#import "BRCSSRewriter.h"
#import "BRJSEngine.h"
#import "BRSettings.h"
#import "BRCommon.h"

#include <zlib.h>

static const NSUInteger BRMaxPagesRemembered = 8;
static NSString *BRPageKey(NSURL *url);
// The bundle is cached by pages for a year, so its URL carries a checksum of the content: a new
// build with new polyfills gets a new URL instead of the old cached bundle.
static NSString *g_polyfillURL;

static NSStringEncoding BREncodingForCharset(NSString *charset)
{
    if (!charset.length) return 0;
    CFStringEncoding cf = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)charset);
    if (cf == kCFStringEncodingInvalidId) return 0;
    return CFStringConvertEncodingToNSStringEncoding(cf);
}

// charset declared inside the document itself (<meta charset>, <meta http-equiv>, @charset)
static NSString *BRSniffCharset(NSData *data, NSString *kind)
{
    NSUInteger len = MIN(data.length, (NSUInteger)4096);
    NSString *head = [[NSString alloc] initWithBytes:data.bytes length:len encoding:NSISOLatin1StringEncoding];
    if (!head) return nil;
    NSRegularExpression *re;
    if ([kind isEqualToString:@"css"]) {
        re = [NSRegularExpression regularExpressionWithPattern:@"^@charset\\s+\"([A-Za-z0-9_-]+)\"" options:0 error:NULL];
    } else {
        re = [NSRegularExpression regularExpressionWithPattern:@"charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9_-]+)" options:NSRegularExpressionCaseInsensitive error:NULL];
    }
    NSTextCheckingResult *m = [re firstMatchInString:head options:0 range:NSMakeRange(0, head.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    return [head substringWithRange:[m rangeAtIndex:1]];
}

static NSString *BRDecode(NSData *data, NSString *charset, NSString **usedCharset)
{
    NSString *s = nil;
    NSStringEncoding enc = BREncodingForCharset(charset);
    if (enc) {
        s = [[NSString alloc] initWithData:data encoding:enc];
        if (s) { *usedCharset = charset; return s; }
    }
    s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) { *usedCharset = @"utf-8"; return s; }
    s = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    if (s) { *usedCharset = @"windows-1252"; return s; }
    *usedCharset = @"iso-8859-1";
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

// Caches/transpiled/<crc>-<length>-<jsfix tag>.js: lowered scripts by content (an empty file: nothing to lower)
static NSString *BRTranspiledDirectory(void)
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return [caches stringByAppendingPathComponent:@"transpiled"];
}

// a checksum of jsfix.js: results of another version are not reused
static NSString *BRTranspileTag(void)
{
    static NSString *tag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"jsfix" ofType:@"js"];
        NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
        unsigned long crc = crc32(0L, Z_NULL, 0);
        if (d.length) crc = crc32(crc, (const Bytef *)d.bytes, (uInt)d.length);
        tag = [NSString stringWithFormat:@"%08lx", crc];
    });
    return tag;
}

@implementation BRCSSRewriter {
    BOOL _loaded;
    BOOL _loadFailed;
    BOOL _jsfixLoaded;                  // in the rewriter's engine (inline scripts of documents)
    BOOL _jsfixLoadedTranspiler;        // in the transpiler engine (script files)
    BOOL _jsfixFailed;
    NSCache *_transpiled;               // cache key -> lowered script (empty data: unchanged)
    NSMutableDictionary *_pageVars;     // page key -> NSMutableDictionary of --name: value
    NSMutableArray *_pageOrder;
    NSMutableDictionary *_pageManifests;   // page key -> @{ @"has": NSMutableArray, @"cq": NSMutableArray, @"seen": NSMutableSet }
    NSMutableArray *_manifestOrder;
}

+ (instancetype)shared
{
    static BRCSSRewriter *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [[BRCSSRewriter alloc] init]; });
    return r;
}

static CGFloat g_viewportWidth = 768;
static CGFloat g_devicePixelRatio = 1;

+ (void)warmUp
{
    BRCSSRewriter *r = [self shared];
    CGRect screen = [UIScreen mainScreen].bounds;
    g_viewportWidth = MIN(screen.size.width, screen.size.height);   // portrait width: the wider layout of the two is fine
    g_devicePixelRatio = [UIScreen mainScreen].scale ?: 1;          // read here, on the main thread
    [[BRJSEngine shared] performAsync:^{ [r ensureLoaded]; if ([BRSettings transpileEnabled]) [r ensureJSFixIn:[BRJSEngine shared]]; }];
    [[BRJSEngine transpiler] performAsync:^{ if ([BRSettings transpileEnabled]) [r ensureJSFixIn:[BRJSEngine transpiler]]; }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{ @autoreleasepool { [BRCSSRewriter pruneTranspiledCache]; } });
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pageVars = [NSMutableDictionary dictionary];
        _pageOrder = [NSMutableArray array];
        _pageManifests = [NSMutableDictionary dictionary];
        _manifestOrder = [NSMutableArray array];
        _transpiled = [[NSCache alloc] init];
        _transpiled.totalCostLimit = 8 * 1024 * 1024;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidReset:) name:BRJSEngineDidResetNotification object:nil];
    }
    return self;
}

#pragma mark - Manifest (:has() and @container entries for the page shim)

- (void)registerManifestInData:(NSData *)data pageURL:(NSURL *)pageURL sourceURL:(NSURL *)sourceURL
{
    if (data.length < 20 || !pageURL) return;
    // the comment sits at the very end: "/*br-manifest:{...}*/" or "<!--br-manifest:{...}-->"; with the custom
    // property entries of a big framework it can be several hundred KB
    NSData *markerData = [@"br-manifest:" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange marker = [data rangeOfData:markerData options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (marker.location == NSNotFound) return;
    NSUInteger start = marker.location + marker.length;
    NSRange tailRange = NSMakeRange(start, data.length - start);
    NSRange end = [data rangeOfData:[@"*/" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:tailRange];
    if (end.location == NSNotFound) end = [data rangeOfData:[@"-->" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:tailRange];
    if (end.location == NSNotFound || end.location < start) return;
    NSString *json = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(start, end.location - start)] encoding:NSUTF8StringEncoding];
    if (!json) return;
    json = [json stringByReplacingOccurrencesOfString:@"-\\u002d" withString:@"--"];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;
    NSString *key = BRPageKey(pageURL);
    NSString *source = (sourceURL ?: pageURL).absoluteString ?: @"";
    NSRange hash = [source rangeOfString:@"#"];
    if (hash.location != NSNotFound) source = [source substringToIndex:hash.location];
    @synchronized (self) {
        NSMutableDictionary *m = _pageManifests[key];
        if (!m) {
            m = [@{ @"has": [NSMutableArray array], @"cq": [NSMutableArray array], @"dv": [NSMutableArray array], @"pt": [NSMutableArray array],
                    @"cv": [NSMutableArray array], @"sc": [NSMutableArray array], @"sheets": [NSMutableArray array], @"seen": [NSMutableSet set] } mutableCopy];
            _pageManifests[key] = m;
            [_manifestOrder addObject:key];
            while (_manifestOrder.count > BRMaxPagesRemembered) {
                [_pageManifests removeObjectForKey:_manifestOrder[0]];
                [_manifestOrder removeObjectAtIndex:0];
            }
        }
        NSMutableSet *seen = m[@"seen"];
        // custom property rules remember which stylesheet they came from: the page shim orders them the way the
        // document orders its stylesheets (they arrive in network order)
        NSMutableArray *sheets = m[@"sheets"];
        NSUInteger sheetIndex = [sheets indexOfObject:source];
        for (NSString *kind in @[@"has", @"cq", @"dv", @"pt", @"cv", @"sc"]) {
            NSArray *entries = parsed[kind];
            if (![entries isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *e in entries) {
                if (![e isKindOfClass:[NSDictionary class]] || ![e[@"h"] isKindOfClass:[NSString class]]) continue;
                NSString *entryId = [kind stringByAppendingString:e[@"h"]];
                if ([seen containsObject:entryId]) continue;
                [seen addObject:entryId];
                if ([kind isEqualToString:@"cv"]) {
                    if (sheetIndex == NSNotFound) { [sheets addObject:source]; sheetIndex = sheets.count - 1; }
                    NSMutableDictionary *withSheet = [e mutableCopy];
                    withSheet[@"si"] = @(sheetIndex);
                    [m[kind] addObject:withSheet];
                } else {
                    [m[kind] addObject:e];
                }
            }
        }
    }
}

- (NSData *)manifestJSONForPageURLString:(NSString *)pageURLString
{
    NSString *key = BRPageKey([NSURL URLWithString:pageURLString ?: @""]);
    NSDictionary *out = nil;
    @synchronized (self) {
        NSDictionary *m = _pageManifests[key];
        NSMutableDictionary *rootVars = [_pageVars[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        [rootVars removeObjectForKey:@" scoped"];
        if (m) out = @{ @"has": [m[@"has"] copy], @"cq": [m[@"cq"] copy], @"dv": [m[@"dv"] copy], @"pt": [m[@"pt"] copy],
                        @"cv": [m[@"cv"] copy], @"sc": [m[@"sc"] copy], @"sheets": [m[@"sheets"] copy], @"vars": rootVars };
    }
    if (!out) out = @{ @"has": @[], @"cq": @[], @"dv": @[], @"pt": @[], @"cv": @[], @"sc": @[] };
    return [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)engineDidReset:(NSNotification *)note
{
    // posted on the engine's own thread
    if (note.object == [BRJSEngine transpiler]) _jsfixLoadedTranspiler = NO;
    else { _loaded = NO; _jsfixLoaded = NO; }
}

// the engine's queue only: acorn and the transpiler, loaded on the first script that needs them (the rewriter's
// engine for inline scripts of documents, the transpiler engine for script files)
- (BOOL)ensureJSFixIn:(BRJSEngine *)engine
{
    BOOL *loaded = engine == [BRJSEngine transpiler] ? &_jsfixLoadedTranspiler : &_jsfixLoaded;
    if (*loaded) return YES;
    if (_jsfixFailed) return NO;
    if (!engine.available) { _jsfixFailed = YES; return NO; }
    NSBundle *b = [NSBundle mainBundle];
    NSString *acornPath = [b pathForResource:@"acorn" ofType:@"js" inDirectory:@"js"] ?: [b pathForResource:@"acorn" ofType:@"js"];
    NSString *fixPath = [b pathForResource:@"jsfix" ofType:@"js"];
    NSString *acorn = acornPath ? [NSString stringWithContentsOfFile:acornPath encoding:NSUTF8StringEncoding error:NULL] : nil;
    NSString *fix = fixPath ? [NSString stringWithContentsOfFile:fixPath encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!acorn.length || !fix.length) {
        BRLog(@"acorn.js or jsfix.js is missing from the bundle");
        _jsfixFailed = YES;
        return NO;
    }
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    if (![engine evaluateScript:acorn sourceName:@"acorn.js"] || ![engine evaluateScript:fix sourceName:@"jsfix.js"]) { _jsfixFailed = YES; return NO; }
    NSString *probe = [engine callFunction:@"JSFix.run" arguments:@[@"let f = (a = 1) => `${a}`;", @"{\"force\":true}"]];
    if (!probe.length) { BRLog(@"jsfix.js self test failed"); _jsfixFailed = YES; return NO; }
    *loaded = YES;
    BRLog(@"jsfix.js loaded in %ld ms (%@)", (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), engine == [BRJSEngine transpiler] ? @"scripts" : @"documents");
    return YES;
}

// the transpiler engine's queue only: the ES5 text of a script, nil when it needs nothing (or cannot be lowered);
// a module always gives its registration for the page's loader (or a stub reporting why it failed)
- (NSData *)transpiledScript:(NSData *)data charset:(NSString *)charset url:(NSURL *)url module:(BOOL)module
{
    BRJSEngine *engine = [BRJSEngine transpiler];
    unsigned long crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef *)data.bytes, (uInt)data.length);
    // (a module's registration names its URL: the key has it too)
    if (module) { NSData *u = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding]; if (u.length) crc = crc32(crc, (const Bytef *)u.bytes, (uInt)u.length); }
    NSString *key = [NSString stringWithFormat:@"%08lx-%lx%@-%@", crc, (unsigned long)data.length, module ? @"m" : @"", BRTranspileTag()];
    NSString *dir = BRTranspiledDirectory();
    NSString *path = [dir stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"js"]];
    BOOL private = [BRSettings privateMode];
    NSData *cached = [_transpiled objectForKey:key];
    if (!cached && !private) {
        cached = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        if (cached) {
            [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: [NSDate date] } ofItemAtPath:path error:NULL];   // recently used
            [_transpiled setObject:cached forKey:key cost:cached.length];
        }
    }
    if (cached) return cached.length ? cached : nil;
    if (![self ensureJSFixIn:engine]) return nil;
    NSString *used = nil;
    NSString *text = BRDecode(data, charset.length ? charset : nil, &used);
    if (!text) return nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    NSString *optsJSON = @"{}";
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    if (url.absoluteString.length) o[@"url"] = url.absoluteString;
    if (module) o[@"module"] = @YES;
    NSData *oj = [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];
    if (oj) optsJSON = [[NSString alloc] initWithData:oj encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *result = [engine callFunction:@"JSFix.run" arguments:@[text, optsJSON]];
    long ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000);
    NSData *out = result.length ? [result dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"script";
    if (out && module) {
        NSString *why = [engine callFunction:@"JSFix.last" arguments:@[]];
        BRLog(@"jsfix module %@: %ld ms, %lu -> %lu bytes%@", name, ms, (unsigned long)data.length, (unsigned long)out.length,
              [why hasPrefix:@"failed"] ? [@" " stringByAppendingString:why] : @"");
    } else if (out) BRLog(@"jsfix %@: %ld ms, %lu -> %lu bytes", name, ms, (unsigned long)data.length, (unsigned long)out.length);
    else {
        NSString *why = [engine callFunction:@"JSFix.last" arguments:@[]];
        if (![why isEqualToString:@"es5"] || ms > 200) BRLog(@"jsfix %@: unchanged after %ld ms (%@)", name, ms, why ?: @"?");
    }
    NSData *store = out ?: [NSData data];
    [_transpiled setObject:store forKey:key cost:store.length + 64];
    if (!private) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [store writeToFile:path atomically:YES];
    }
    if (data.length > 200000) [engine collectGarbage];
    return out;
}

+ (void)pruneTranspiledCache
{
    NSString *dir = BRTranspiledDirectory(), *suffix = [NSString stringWithFormat:@"-%@.js", BRTranspileTag()];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray *items = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *n in names) {
        NSString *p = [dir stringByAppendingPathComponent:n];
        if (![n hasSuffix:suffix]) { [fm removeItemAtPath:p error:NULL]; continue; }   // an older transpiler's output
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        if (!a) continue;
        total += [a fileSize];
        [items addObject:@[p, [a fileModificationDate] ?: [NSDate distantPast], @([a fileSize])]];
    }
    const unsigned long long limit = 48ull * 1024 * 1024;
    if (total <= limit) return;
    [items sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [x[1] compare:y[1]]; }];
    for (NSArray *it in items) {
        if (total <= limit * 3 / 4) break;
        [fm removeItemAtPath:it[0] error:NULL];
        total -= [it[2] unsignedLongLongValue];
    }
}

- (BOOL)available
{
    return [BRJSEngine shared].available && !_loadFailed;
}

// engine queue only
- (BOOL)ensureLoaded
{
    if (_loaded) return YES;
    if (_loadFailed) return NO;
    BRJSEngine *engine = [BRJSEngine shared];
    if (!engine.available) { _loadFailed = YES; return NO; }
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cssfix" ofType:@"js"];
    NSString *script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!script.length) {
        BRLog(@"cssfix.js is missing from the bundle");
        _loadFailed = YES;
        return NO;
    }
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    if (![engine evaluateScript:script sourceName:@"cssfix.js"]) { _loadFailed = YES; return NO; }
    NSString *probe = [engine callFunction:@"CSSFix.run" arguments:@[@"css", @".a{display:flex}", @"{}"]];
    if (!probe.length) { BRLog(@"cssfix.js self test failed"); _loadFailed = YES; return NO; }
    _loaded = YES;
    BRLog(@"cssfix.js loaded in %ld ms", (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000));
    return YES;
}

static NSString *BRPageKey(NSURL *url)
{
    NSString *s = url.absoluteString ?: @"";
    NSRange hash = [s rangeOfString:@"#"];
    return hash.location == NSNotFound ? s : [s substringToIndex:hash.location];
}

// engine queue only
- (NSMutableDictionary *)varsForPage:(NSString *)key create:(BOOL)create
{
    @synchronized (self) {   // the manifest endpoint reads them from other threads
        NSMutableDictionary *vars = _pageVars[key];
        if (!vars && create) {
            vars = [NSMutableDictionary dictionary];
            _pageVars[key] = vars;
            [_pageOrder addObject:key];
            while (_pageOrder.count > BRMaxPagesRemembered) {
                [_pageVars removeObjectForKey:_pageOrder[0]];
                [_pageOrder removeObjectAtIndex:0];
            }
        }
        return vars;
    }
}

+ (NSString *)polyfillURLString
{
    [self polyfillBundle];
    return g_polyfillURL ?: @"https://ios6-browser.invalid/polyfills.js";
}

+ (NSData *)polyfillBundle
{
    static NSData *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableData *d = [NSMutableData data];
        NSBundle *b = [NSBundle mainBundle];
        for (NSString *name in @[@"core-js-custom", @"regenerator-runtime", @"fetch", @"intersection-observer", @"resize-observer", @"picturefill", @"dialog-polyfill",
                                 @"object-fit-images", @"shims", @"shims-extra"]) {
            NSString *path = [b pathForResource:name ofType:@"js" inDirectory:@"js"];
            if (!path) path = [b pathForResource:name ofType:@"js"];
            NSData *part = path ? [NSData dataWithContentsOfFile:path] : nil;
            if (!part.length) { BRLog(@"polyfill %@.js missing", name); continue; }
            [d appendData:[[NSString stringWithFormat:@"\n;/* %@ */\n", name] dataUsingEncoding:NSUTF8StringEncoding]];
            [d appendData:part];
            [d appendData:[@"\n;\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        bundle = d;
        unsigned long crc = crc32(0L, Z_NULL, 0);
        crc = crc32(crc, (const Bytef *)d.bytes, (uInt)d.length);
        g_polyfillURL = [NSString stringWithFormat:@"https://ios6-browser.invalid/polyfills-%08lx.js", crc];
        BRLog(@"Polyfill bundle assembled: %lu KB (%@)", (unsigned long)(d.length / 1024), g_polyfillURL);
    });
    return bundle;
}

- (void)rewriteData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL
          mainFrame:(BOOL)mainFrame completion:(BRRewriteCompletion)completion
{
    [self rewriteData:data kind:kind charset:charset pageURL:pageURL sourceURL:nil mainFrame:mainFrame completion:completion];
}

- (void)rewriteData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL
          sourceURL:(NSURL *)sourceURL mainFrame:(BOOL)mainFrame completion:(BRRewriteCompletion)completion
{
    if (!completion) return;
    if ([kind isEqualToString:@"js"] || [kind isEqualToString:@"jsmodule"]) {
        // scripts on the transpiler engine: stylesheets and documents do not wait behind them
        BOOL module = [kind isEqualToString:@"jsmodule"];
        [[BRJSEngine transpiler] performAsync:^{
            @autoreleasepool {
                NSData *lowered = [BRSettings transpileEnabled] ? [self transpiledScript:data charset:charset url:sourceURL module:module] : nil;
                if (lowered) completion(lowered, @"utf-8");
                else completion(data, charset);
            }
        }];
        return;
    }
    [[BRJSEngine shared] performAsync:^{
        @autoreleasepool {
            NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
            NSString *used = nil;
            if (![self ensureLoaded]) { completion(data, charset); return; }
            NSString *declared = charset.length ? charset : BRSniffCharset(data, kind);
            NSString *text = BRDecode(data, declared, &used);
            if (!text) { completion(data, charset); return; }
            NSString *pageKey = BRPageKey(pageURL);
            NSMutableDictionary *vars = [self varsForPage:pageKey create:YES];
            NSString *varsJSON = @"{}";
            NSData *j = nil;
            @synchronized (self) { if (vars.count) j = [NSJSONSerialization dataWithJSONObject:vars options:0 error:NULL]; }
            if (j) varsJSON = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] ?: @"{}";
            NSString *optionsJSON = @"{}";
            {
                NSMutableDictionary *opts = [@{ @"pageURL": pageURL.absoluteString ?: @"", @"viewportWidth": @(g_viewportWidth),
                                                @"devicePixelRatio": @(g_devicePixelRatio) } mutableCopy];
                // iframes (mostly ads and widgets) do not get the 500 KB bundle: memory on a 512 MB device
                if ([kind isEqualToString:@"html"] && mainFrame && [BRSettings jsFixEnabled]) opts[@"polyfillURL"] = [BRCSSRewriter polyfillURLString];
                if ([kind isEqualToString:@"html"] && [BRSettings hideCookieBanners]) opts[@"hideCookieBanners"] = @YES;
                // inline scripts in ES2015+ syntax: lowered by the transpiler in the same context
                if ([kind isEqualToString:@"html"] && [BRSettings transpileEnabled] && [self ensureJSFixIn:[BRJSEngine shared]]) opts[@"transpile"] = @YES;
                NSData *oj = [NSJSONSerialization dataWithJSONObject:opts options:0 error:NULL];
                if (oj) optionsJSON = [[NSString alloc] initWithData:oj encoding:NSUTF8StringEncoding] ?: @"{}";
            }
            NSString *result = [[BRJSEngine shared] callFunction:@"CSSFix.run" arguments:@[kind, text, varsJSON, optionsJSON]];
            if (!result.length) { completion(data, charset); return; }
            NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            NSString *out = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"out"] : nil;
            if (![out isKindOfClass:[NSString class]]) { completion(data, charset); return; }
            NSDictionary *newVars = parsed[@"vars"];
            NSArray *scoped = parsed[@"scoped"];
            @synchronized (self) {
                if ([newVars isKindOfClass:[NSDictionary class]] && newVars.count) {
                    for (NSString *name in newVars) {
                        id value = newVars[name];
                        if ([value isKindOfClass:[NSString class]] && ![name isEqualToString:@" scoped"]) vars[name] = value;
                    }
                }
                // custom properties resolved per element at run time, for the page's later documents (" scoped" is
                // not a property name, so it cannot clash with one)
                if ([scoped isKindOfClass:[NSArray class]] && scoped.count) {
                    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSetWithArray:[vars[@" scoped"] ?: @"" componentsSeparatedByString:@" "]];
                    for (id n in scoped) if ([n isKindOfClass:[NSString class]]) [names addObject:n];
                    [names removeObject:@""];
                    vars[@" scoped"] = [names.array componentsJoinedByString:@" "];
                }
            }
            NSData *outData = [out dataUsingEncoding:NSUTF8StringEncoding];
            BRLog(@"cssfix %@ %ld ms: %lu -> %lu bytes (%@, %lu vars)", kind, (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000),
                  (unsigned long)data.length, (unsigned long)outData.length, used ?: @"?", (unsigned long)vars.count);
            if (data.length > 200000) [[BRJSEngine shared] collectGarbage];
            completion(outData ?: data, outData ? @"utf-8" : charset);
        }
    }];
}

@end
