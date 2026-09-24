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

@implementation BRCSSRewriter {
    BOOL _loaded;
    BOOL _loadFailed;
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

+ (void)warmUp
{
    BRCSSRewriter *r = [self shared];
    CGRect screen = [UIScreen mainScreen].bounds;
    g_viewportWidth = MIN(screen.size.width, screen.size.height);   // portrait width: the wider layout of the two is fine
    [[BRJSEngine shared] performAsync:^{ [r ensureLoaded]; }];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pageVars = [NSMutableDictionary dictionary];
        _pageOrder = [NSMutableArray array];
        _pageManifests = [NSMutableDictionary dictionary];
        _manifestOrder = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidReset:) name:BRJSEngineDidResetNotification object:nil];
    }
    return self;
}

#pragma mark - Manifest (:has() and @container entries for the page shim)

- (void)registerManifestInData:(NSData *)data pageURL:(NSURL *)pageURL
{
    if (data.length < 20 || !pageURL) return;
    // the comment sits at the very end: "/*br-manifest:{...}*/" or "<!--br-manifest:{...}-->"
    NSUInteger tailLength = MIN(data.length, (NSUInteger)65536);
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - tailLength, tailLength)];
    NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
    if (!text) { text = [[NSString alloc] initWithData:tail encoding:NSISOLatin1StringEncoding]; if (!text) return; }
    NSRange marker = [text rangeOfString:@"br-manifest:" options:NSBackwardsSearch];
    if (marker.location == NSNotFound) return;
    NSString *rest = [text substringFromIndex:marker.location + marker.length];
    NSRange end = [rest rangeOfString:@"*/" options:NSBackwardsSearch];
    if (end.location == NSNotFound) end = [rest rangeOfString:@"-->" options:NSBackwardsSearch];
    if (end.location == NSNotFound) return;
    NSString *json = [[rest substringToIndex:end.location] stringByReplacingOccurrencesOfString:@"-\\u002d" withString:@"--"];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;
    NSString *key = BRPageKey(pageURL);
    @synchronized (self) {
        NSMutableDictionary *m = _pageManifests[key];
        if (!m) {
            m = [@{ @"has": [NSMutableArray array], @"cq": [NSMutableArray array], @"seen": [NSMutableSet set] } mutableCopy];
            _pageManifests[key] = m;
            [_manifestOrder addObject:key];
            while (_manifestOrder.count > BRMaxPagesRemembered) {
                [_pageManifests removeObjectForKey:_manifestOrder[0]];
                [_manifestOrder removeObjectAtIndex:0];
            }
        }
        NSMutableSet *seen = m[@"seen"];
        for (NSString *kind in @[@"has", @"cq"]) {
            NSArray *entries = parsed[kind];
            if (![entries isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *e in entries) {
                if (![e isKindOfClass:[NSDictionary class]] || ![e[@"h"] isKindOfClass:[NSString class]]) continue;
                NSString *entryId = [kind stringByAppendingString:e[@"h"]];
                if ([seen containsObject:entryId]) continue;
                [seen addObject:entryId];
                [m[kind] addObject:e];
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
        if (m) out = @{ @"has": [m[@"has"] copy], @"cq": [m[@"cq"] copy] };
    }
    if (!out) out = @{ @"has": @[], @"cq": @[] };
    return [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)engineDidReset:(NSNotification *)note
{
    _loaded = NO;   // posted on the engine thread
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
    if (!completion) return;
    [[BRJSEngine shared] performAsync:^{
        @autoreleasepool {
            NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
            NSString *used = nil;
            if ([kind isEqualToString:@"js"]) {
                // no transpiling on this hardware (see the build workflow); scripts pass through unchanged
                completion(data, charset);
                return;
            }
            if (![self ensureLoaded]) { completion(data, charset); return; }
            NSString *declared = charset.length ? charset : BRSniffCharset(data, kind);
            NSString *text = BRDecode(data, declared, &used);
            if (!text) { completion(data, charset); return; }
            NSString *pageKey = BRPageKey(pageURL);
            NSMutableDictionary *vars = [self varsForPage:pageKey create:YES];
            NSString *varsJSON = @"{}";
            if (vars.count) {
                NSData *j = [NSJSONSerialization dataWithJSONObject:vars options:0 error:NULL];
                if (j) varsJSON = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] ?: @"{}";
            }
            NSString *optionsJSON = @"{}";
            {
                NSMutableDictionary *opts = [@{ @"transpile": @NO, @"pageURL": pageURL.absoluteString ?: @"", @"viewportWidth": @(g_viewportWidth) } mutableCopy];
                // iframes (mostly ads and widgets) do not get the 500 KB bundle: memory on a 512 MB device
                if ([kind isEqualToString:@"html"] && mainFrame && [BRSettings jsFixEnabled]) opts[@"polyfillURL"] = [BRCSSRewriter polyfillURLString];
                if ([kind isEqualToString:@"html"] && [BRSettings hideCookieBanners]) opts[@"hideCookieBanners"] = @YES;
                NSData *oj = [NSJSONSerialization dataWithJSONObject:opts options:0 error:NULL];
                if (oj) optionsJSON = [[NSString alloc] initWithData:oj encoding:NSUTF8StringEncoding] ?: @"{}";
            }
            NSString *result = [[BRJSEngine shared] callFunction:@"CSSFix.run" arguments:@[kind, text, varsJSON, optionsJSON]];
            if (!result.length) { completion(data, charset); return; }
            NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            NSString *out = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"out"] : nil;
            if (![out isKindOfClass:[NSString class]]) { completion(data, charset); return; }
            NSDictionary *newVars = parsed[@"vars"];
            if ([newVars isKindOfClass:[NSDictionary class]] && newVars.count) {
                for (NSString *name in newVars) {
                    id value = newVars[name];
                    if ([value isKindOfClass:[NSString class]]) vars[name] = value;
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
