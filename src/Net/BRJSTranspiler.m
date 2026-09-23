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
@"  function transpile(src, name, moduleId) {"
@"    var opts = { presets: [['env', { targets: { ie: '11' }, modules: 'systemjs', loose: true, exclude: ['transform-typeof-symbol'] }]],"
@"      sourceType: moduleId ? 'module' : 'unambiguous', compact: true, comments: false, filename: name || 'script.js', babelrc: false, configFile: false };"
@"    if (moduleId) { opts.moduleIds = true; opts.moduleId = moduleId; }"
@"    return Babel.transform(src, opts).code;"
@"  }"
@"  return { needsTranspile: needsTranspile, transpile: transpile,"
@"    run: function (src, name) { if (!needsTranspile(src)) return ''; return transpile(src, name); },"
@"    transpileModule: function (src, moduleId) { return transpile(src, moduleId, moduleId); } };"
@"})();";

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
    NSString *sample = @"const f = async (a = 1, ...r) => { const {x, y = 2} = {x: a}; let s = `v${x}`; class K { #p = 1; static m() {} get v() { return this.#p ?? 0; } } for (const i of [1,2]) { await null; } return r?.[0] ?? y; };";
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BOOL changed = NO;
    NSString *out = [self transpileIfNeeded:sample name:@"selftest.js" changed:&changed];
    BRLog(@"Transpiler self test: %@ in %ld ms (%ld -> %ld chars), %ld MB", changed ? @"transpiled" : @"unchanged",
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), (long)sample.length, (long)out.length, (long)BRResidentMemoryMB());
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
