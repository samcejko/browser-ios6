#import "BRCSSRewriter.h"
#import "BRJSEngine.h"
#import "BRSettings.h"
#import "BRCommon.h"
#import "BRMemory.h"

#include <zlib.h>

static const NSUInteger BRMaxPagesRemembered = 8;
// seconds without work before an engine gives its whole heap back (the rewriter's engine only above the given
// resident size: every document needs it, and reloading cssfix.js costs half a second)
static const NSTimeInterval BRTranspilerIdleRelease = 6;
static const NSTimeInterval BRRewriterIdleRelease = 15;
static const long BRRewriterIdleReleaseAboveMB = 170;
// what the system should have available before heavy work starts (MB): a floor plus a share of the input size
// (measured: lowering a 1-1.5 MB script function by function takes 45-75 MB; rewriting takes less)
static const long BRRoomFloorMB = 55, BRRoomPerMBScript = 40, BRRoomPerMBDocument = 25;
// bumped when a page load is stopped for lack of memory: queued work of that page is dropped
static volatile NSUInteger g_workGeneration;
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

+ (NSData *)dataWithoutManifest:(NSData *)data
{
    if (data.length < 20) return data;
    NSRange m = [data rangeOfData:[@"br-manifest:" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (m.location == NSNotFound || m.location < 4) return data;
    const char *bytes = data.bytes;
    NSUInteger start;
    NSData *closer;
    if (bytes[m.location - 2] == '/' && bytes[m.location - 1] == '*') { start = m.location - 2; closer = [@"*/" dataUsingEncoding:NSUTF8StringEncoding]; }
    else if (memcmp(bytes + m.location - 4, "<!--", 4) == 0) { start = m.location - 4; closer = [@"-->" dataUsingEncoding:NSUTF8StringEncoding]; }
    else return data;
    NSRange end = [data rangeOfData:closer options:NSDataSearchBackwards range:NSMakeRange(m.location, data.length - m.location)];
    if (end.location == NSNotFound) return data;
    NSUInteger after = end.location + end.length;
    NSMutableData *out = [NSMutableData dataWithCapacity:start + (data.length - after)];
    [out appendBytes:bytes length:start];
    [out appendBytes:bytes + after length:data.length - after];
    return out;
}

// since: "has:3,cq:0,...,vars:40,sheets:2", what the page has already: only the entries after those counts come back
// (all of them, with reset, when the page has more than there are), and {"same":1} when nothing changed. GitHub's
// manifest is 2.3 MB, and the page asks again whenever its DOM settles.
- (NSData *)manifestJSONForPageURLString:(NSString *)pageURLString since:(NSString *)since
{
    if (!since.length) return [self manifestJSONForPageURLString:pageURLString];
    NSMutableDictionary *have = [NSMutableDictionary dictionary];
    for (NSString *part in [since componentsSeparatedByString:@","]) {
        NSRange c = [part rangeOfString:@":"];
        if (c.location != NSNotFound) have[[part substringToIndex:c.location]] = @([[part substringFromIndex:c.location + 1] integerValue]);
    }
    NSString *key = BRPageKey([NSURL URLWithString:pageURLString ?: @""]);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray *kinds = @[@"has", @"cq", @"dv", @"pt", @"cv", @"sc"];
    BOOL changed = NO, reset = NO;
    @synchronized (self) {
        NSDictionary *m = _pageManifests[key];
        NSMutableDictionary *rootVars = [_pageVars[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        [rootVars removeObjectForKey:@" scoped"];
        for (NSString *kind in kinds) if ([have[kind] integerValue] > (NSInteger)[m[kind] count]) reset = YES;
        for (NSString *kind in kinds) {
            NSArray *list = m[kind] ?: @[];
            NSUInteger from = reset ? 0 : (NSUInteger)MAX(0, [have[kind] integerValue]);
            if (from < list.count) { out[kind] = [list subarrayWithRange:NSMakeRange(from, list.count - from)]; changed = YES; }
            else out[kind] = @[];
        }
        NSArray *sheets = [m[@"sheets"] copy] ?: @[];
        if ((NSInteger)sheets.count != [have[@"sheets"] integerValue] || (NSInteger)rootVars.count != [have[@"vars"] integerValue]) changed = YES;
        out[@"sheets"] = sheets;
        out[@"vars"] = rootVars;
    }
    if (!changed && !reset) return [@"{\"same\":1}" dataUsingEncoding:NSUTF8StringEncoding];
    if (reset) out[@"reset"] = @YES;
    return [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
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
    // Unicode property tables for \p{...} (optional: without them such patterns stay RegExp constructor calls)
    NSString *uniPath = [b pathForResource:@"unicode-props" ofType:@"js" inDirectory:@"js"];
    NSString *uni = uniPath ? [NSString stringWithContentsOfFile:uniPath encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (uni.length) [engine evaluateScript:uni sourceName:@"unicode-props.js"];
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
    // room first: when the iPad is short of memory the page waits (loads slower) instead of iOS closing the app; a big
    // script that still does not fit is left as it is (not cached: it is lowered on a later visit)
    long need = BRRoomFloorMB + (long)(data.length * BRRoomPerMBScript / (1024 * 1024));
    if (![BRMemory waitForAvailableMB:need timeout:30 reason:[NSString stringWithFormat:@"lowering %@ (%lu KB)", url.lastPathComponent ?: @"a script", (unsigned long)(data.length >> 10)] engine:engine]
        && [BRMemory availableMB] < BRRoomFloorMB + (long)(data.length * BRRoomPerMBScript / (2 * 1024 * 1024))) {
        BRLog(@"jsfix %@: left unlowered, not enough memory", url.lastPathComponent ?: @"script");
        return nil;
    }
    if (![self ensureJSFixIn:engine]) return nil;
    NSString *used = nil;
    NSString *text = BRDecode(data, charset.length ? charset : nil, &used);
    if (!text) return nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    long mb0 = (long)BRResidentMemoryMB();
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"script";
    [BRMemory setActivity:[NSString stringWithFormat:@"transpiling %@ (%lu KB)", name, (unsigned long)(data.length >> 10)] forKey:@"js"];
    NSString *optsJSON = @"{}";
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    if (url.absoluteString.length) o[@"url"] = url.absoluteString;
    if (module) o[@"module"] = @YES;
    NSData *oj = [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];
    if (oj) optsJSON = [[NSString alloc] initWithData:oj encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *result = [engine callFunction:@"JSFix.run" arguments:@[text, optsJSON]];
    text = nil;
    long ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000);
    NSData *out = result.length ? [result dataUsingEncoding:NSUTF8StringEncoding] : nil;
    result = nil;
    long mb1 = (long)BRResidentMemoryMB();
    if (out && module) {
        NSString *why = [engine callFunction:@"JSFix.last" arguments:@[]];
        BRLog(@"jsfix module %@: %ld ms, %lu -> %lu bytes, %ld -> %ld MB%@", name, ms, (unsigned long)data.length, (unsigned long)out.length, mb0, mb1,
              [why hasPrefix:@"failed"] ? [@" " stringByAppendingString:why] : @"");
    } else if (out) BRLog(@"jsfix %@: %ld ms, %lu -> %lu bytes, %ld -> %ld MB", name, ms, (unsigned long)data.length, (unsigned long)out.length, mb0, mb1);
    else {
        NSString *why = [engine callFunction:@"JSFix.last" arguments:@[]];
        if (![why isEqualToString:@"es5"] || ms > 200) BRLog(@"jsfix %@: unchanged after %ld ms (%@), %ld -> %ld MB", name, ms, why ?: @"?", mb0, mb1);
    }
    [BRMemory setActivity:nil forKey:@"js"];
    // given up for lack of memory (see jsfix.js MEMORY_FLOOR_MB): not remembered, a later visit lowers it
    if (!out || module) {
        NSString *last = [engine callFunction:@"JSFix.last" arguments:@[]] ?: @"";
        if ([last rangeOfString:@"memory"].location != NSNotFound) {
            BRLog(@"jsfix %@: gave up, the iPad is short of memory (%ld MB available)", name, [BRMemory availableMB]);
            [engine releaseContextNow];
            return out;
        }
    }
    NSData *store = out ?: [NSData data];
    [_transpiled setObject:store forKey:key cost:store.length + 64];
    if (!private) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [store writeToFile:path atomically:YES];
    }
    if (data.length > 200000) { [engine collectGarbage]; [BRJSEngine returnFreeMemory]; }
    // a parse tree of a big script leaves the heap large: the whole VM goes once the page's scripts are through
    // (acorn and jsfix.js load again in about 0.4 s; most scripts come from the cache above anyway)
    [engine releaseWhenIdleFor:BRTranspilerIdleRelease aboveMB:0];
    return out;
}

+ (void)cancelPendingWork
{
    g_workGeneration++;
}

+ (void)runTranspileTest:(NSDictionary *)params
{
    BRJSEngine *engine = [BRJSEngine transpiler];
    [engine performAsync:^{
        @autoreleasepool {
            NSString *report;
            NSString *input = params[@"input"] ?: @"", *opts = [params[@"opts"] length] ? params[@"opts"] : @"{}";
            BOOL readable = [[NSFileManager defaultManager] isReadableFileAtPath:input];
            [engine releaseContextNow];   // a fresh heap for the measurement
            long mb0 = (long)BRResidentMemoryMB();
            NSBundle *b = [NSBundle mainBundle];
            NSString *uniPath = [b pathForResource:@"unicode-props" ofType:@"js" inDirectory:@"js"];
            NSString *acornPath = [b pathForResource:@"acorn" ofType:@"js" inDirectory:@"js"] ?: [b pathForResource:@"acorn" ofType:@"js"];
            NSString *fixPath = [params[@"jsfix"] length] ? params[@"jsfix"] : [b pathForResource:@"jsfix" ofType:@"js"];
            NSString *uni = uniPath ? [NSString stringWithContentsOfFile:uniPath encoding:NSUTF8StringEncoding error:NULL] : nil;
            NSString *acorn = acornPath ? [NSString stringWithContentsOfFile:acornPath encoding:NSUTF8StringEncoding error:NULL] : nil;
            NSString *fix = fixPath ? [NSString stringWithContentsOfFile:fixPath encoding:NSUTF8StringEncoding error:NULL] : nil;
            if (!readable || !acorn || !fix) {
                report = [NSString stringWithFormat:@"jsfix test: cannot read %@", !readable ? input : !acorn ? @"acorn.js" : fixPath];
            } else {
                if (uni.length) [engine evaluateScript:uni sourceName:@"unicode-props.js"];
                [engine evaluateScript:acorn sourceName:@"acorn.js"];
                [engine evaluateScript:fix sourceName:@"jsfix.js"];
                [engine evaluateScript:@"var __brStats = function () { return JSON.stringify(JSFix.stats); };" sourceName:@"stats.js"];
                long mb1 = (long)BRResidentMemoryMB();
                // the peak from a sampling thread (the run itself is one call)
                __block long peak = mb1;
                dispatch_semaphore_t stop = dispatch_semaphore_create(0), stopped = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    for (;;) {
                        long m = (long)BRResidentMemoryMB();
                        if (m > peak) peak = m;
                        if (!dispatch_semaphore_wait(stop, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) break;
                    }
                    dispatch_semaphore_signal(stopped);
                });
                long ms, mb2;
                NSUInteger inLength, outLength;
                NSString *last, *stats;
                @autoreleasepool {   // (the input and output strings go before the last measurements)
                    NSString *text = [NSString stringWithContentsOfFile:input encoding:NSUTF8StringEncoding error:NULL] ?: @"";
                    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
                    NSString *out = [engine callFunction:@"JSFix.run" arguments:@[text, opts]];
                    ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000);
                    dispatch_semaphore_signal(stop);
                    dispatch_semaphore_wait(stopped, DISPATCH_TIME_FOREVER);
                    mb2 = (long)BRResidentMemoryMB();
                    last = [engine callFunction:@"JSFix.last" arguments:@[]] ?: @"?";
                    stats = [engine callFunction:@"__brStats" arguments:@[]] ?: @"?";
                    inLength = text.length;
                    outLength = out.length;
                }
                [engine collectGarbage];
                long mb3 = (long)BRResidentMemoryMB();
                [engine releaseContextNow];
                long mb4 = (long)BRResidentMemoryMB();
                report = [NSString stringWithFormat:@"jsfix test %@ (%@, jsfix %@): %ld ms, %lu -> %lu chars (%@); resident %ld MB, with jsfix loaded %ld, "
                          "peak %ld (+%ld), after the run %ld, after GC %ld, context released %ld; stats %@",
                          input.lastPathComponent, opts, fixPath.lastPathComponent, ms, (unsigned long)inLength, (unsigned long)outLength, last,
                          mb0, mb1, peak, peak - mb1, mb2, mb3, mb4, stats];
            }
            [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            BRLog(@"%@", report);
        }
    }];
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
                                 @"object-fit-images", @"shims", @"regexp-shim", @"shims-extra"]) {
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

+ (NSData *)workerPolyfills
{
    static NSData *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableData *d = [NSMutableData data];
        for (NSString *name in @[@"core-js-custom", @"regenerator-runtime", @"fetch", @"worker-shims", @"regexp-shim"]) {
            NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"js" inDirectory:@"js"];
            if (!path) path = [[NSBundle mainBundle] pathForResource:name ofType:@"js"];
            NSData *part = path ? [NSData dataWithContentsOfFile:path] : nil;
            if (!part.length) continue;
            [d appendData:part];
            [d appendData:[@"\n;\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        bundle = d;
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
        NSUInteger generation = g_workGeneration;
        [[BRJSEngine transpiler] performAsync:^{
            @autoreleasepool {
                if (generation != g_workGeneration) { completion(data, charset); return; }   // (the page load was stopped)
                NSData *lowered = [BRSettings transpileEnabled] ? [self transpiledScript:data charset:charset url:sourceURL module:module] : nil;
                if (lowered) completion(lowered, @"utf-8");
                else completion(data, charset);
            }
        }];
        return;
    }
    NSUInteger generation = g_workGeneration;
    [[BRJSEngine shared] performAsync:^{
        @autoreleasepool {
            if (generation != g_workGeneration) { completion(data, charset); return; }   // (the page load was stopped)
            // (big documents and stylesheets wait for room like scripts, but are always rewritten)
            if (data.length > 256 * 1024)
                [BRMemory waitForAvailableMB:BRRoomFloorMB + (long)(data.length * BRRoomPerMBDocument / (1024 * 1024)) timeout:15
                                      reason:[NSString stringWithFormat:@"rewriting %@ (%lu KB)", kind, (unsigned long)(data.length >> 10)] engine:[BRJSEngine shared]];
            [BRMemory setActivity:[NSString stringWithFormat:@"rewriting %@ %@ (%lu KB)", kind, (sourceURL ?: pageURL).lastPathComponent ?: @"",
                                   (unsigned long)(data.length >> 10)] forKey:@"css"];
            NSData *outData = [self rewrittenData:data kind:kind charset:charset pageURL:pageURL mainFrame:mainFrame];
            [BRMemory setActivity:nil forKey:@"css"];
            [[BRJSEngine shared] releaseWhenIdleFor:BRRewriterIdleRelease aboveMB:BRRewriterIdleReleaseAboveMB];
            if (outData) completion(outData, @"utf-8");
            else completion(data, charset);
        }
    }];
}

// the rewriter's engine queue only: the rewritten document or stylesheet in UTF-8, nil to keep the original
- (NSData *)rewrittenData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL mainFrame:(BOOL)mainFrame
{
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    NSString *used = nil;
    if (![self ensureLoaded]) return nil;
    if (data.length > 200000 && [[NSUserDefaults standardUserDefaults] boolForKey:@"BRDumpRewriteInputs"]) {
        // debugging: big inputs as they came from the network, Caches/rewrite-inputs/<host>-<length>.<kind>
        NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:@"rewrite-inputs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [data writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu.%@", pageURL.host ?: @"page", (unsigned long)data.length, kind]] atomically:NO];
    }
    NSString *declared = charset.length ? charset : BRSniffCharset(data, kind);
    NSString *text = BRDecode(data, declared, &used);
    if (!text) return nil;
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
    if (!result.length) return nil;
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSString *out = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"out"] : nil;
    if (![out isKindOfClass:[NSString class]]) return nil;
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
    return outData;
}

@end
