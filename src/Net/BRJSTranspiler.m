#import "BRJSTranspiler.h"
#import "BRJSEngine.h"
#import "BRCommon.h"

#include <CommonCrypto/CommonDigest.h>

static NSString *BRSHA1(NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// Installed into the engine context: syntax check with the engine's own (ES5) parser and the Babel call.
static NSString * const BRTranspilerGlue =
@"var BRTranspile = (function () {"
@"  function needsTranspile(src) { try { new Function(src); return false; } catch (e) { return e instanceof SyntaxError; } }"
@"  var moduleSyntax = /^[ \\t]*(import\\s*[\\w{*'\"]|export\\s+)/m;"
@"  function transpile(src, name, moduleId) {"
@"    var isModule = !!moduleId || moduleSyntax.test(src);"
@"    var opts = { presets: [['env', { targets: { ie: '11' }, modules: isModule ? 'systemjs' : false, loose: true, exclude: ['transform-typeof-symbol'] }]],"
@"      sourceType: isModule ? 'module' : 'script', compact: true, comments: false, filename: name || 'script.js', babelrc: false, configFile: false };"
@"    if (moduleId) { opts.moduleIds = true; opts.moduleId = moduleId; }"
@"    if (!isModule) src = src.replace(/(^|[^\\w$.])import\\s*\\(/g, '$1System.import(');"
@"    return Babel.transform(src, opts).code;"
@"  }"
@"  return { needsTranspile: needsTranspile, transpile: transpile,"
@"    run: function (src, name) { if (!needsTranspile(src)) return ''; return transpile(src, name); },"
@"    transpileModule: function (src, moduleId) { return transpile(src, moduleId, moduleId); } };"
@"})();";

static NSString * const BRSelfTestSample =
@"const f = async (a = 1, ...r) => { const {x, y = 2} = {x: a}; let s = `v${x}`; class K { #p = 1; static m() {} get v() { return this.#p ?? 0; } } for (const i of [1,2]) { await null; } return r?.[0] ?? y; };";

@implementation BRJSTranspiler {
    BOOL _loaded;
    BOOL _loadFailed;
    NSString *_cacheDir;
}

+ (instancetype)shared
{
    static BRJSTranspiler *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[BRJSTranspiler alloc] init]; });
    return t;
}

+ (void)warmUp
{
    BRJSTranspiler *t = [self shared];
    // a few seconds after launch, so the start page renders first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[BRJSEngine shared] performAsync:^{
            BRLog(@"Process uses %ld MB before loading the transpiler", (long)BRResidentMemoryMB());
            if ([t ensureLoaded]) [t selfTest];
        }];
    });
}

// engine queue only: YES when Babel is ready (loads it on demand)
- (BOOL)prepare
{
    return [self ensureLoaded];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _cacheDir = [caches stringByAppendingPathComponent:@"transpiled"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_cacheDir withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidReset:) name:BRJSEngineDidResetNotification object:nil];
    }
    return self;
}

- (void)engineDidReset:(NSNotification *)note
{
    _loaded = NO;   // posted on the engine thread; Babel is loaded again on demand
}

- (BOOL)available
{
    return _loaded && !_loadFailed;
}

// engine queue only
- (BOOL)ensureLoaded
{
    if (_loaded) return YES;
    if (_loadFailed) return NO;
    BRJSEngine *engine = [BRJSEngine shared];
    if (!engine.available) { _loadFailed = YES; return NO; }
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    for (NSString *name in @[@"core-js-custom", @"regenerator-runtime", @"babel.min"]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"js" inDirectory:@"js"];
        if (!path) path = [[NSBundle mainBundle] pathForResource:name ofType:@"js"];
        NSString *script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (!script.length) {
            BRLog(@"%@.js is missing from the bundle", name);
            _loadFailed = YES;
            return NO;
        }
        NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
        BOOL ok = [engine evaluateScript:script sourceName:[name stringByAppendingString:@".js"]];
        long ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t1) * 1000);
        long kb = (long)(script.length / 1024);
        BRLog(@"%@.js %@ in %ld ms (%ld KB)", name, ok ? @"loaded" : @"FAILED", ms, kb);
        if (!ok) {
            _loadFailed = YES;
            return NO;
        }
        // a polyfill library must never leave slow JavaScript versions of native functions behind
        [engine evaluateScript:@"__brRestoreNatives()" sourceName:@"restore-natives.js"];
    }
    if (![engine evaluateScript:BRTranspilerGlue sourceName:@"transpiler-glue.js"]) { _loadFailed = YES; return NO; }
    _loaded = YES;
    BRLog(@"Transpiler ready in %ld ms, process now uses %ld MB", (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), (long)BRResidentMemoryMB());
    return YES;
}

- (void)selfTest
{
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BOOL changed = NO;
    NSString *out = [self transpileIfNeeded:BRSelfTestSample name:@"selftest.js" changed:&changed];
    BRLog(@"Transpiler self test: %@ in %ld ms (%ld -> %ld chars), %ld MB", changed ? @"transpiled" : @"unchanged",
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), (long)BRSelfTestSample.length, (long)out.length, (long)BRResidentMemoryMB());
}

// Throughput measurement on a synthetic 20 KB source (100 copies of the sample), Babel and TypeScript.
+ (void)runBenchmark
{
    BRJSTranspiler *t = [self shared];
    [[BRJSEngine shared] performAsync:^{
        NSMutableString *big = [NSMutableString string];
        for (int i = 0; i < 100; i++) [big appendFormat:@"%@\nvar g%d = f;\n", BRSelfTestSample, i];
        if ([t ensureLoaded]) {
            NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
            NSString *out = [[BRJSEngine shared] callFunction:@"BRTranspile.transpile" arguments:@[big, @"bench.js"]];
            BRLog(@"BENCH Babel: %ld chars in %ld ms -> %ld chars, %ld MB", (long)big.length,
                  (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), (long)out.length, (long)BRResidentMemoryMB());
        }
        // TypeScript in a fresh context (Babel released first)
        BRJSEngine *engine = [BRJSEngine shared];
        [engine resetContext];
        [engine performAsync:^{
            NSString *path = [[NSBundle mainBundle] pathForResource:@"typescript.min" ofType:@"js" inDirectory:@"js"];
            NSString *script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
            if (!script.length) { BRLog(@"BENCH TypeScript: typescript.min.js missing"); return; }
            NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
            BOOL ok = [engine evaluateScript:script sourceName:@"typescript.js"];
            [engine evaluateScript:@"__brRestoreNatives()" sourceName:@"restore-natives.js"];
            BRLog(@"BENCH TypeScript %@ in %ld ms (%ld KB), %ld MB", ok ? @"loaded" : @"FAILED",
                  (long)(([NSDate timeIntervalSinceReferenceDate] - t1) * 1000), (long)(script.length / 1024), (long)BRResidentMemoryMB());
            if (!ok) return;
            [engine evaluateScript:@"var BRTS = function (src) { return ts.transpileModule(src, { compilerOptions: { target: ts.ScriptTarget.ES5, module: ts.ModuleKind.System, downlevelIteration: false, importHelpers: false, noEmitHelpers: false }, reportDiagnostics: false }).outputText; };" sourceName:@"ts-glue.js"];
            NSTimeInterval t2 = [NSDate timeIntervalSinceReferenceDate];
            NSString *small = [engine callFunction:@"BRTS" arguments:@[BRSelfTestSample]];
            BRLog(@"BENCH TypeScript small: %ld -> %ld chars in %ld ms", (long)BRSelfTestSample.length, (long)small.length, (long)(([NSDate timeIntervalSinceReferenceDate] - t2) * 1000));
            NSTimeInterval t3 = [NSDate timeIntervalSinceReferenceDate];
            NSString *out = [engine callFunction:@"BRTS" arguments:@[big]];
            BRLog(@"BENCH TypeScript: %ld chars in %ld ms -> %ld chars, %ld MB", (long)big.length,
                  (long)(([NSDate timeIntervalSinceReferenceDate] - t3) * 1000), (long)out.length, (long)BRResidentMemoryMB());
            [engine resetContext];
        }];
    }];
}

- (NSString *)transpileIfNeeded:(NSString *)source name:(NSString *)name changed:(BOOL *)changed
{
    if (changed) *changed = NO;
    if (!source.length || ![self ensureLoaded]) return nil;
    BRJSEngine *engine = [BRJSEngine shared];
    NSString *needs = [engine callFunction:@"BRTranspile.needsTranspile" arguments:@[source]];
    if (![needs isEqualToString:@"true"]) return nil;
    NSString *key = BRSHA1(source);
    NSString *cachePath = [_cacheDir stringByAppendingPathComponent:[key stringByAppendingString:@".js"]];
    NSString *cached = [NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:NULL];
    if (cached.length) {
        if (changed) *changed = YES;
        return cached;
    }
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    NSString *out = [engine callFunction:@"BRTranspile.transpile" arguments:@[source, name ?: @"script.js"]];
    long ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000);
    if (!out.length) {
        BRLog(@"Transpile failed for %@ in %ld ms (%ld chars)", name, ms, (long)source.length);
        return nil;
    }
    BRLog(@"Transpiled %@ in %ld ms: %ld -> %ld chars", name, ms, (long)source.length, (long)out.length);
    [out writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (source.length > 100000) [engine collectGarbage];
    if (changed) *changed = YES;
    return out;
}

@end
