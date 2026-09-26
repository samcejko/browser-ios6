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
// (measured: lowering a 1-1.5 MB script function by function takes 45-75 MB, Vimeo's 3.3 MB chunk 125 MB while the
// page kept growing next to it; rewriting takes less)
static const long BRRoomFloorMB = 55, BRRoomPerMBScript = 45, BRRoomPerMBDocument = 25;
// bumped when a page load is stopped for lack of memory: queued work of that page is dropped
static volatile NSUInteger g_workGeneration;
static NSString *BRPageKey(NSURL *url);
// The bundle is cached by pages for a year, so its URL carries a checksum of the content: a new
// build with new polyfills gets a new URL instead of the old cached bundle. It is a path on the page's own host
// (answered by BRURLProtocol for every host): from another origin, an error thrown in a callback run by the
// polyfills (promise jobs, timers) reached the page only as "Script error.".
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

// the text of factory n of a webpack chunk kept for later (base = "<crc>-<length>" of the chunk; see jsfix.js LAZY_*)
static NSString *BRLazyPartPath(NSString *base, long n)
{
    return [BRTranspiledDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@s%ld-%@.js", base, n, BRTranspileTag()]];
}

@implementation BRCSSRewriter {
    NSMutableDictionary *_noRoom;       // script key -> when it did not fit in memory (not waited for again soon)
    BOOL _lastNoRoom;                   // (transpiler queue) the last transpiledScript: left as it was for lack of memory
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

// "/*br-page:{"calc":"...","trans":"..."}*/" (or "<!--br-page:...-->") right before the manifest: the properties a
// document gives -webkit-calc() values and the ones it transitions (see guardCalcTransitions in cssfix.js). They join
// the page's " calc" / " trans" entries, which the page's later documents are rewritten with; a cached copy is not
// rewritten again, so its comment is the only way its findings reach them.
- (void)registerPageStateInData:(NSData *)data before:(NSUInteger)limit pageURL:(NSURL *)pageURL
{
    if (limit > data.length || limit < 16) return;
    NSUInteger from = limit > 16384 ? limit - 16384 : 0;
    NSRange marker = [data rangeOfData:[@"br-page:{" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(from, limit - from)];
    if (marker.location == NSNotFound || marker.location < 2) return;
    const char *bytes = data.bytes;
    if (!(bytes[marker.location - 2] == '/' && bytes[marker.location - 1] == '*') && !(marker.location >= 4 && memcmp(bytes + marker.location - 4, "<!--", 4) == 0)) return;
    NSUInteger start = marker.location + 8;   // at the "{"
    NSRange end = [data rangeOfData:[@"}" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(start, limit - start)];
    if (end.location == NSNotFound) return;
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(start, end.location + 1 - start)] options:0 error:NULL];
    if (![state isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *vars = [self varsForPage:BRPageKey(pageURL) create:YES];
    @synchronized (self) {
        for (NSString *kind in @[@"calc", @"trans"]) {
            NSString *names = state[kind];
            if (![names isKindOfClass:[NSString class]] || !names.length) continue;
            NSString *entry = [@" " stringByAppendingString:kind];
            NSString *old = [vars[entry] isKindOfClass:[NSString class]] ? vars[entry] : @"";
            NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSetWithArray:[old componentsSeparatedByString:@" "]];
            [set addObjectsFromArray:[names componentsSeparatedByString:@" "]];
            [set removeObject:@""];
            vars[entry] = [set.array componentsJoinedByString:@" "];
        }
    }
}

- (void)registerManifestInData:(NSData *)data pageURL:(NSURL *)pageURL sourceURL:(NSURL *)sourceURL
{
    if (data.length < 20 || !pageURL) return;
    // the comment sits at the very end: "/*br-manifest:{...}*/" or "<!--br-manifest:{...}-->"; with the custom
    // property entries of a big framework it can be several hundred KB
    NSData *markerData = [@"br-manifest:" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange marker = [data rangeOfData:markerData options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    // (the calc / transition findings come just before it, or last when there is no manifest)
    NSUInteger stateLimit = data.length;
    if (marker.location != NSNotFound) stateLimit = marker.location >= 4 && memcmp((const char *)data.bytes + marker.location - 4, "<!--", 4) == 0 ? marker.location - 4 : marker.location >= 2 ? marker.location - 2 : marker.location;
    [self registerPageStateInData:data before:stateLimit pageURL:pageURL];
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
        // (a page without entries still has its " calc" / " trans" findings, which the shims read from the vars)
        else out = @{ @"has": @[], @"cq": @[], @"dv": @[], @"pt": @[], @"cv": @[], @"sc": @[], @"vars": rootVars };
    }
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
    _lastNoRoom = NO;
    unsigned long crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef *)data.bytes, (uInt)data.length);
    // (a module's registration names its URL: the key has it too)
    if (module) { NSData *u = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding]; if (u.length) crc = crc32(crc, (const Bytef *)u.bytes, (uInt)u.length); }
    NSString *key = [NSString stringWithFormat:@"%08lx-%lx%@-%@", crc, (unsigned long)data.length, module ? @"m" : @"", BRTranspileTag()];
    NSString *dir = BRTranspiledDirectory();
    NSString *path = [dir stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"js"]];
    BOOL private = [BRSettings privateMode];
    NSString *base = [NSString stringWithFormat:@"%08lx-%lx", crc, (unsigned long)data.length];
    NSData *cached = [_transpiled objectForKey:key];
    if (!cached && !private) {
        cached = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        if (cached) {
            [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: [NSDate date] } ofItemAtPath:path error:NULL];   // recently used
            [_transpiled setObject:cached forKey:key cost:cached.length];
        }
    }
    if (cached && ![BRCSSRewriter lazyPartsPresentIn:cached]) {
        // (a chunk whose kept factories were pruned: lowered again)
        [_transpiled removeObjectForKey:key];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        cached = nil;
    }
    if (cached) return cached.length ? cached : nil;
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"script";
    // a webpack chunk keeps its big factories for later: only the rest is lowered now (and needs room)
    NSString *text = nil, *lazyScan = nil;
    long lazyBytes = 0;
    if (!module && !private && data.length >= 256 * 1024 && [self ensureJSFixIn:engine]) {
        NSString *used = nil;
        text = BRDecode(data, charset.length ? charset : nil, &used);
        lazyScan = text ? [engine callFunction:@"JSFix.lazyScan" arguments:@[text]] : nil;
        NSArray *parts = lazyScan.length ? [NSJSONSerialization JSONObjectWithData:[lazyScan dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
        if (![parts isKindOfClass:[NSArray class]]) { parts = nil; lazyScan = nil; }
        for (NSArray *p in parts) if ([p isKindOfClass:[NSArray class]] && p.count == 2) lazyBytes += [p[1] longValue] - [p[0] longValue];
    }
    // room first: when the iPad is short of memory the page waits (loads slower) instead of iOS closing the app; a big
    // script that still does not fit is left as it is (not cached: it is lowered on a later visit). A factory the page
    // waits for (a synchronous request: the page stands still) waits less, and one that did not fit a moment ago does
    // not wait again (a page may ask for it over and over).
    long work = MAX(0L, (long)data.length - lazyBytes);
    long need = BRRoomFloorMB + (long)(work * BRRoomPerMBScript / (1024 * 1024));
    BOOL lazyPart = [url.host isEqualToString:@"ios6-browser.invalid"];
    NSDate *noRoom = nil;
    @synchronized (self) { noRoom = _noRoom[key]; }
    // (a script left as it is breaks the page: better slower, since the page's new requests wait meanwhile anyway; a
    // factory asked for synchronously holds the page's thread, and the screen with it: shorter)
    NSTimeInterval patience = (noRoom && -[noRoom timeIntervalSinceNow] < 120) ? 0 : lazyPart ? 10 : 60;
    BOOL fits = patience > 0 ? [BRMemory waitForAvailableMB:need timeout:patience reason:[NSString stringWithFormat:@"lowering %@ (%lu KB)", name, (unsigned long)(work >> 10)] engine:engine]
                             : [BRMemory availableMB] >= need;
    if (!fits && [BRMemory availableMB] < BRRoomFloorMB + (long)(work * BRRoomPerMBScript / (2 * 1024 * 1024))) {
        BRLog(@"jsfix %@: left unlowered, not enough memory", name);
        @synchronized (self) {
            if (!_noRoom) _noRoom = [NSMutableDictionary dictionary];
            if (_noRoom.count > 64) [_noRoom removeAllObjects];
            _noRoom[key] = [NSDate date];
        }
        _lastNoRoom = YES;
        return nil;
    }
    if (![self ensureJSFixIn:engine]) return nil;
    if (!text) {
        NSString *used = nil;
        text = BRDecode(data, charset.length ? charset : nil, &used);
    }
    if (!text) return nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    long mb0 = (long)BRResidentMemoryMB();
    [BRMemory setActivity:[NSString stringWithFormat:@"transpiling %@ (%lu KB)", name, (unsigned long)(work >> 10)] forKey:@"js"];
    NSString *optsJSON = @"{}";
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    if (url.absoluteString.length) o[@"url"] = url.absoluteString;
    if (module) o[@"module"] = @YES;
    if (lazyScan.length) o[@"lazy"] = base;
    NSData *oj = [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];
    if (oj) optsJSON = [[NSString alloc] initWithData:oj encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *result = [engine callFunction:@"JSFix.run" arguments:@[text, optsJSON]];
    // the factories kept for later go next to the lowered chunk, where the page's stubs ask for them
    NSUInteger kept = 0;
    if (lazyScan.length && [result hasPrefix:@"/*br-lazy:"]) {
        kept = [self storeLazyParts:[engine callFunction:@"JSFix.lazy" arguments:@[]] ofText:text base:base];
        if (!kept) {
            BRLog(@"jsfix %@: the factories kept for later could not be stored", name);
            [BRMemory setActivity:nil forKey:@"js"];
            return nil;
        }
        else BRLog(@"jsfix %@: %lu factories (%ld KB) lowered only when the page needs them", name, (unsigned long)kept, lazyBytes >> 10);
    }
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
            _lastNoRoom = YES;
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

// A lowered chunk that keeps factories for later starts with /*br-lazy:N:<base>*/ and needs their texts: YES when
// they are all there (touched as recently used, the cache prunes by age) or when it keeps none.
+ (BOOL)lazyPartsPresentIn:(NSData *)lowered
{
    static const char mark[] = "/*br-lazy:";
    if (lowered.length < sizeof(mark) + 4 || memcmp(lowered.bytes, mark, sizeof(mark) - 1) != 0) return YES;
    char head[64] = { 0 };
    memcpy(head, (const char *)lowered.bytes + sizeof(mark) - 1, MIN(sizeof(head) - 1, lowered.length - (sizeof(mark) - 1)));
    char *colon = NULL;
    long count = strtol(head, &colon, 10);
    char *close = colon && *colon == ':' ? strstr(colon, "*/") : NULL;
    if (!close || count <= 0) return NO;
    NSString *base = [[NSString alloc] initWithBytes:colon + 1 length:(NSUInteger)(close - colon - 1) encoding:NSASCIIStringEncoding];
    if (!base.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *now = @{ NSFileModificationDate: [NSDate date] };
    for (long i = 0; i < count; i++) if (![fm setAttributes:now ofItemAtPath:BRLazyPartPath(base, i) error:NULL]) return NO;
    return YES;
}

// the transpiler's queue: the texts of the kept factories ("[[start,end],...]" in UTF-16 units of text); how many
- (NSUInteger)storeLazyParts:(NSString *)json ofText:(NSString *)text base:(NSString *)base
{
    NSArray *parts = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (![parts isKindOfClass:[NSArray class]] || !parts.count) return 0;
    [[NSFileManager defaultManager] createDirectoryAtPath:BRTranspiledDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
    NSUInteger n = 0;
    for (NSArray *p in parts) {
        if (![p isKindOfClass:[NSArray class]] || p.count != 2) return 0;
        NSUInteger start = [p[0] unsignedIntegerValue], end = [p[1] unsignedIntegerValue];
        if (end <= start || end > text.length) return 0;
        @autoreleasepool {
            NSData *d = [[text substringWithRange:NSMakeRange(start, end - start)] dataUsingEncoding:NSUTF8StringEncoding];
            if (!d || ![d writeToFile:BRLazyPartPath(base, (long)n) atomically:YES]) return 0;
        }
        n++;
    }
    return n;
}

- (NSData *)lazyModuleForBase:(NSString *)base index:(NSInteger)index
{
    NSString *path = BRLazyPartPath(base, (long)index);
    NSData *src = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!src) { BRLog(@"Lazy factory %@/%ld: its text is gone", base, (long)index); return nil; }
    [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: [NSDate date] } ofItemAtPath:path error:NULL];
    NSMutableData *wrapped = [NSMutableData dataWithCapacity:src.length + 32];
    [wrapped appendBytes:"var __br_lazyValue=(" length:20];
    [wrapped appendData:src];
    [wrapped appendBytes:"\n);" length:3];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://ios6-browser.invalid/lazy/%@/%ld.js", base, (long)index]];
    __block NSData *out = nil;
    __block BOOL noRoom = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    [[BRJSEngine transpiler] performAsync:^{
        @autoreleasepool { out = [self transpiledScript:wrapped charset:@"utf-8" url:url module:NO]; noRoom = _lastNoRoom; }
        dispatch_semaphore_signal(done);
    }];
    BOOL finished = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(240 * NSEC_PER_SEC))) == 0;
    BRLog(@"Lazy factory %@/%ld (%lu KB) asked for by the page: %@ after %ld ms", base, (long)index, (unsigned long)(src.length >> 10),
          !finished ? @"still lowering" : noRoom ? @"no room to lower it" : out ? @"lowered" : @"sent as it is", (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000));
    // (without room the page gets a factory that says so, not megabytes its engine cannot parse)
    if (!finished || noRoom) return [@"var __br_lazyValue=function(){throw new Error(\"This part of the page did not fit in the iPad's memory\")};" dataUsingEncoding:NSUTF8StringEncoding];
    return out ?: wrapped;
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

+ (NSString *)rewriteTag
{
    static NSString *tag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"cssfix" ofType:@"js"];
        NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
        unsigned long crc = crc32(0L, Z_NULL, 0);
        if (d.length) crc = crc32(crc, (const Bytef *)d.bytes, (uInt)d.length);
        tag = [NSString stringWithFormat:@"%08lx-%@", crc, BRTranspileTag()];
    });
    return tag;
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
    const unsigned long long limit = 1024ull * 1024 * 1024;   // (1 GB: every lowering saved is seconds on the next visit)
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
    return g_polyfillURL ?: @"/__br_polyfills.js";
}

+ (NSData *)polyfillBundle
{
    static NSData *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableData *d = [NSMutableData data];
        NSBundle *b = [NSBundle mainBundle];
        // (debugging switch: the page shim logs the real errors of callbacks and promises, see shims-extra.js)
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BRDebugJSErrors"]) [d appendData:[@"window.__brDebugErrors=true;\n" dataUsingEncoding:NSUTF8StringEncoding]];
        // (jsfix-helpers: the transpiler's runtime helpers as globals, for lowered code a page keeps as text and runs
        // later, see tools/gen-helpers.js)
        for (NSString *name in @[@"core-js-custom", @"regenerator-runtime", @"jsfix-helpers", @"fetch", @"intersection-observer", @"resize-observer", @"picturefill",
                                 @"dialog-polyfill", @"object-fit-images", @"shims", @"regexp-shim", @"shims-extra"]) {
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
        g_polyfillURL = [NSString stringWithFormat:@"/__br_polyfills-%08lx.js", crc];
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
        for (NSString *name in @[@"core-js-custom", @"regenerator-runtime", @"jsfix-helpers", @"fetch", @"worker-shims", @"regexp-shim"]) {
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
