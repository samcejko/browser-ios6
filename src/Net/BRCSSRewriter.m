#import "BRCSSRewriter.h"
#import "BRJSEngine.h"
#import "BRSettings.h"
#import "BRCommon.h"

static const NSUInteger BRMaxPagesRemembered = 8;
static NSString * const BRPolyfillURL = @"https://ios6-browser.invalid/polyfills.js";

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
}

+ (instancetype)shared
{
    static BRCSSRewriter *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [[BRCSSRewriter alloc] init]; });
    return r;
}

+ (void)warmUp
{
    BRCSSRewriter *r = [self shared];
    [[BRJSEngine shared] performAsync:^{ [r ensureLoaded]; }];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pageVars = [NSMutableDictionary dictionary];
        _pageOrder = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidReset:) name:BRJSEngineDidResetNotification object:nil];
    }
    return self;
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
    return BRPolyfillURL;
}

+ (NSData *)polyfillBundle
{
    static NSData *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableData *d = [NSMutableData data];
        NSBundle *b = [NSBundle mainBundle];
        for (NSString *name in @[@"core-js-custom", @"fetch", @"intersection-observer", @"resize-observer", @"picturefill", @"dialog-polyfill",
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
        BRLog(@"Polyfill bundle assembled: %lu KB", (unsigned long)(d.length / 1024));
    });
    return bundle;
}

- (void)rewriteData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL
         completion:(BRRewriteCompletion)completion
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
            if ([kind isEqualToString:@"html"] && [BRSettings jsFixEnabled]) {
                NSDictionary *opts = @{ @"polyfillURL": BRPolyfillURL, @"transpile": @NO, @"pageURL": pageURL.absoluteString ?: @"" };
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
