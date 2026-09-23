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
@"  function transpile(src, name) {"
@"    var out = Babel.transform(src, { presets: [['env', { targets: { ie: '11' }, modules: false, loose: true, exclude: ['transform-typeof-symbol'] }]],"
@"      sourceType: 'unambiguous', compact: true, comments: false, filename: name || 'script.js', babelrc: false, configFile: false });"
@"    return out.code;"
@"  }"
@"  return { needsTranspile: needsTranspile, transpile: transpile,"
@"    run: function (src, name) { if (!needsTranspile(src)) return ''; return transpile(src, name); } };"
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
            BRLog(@"Process uses %.0f MB before loading the transpiler", BRResidentMemoryMB());
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
    }
    return self;
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
        double ms = ([NSDate timeIntervalSinceReferenceDate] - t1) * 1000;
        int kb = (int)(script.length / 1024);
        BRLog(@"%@.js %@ in %.0f ms (%d KB)", name, ok ? @"loaded" : @"FAILED", ms, kb);
        if (!ok) {
            _loadFailed = YES;
            return NO;
        }
        // a polyfill library must never leave slow JavaScript versions of native functions behind
        [engine evaluateScript:@"__brRestoreNatives()" sourceName:@"restore-natives.js"];
    }
    if (![engine evaluateScript:BRTranspilerGlue sourceName:@"transpiler-glue.js"]) { _loadFailed = YES; return NO; }
    _loaded = YES;
    BRLog(@"Transpiler ready in %.0f ms, process now uses %.0f MB", ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000, BRResidentMemoryMB());
    return YES;
}

- (void)selfTest
{
    NSString *sample = @"const f = async (a = 1, ...r) => { const {x, y = 2} = {x: a}; let s = `v${x}`; class K { #p = 1; static m() {} get v() { return this.#p ?? 0; } } for (const i of [1,2]) { await null; } return r?.[0] ?? y; };";
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BOOL changed = NO;
    NSString *out = [self transpileIfNeeded:sample name:@"selftest.js" changed:&changed];
    BRLog(@"Transpiler self test: %@ in %.0f ms (%d -> %d chars), %.0f MB", changed ? @"transpiled" : @"unchanged",
          ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000, (int)sample.length, (int)out.length, BRResidentMemoryMB());
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
    NSTimeInterval ms = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000;
    if (!out.length) {
        BRLog(@"Transpile failed for %@ in %.0f ms (%d chars)", name, ms, (int)source.length);
        return nil;
    }
    BRLog(@"Transpiled %@ in %.0f ms: %d -> %d chars", name, ms, (int)source.length, (int)out.length);
    [out writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (source.length > 100000) [engine collectGarbage];
    if (changed) *changed = YES;
    return out;
}

@end
