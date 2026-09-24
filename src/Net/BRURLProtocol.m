#import "BRURLProtocol.h"
#import "BRHTTPRequest.h"
#import "BRAdBlock.h"
#import "BRCSSRewriter.h"
#import "BRFontConverter.h"
#import "BRImageConverter.h"
#import "BRCommon.h"
#import "BRSettings.h"

static const NSUInteger BRMaxRewriteBody = 4 * 1024 * 1024;

static void BRSetHeaderField(NSMutableDictionary *fields, NSString *name, NSString *value)
{
    NSMutableArray *remove = [NSMutableArray array];
    for (NSString *k in fields) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) [remove addObject:k];
    }
    [fields removeObjectsForKeys:remove];
    if (value) fields[name] = value;
}

// 1x1 transparent GIF served for blocked image requests
static const uint8_t BRBlankGIF[] = {
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B
};

static NSString * const BRHandledKey = @"BRURLProtocolHandled";
NSString * const BRPageProgressNotification = @"BRPageProgressNotification";

#pragma mark - Page progress and main document facts

static NSURL *g_lastMainURL;
static NSString *g_lastMainTLS;
static NSString *g_lastMainContentType;
static NSString *g_progressPage;        // main document URL string of the page being counted
static NSUInteger g_progressStarted, g_progressFinished;
static CFAbsoluteTime g_progressPosted;

static void BRPostProgress(BOOL force)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now - g_progressPosted < 0.15) return;
    g_progressPosted = now;
    NSDictionary *info = @{ @"page": g_progressPage ?: @"", @"started": @(g_progressStarted), @"finished": @(g_progressFinished) };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BRPageProgressNotification object:nil userInfo:info];
    });
}

// Called for every request that reaches the network: counts requests per page for the progress bar.
static void BRProgressRequestStarted(NSURLRequest *request)
{
    NSString *page = request.mainDocumentURL.absoluteString ?: request.URL.absoluteString;
    BOOL isMain = !request.mainDocumentURL || [request.URL isEqual:request.mainDocumentURL];
    @synchronized ([BRURLProtocol class]) {
        if (isMain || ![page isEqualToString:g_progressPage]) {
            if (!isMain && g_progressPage && ![page isEqualToString:g_progressPage]) return;   // a stray load of an old page
            g_progressPage = page;
            g_progressStarted = 0;
            g_progressFinished = 0;
        }
        g_progressStarted++;
    }
    BRPostProgress(isMain);
}

static void BRProgressRequestFinished(NSURLRequest *request)
{
    NSString *page = request.mainDocumentURL.absoluteString ?: request.URL.absoluteString;
    BOOL post = NO;
    @synchronized ([BRURLProtocol class]) {
        if ([page isEqualToString:g_progressPage] && g_progressFinished < g_progressStarted) {
            g_progressFinished++;
            post = YES;
        }
    }
    if (post) BRPostProgress(g_progressFinished == g_progressStarted);
}
static NSString * const BRCacheStoredAtKey = @"BRStoredAt";     // NSCachedURLResponse.userInfo
static NSString * const BRCacheMaxAgeKey = @"BRMaxAge";
static const NSUInteger BRMaxCacheableBody = 2 * 1024 * 1024;

#pragma mark - HTTP authentication (Basic)

static NSString *BRHeader(NSDictionary *headers, NSString *name);

static BRAuthenticationHandler g_authHandler;
static NSMutableDictionary *g_credentials;          // "https://host:443" -> "Basic base64(user:password)", this session only
static dispatch_semaphore_t g_authPromptLock;       // one login dialog at a time

static NSString *BRAuthKeyForURL(NSURL *url)
{
    NSString *scheme = [url.scheme lowercaseString] ?: @"http";
    NSInteger port = url.port ? [url.port integerValue] : ([scheme isEqualToString:@"https"] ? 443 : 80);
    return [NSString stringWithFormat:@"%@://%@:%ld", scheme, [url.host lowercaseString] ?: @"", (long)port];
}

static NSString *BRStoredAuthorization(NSString *key)
{
    @synchronized ([BRURLProtocol class]) { return key ? g_credentials[key] : nil; }
}

static void BRStoreAuthorization(NSString *key, NSString *value)
{
    if (!key) return;
    @synchronized ([BRURLProtocol class]) {
        if (!g_credentials) g_credentials = [NSMutableDictionary dictionary];
        if (value) g_credentials[key] = value; else [g_credentials removeObjectForKey:key];
    }
}

static NSString *BRRealmFromChallenge(NSString *challenge)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"realm\\s*=\\s*\"?([^\",]*)\"?" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *m = challenge.length ? [re firstMatchInString:challenge options:0 range:NSMakeRange(0, challenge.length)] : nil;
    return (m && m.numberOfRanges > 1) ? [challenge substringWithRange:[m rangeAtIndex:1]] : @"";
}

// Third-party check for cookies: the request host must share the registrable domain (last two labels) with the page.
static BOOL BRSameSite(NSURL *a, NSURL *b)
{
    NSString *ha = [a.host lowercaseString], *hb = [b.host lowercaseString];
    if (!ha.length || !hb.length) return YES;
    if ([ha isEqualToString:hb]) return YES;
    NSArray *pa = [ha componentsSeparatedByString:@"."], *pb = [hb componentsSeparatedByString:@"."];
    if (pa.count < 2 || pb.count < 2) return NO;
    return [pa[pa.count - 1] isEqualToString:pb[pb.count - 1]] && [pa[pa.count - 2] isEqualToString:pb[pb.count - 2]];
}

static BOOL BRLooksLikeImageRequest(NSURLRequest *request)
{
    NSString *accept = [BRHeader(request.allHTTPHeaderFields, @"Accept") lowercaseString] ?: @"";
    if ([accept hasPrefix:@"image/"]) return YES;
    NSString *ext = [[request.URL.path pathExtension] lowercaseString] ?: @"";
    return [@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"bmp", @"avif", @"jfif"] containsObject:ext];
}

#pragma mark - Helpers

// Case-insensitive header lookup (NSHTTPURLResponse.allHeaderFields is case-insensitive in practice, plain dictionaries are not).
static NSString *BRHeader(NSDictionary *headers, NSString *name)
{
    id v = headers[name];
    if (v) return [v description];
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) return [headers[k] description];
    }
    return nil;
}

static NSDate *BRParseHTTPDate(NSString *s)
{
    if (!s.length) return nil;
    static NSArray *formatters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLocale *posix = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
        NSMutableArray *fs = [NSMutableArray array];
        for (NSString *fmt in @[@"EEE, dd MMM yyyy HH:mm:ss zzz", @"EEEE, dd-MMM-yy HH:mm:ss zzz", @"EEE MMM d HH:mm:ss yyyy"]) {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.locale = posix;
            f.timeZone = gmt;
            f.dateFormat = fmt;
            [fs addObject:f];
        }
        formatters = fs;
    });
    @synchronized (formatters) {   // NSDateFormatter is not thread safe on iOS 6
        for (NSDateFormatter *f in formatters) {
            NSDate *d = [f dateFromString:s];
            if (d) return d;
        }
    }
    return nil;
}

// Seconds a 200 response may be served without revalidation: > 0 fresh for that long,
// 0 = always revalidate (validators present), -1 = do not cache at all.
static NSTimeInterval BRMaxAgeForResponse(NSDictionary *headers, BOOL hasSetCookie)
{
    NSString *cc = [BRHeader(headers, @"Cache-Control") lowercaseString] ?: @"";
    NSString *pragma = [BRHeader(headers, @"Pragma") lowercaseString] ?: @"";
    NSString *vary = BRHeader(headers, @"Vary");
    BOOL hasValidator = BRHeader(headers, @"ETag") != nil || BRHeader(headers, @"Last-Modified") != nil;
    if ([cc rangeOfString:@"no-store"].location != NSNotFound) return -1;
    if ([vary isEqualToString:@"*"]) return -1;
    if ([cc rangeOfString:@"no-cache"].location != NSNotFound || [pragma rangeOfString:@"no-cache"].location != NSNotFound) {
        return hasValidator ? 0 : -1;
    }
    NSRange r = [cc rangeOfString:@"max-age="];
    if (r.location != NSNotFound) {
        NSTimeInterval v = [[cc substringFromIndex:r.location + r.length] doubleValue];
        if (v > 0) return v;
        return hasValidator ? 0 : -1;
    }
    NSDate *date = BRParseHTTPDate(BRHeader(headers, @"Date")) ?: [NSDate date];
    NSString *expires = BRHeader(headers, @"Expires");
    if (expires.length) {
        NSDate *e = BRParseHTTPDate(expires);
        NSTimeInterval v = e ? [e timeIntervalSinceDate:date] : 0;
        if (v > 0) return v;
        return hasValidator ? 0 : -1;
    }
    NSDate *lm = BRParseHTTPDate(BRHeader(headers, @"Last-Modified"));
    if (lm && !hasSetCookie) {
        // Heuristic freshness like browsers: 10 % of the age, at most one day.
        NSTimeInterval v = [date timeIntervalSinceDate:lm] * 0.1;
        return MIN(MAX(v, 0), 24 * 3600);
    }
    return hasValidator ? 0 : -1;
}

static BOOL BRCachedResponseIsFresh(NSCachedURLResponse *c)
{
    NSNumber *storedAt = c.userInfo[BRCacheStoredAtKey];
    NSNumber *maxAge = c.userInfo[BRCacheMaxAgeKey];
    if (!storedAt || !maxAge) return NO;
    return [NSDate timeIntervalSinceReferenceDate] - [storedAt doubleValue] < [maxAge doubleValue];
}

static NSData *BRReadBodyStream(NSInputStream *stream)
{
    if (!stream) return nil;
    NSMutableData *d = [NSMutableData data];
    [stream open];
    uint8_t buf[16384];
    for (;;) {
        NSInteger n = [stream read:buf maxLength:sizeof(buf)];
        if (n <= 0) break;
        [d appendBytes:buf length:(NSUInteger)n];
    }
    [stream close];
    return d;
}

@interface BRURLProtocol ()
@property (nonatomic, strong) NSThread *clientThread;
@property (nonatomic, strong) NSArray *clientModes;
@property (nonatomic, strong) BRHTTPRequest *httpRequest;
@property (nonatomic) BOOL stopped;             // stopLoading was called
@property (nonatomic) BOOL counted;             // counted as started in the page progress
@property (nonatomic) BOOL done;                // finished, failed or redirected: nothing more goes to the client
@property (nonatomic, strong) NSCachedURLResponse *staleCached;   // stale cache entry being revalidated
@property (nonatomic, strong) NSMutableData *cacheBody;
@property (nonatomic) NSTimeInterval cacheMaxAge;
@property (nonatomic, strong) NSHTTPURLResponse *response;
// CSS/HTML rewriting: the body is buffered and the response is sent once the rewritten data is ready
@property (nonatomic, copy) NSString *rewriteKind;
@property (nonatomic, strong) NSMutableData *rewriteBuffer;
@property (nonatomic, copy) NSString *rewriteCharset;
@property (nonatomic, strong) NSDictionary *pendingHeaderFields;
@property (nonatomic) NSInteger pendingStatus;
// what went on the wire (a 401 answer repeats the request with credentials)
@property (nonatomic, copy) NSString *sentMethod;
@property (nonatomic, strong) NSDictionary *sentHeaders;
@property (nonatomic, strong) NSData *sentBody;
@property (nonatomic) BOOL thirdParty;          // cookies are neither sent nor stored
@property (nonatomic) BOOL authAttempted;       // the user was asked once for this request
@end

@implementation BRURLProtocol

+ (void)registerProtocol
{
    [NSURLProtocol registerClass:self];
}

+ (void)setAuthenticationHandler:(BRAuthenticationHandler)handler
{
    @synchronized (self) {
        g_authHandler = [handler copy];
        if (!g_authPromptLock) g_authPromptLock = dispatch_semaphore_create(1);
    }
}

+ (void)forgetCredentials
{
    @synchronized (self) { [g_credentials removeAllObjects]; }
}

+ (NSURL *)lastMainDocumentURL { @synchronized (self) { return g_lastMainURL; } }
+ (NSString *)lastMainDocumentTLSInfo { @synchronized (self) { return g_lastMainTLS; } }
+ (NSString *)lastMainDocumentContentType { @synchronized (self) { return g_lastMainContentType; } }

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    NSString *scheme = [request.URL.scheme lowercaseString];
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    if (![request.URL.host length]) return NO;
    if ([NSURLProtocol propertyForKey:BRHandledKey inRequest:request]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

#pragma mark - Client thread

// The NSURLProtocolClient is talked to on the thread that called -startLoading, in the run loop
// modes that were active at that time (the same pattern as Apple's CustomHTTPProtocol sample).
- (void)performOnClientThread:(dispatch_block_t)block
{
    if (!self.clientThread || !block) return;
    [self performSelector:@selector(br_runBlock:) onThread:self.clientThread withObject:(id)[block copy] waitUntilDone:NO modes:self.clientModes];
}

- (void)br_runBlock:(dispatch_block_t)block
{
    if (self.stopped) return;
    block();
}

#pragma mark - Loading

- (void)startLoading
{
    self.clientThread = [NSThread currentThread];
    NSString *mode = [[NSRunLoop currentRunLoop] currentMode];
    NSMutableArray *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    if (mode.length && ![mode isEqualToString:NSDefaultRunLoopMode]) [modes addObject:mode];
    self.clientModes = modes;

    NSURLRequest *request = self.request;
    NSURL *url = request.URL;
    NSString *method = request.HTTPMethod.length ? [request.HTTPMethod uppercaseString] : @"GET";
    BOOL isGET = [method isEqualToString:@"GET"];
    NSURLRequestCachePolicy policy = request.cachePolicy;

    // 0a. Our own resources (polyfill bundle) live on a reserved host name that never resolves
    if ([[url.host lowercaseString] isEqualToString:@"ios6-browser.invalid"]) {
        [self serveInternalResource];
        return;
    }

    // 0b. Ad and tracker blocking (never for the main document)
    BOOL subresource = request.mainDocumentURL && ![url isEqual:request.mainDocumentURL];
    if (subresource && [BRSettings adBlockEnabled] && ![BRSettings adBlockDisabledForHost:request.mainDocumentURL.host] && [BRAdBlock shouldBlockHost:url.host]) {
        [BRAdBlock noteBlockedRequest];
        [self serveBlockedResponse];
        return;
    }
    // 0c. Data saver: images are answered with a blank picture
    if (subresource && ![BRSettings loadImages] && BRLooksLikeImageRequest(request)) {
        [self serveBlockedResponse];
        return;
    }
    self.thirdParty = subresource && [BRSettings blockThirdPartyCookies] && !BRSameSite(url, request.mainDocumentURL);

    // 1. Cache
    if (isGET && policy != NSURLRequestReloadIgnoringLocalCacheData && policy != NSURLRequestReloadIgnoringLocalAndRemoteCacheData) {
        NSCachedURLResponse *cached = [[NSURLCache sharedURLCache] cachedResponseForRequest:request];
        if (cached && [cached.response isKindOfClass:[NSHTTPURLResponse class]] && cached.userInfo[BRCacheStoredAtKey]) {
            if (BRCachedResponseIsFresh(cached) || policy == NSURLRequestReturnCacheDataElseLoad || policy == NSURLRequestReturnCacheDataDontLoad) {
                [self serveCachedResponse:cached];
                return;
            }
            self.staleCached = cached;
        }
        if (policy == NSURLRequestReturnCacheDataDontLoad) {
            [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable
                                                userInfo:@{ NSURLErrorFailingURLStringErrorKey: url.absoluteString ?: @"" }]];
            return;
        }
    }

    // 2. Request headers: WebKit's own, cookies from the shared jar, validators for a stale cache entry
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:request.allHTTPHeaderFields ?: @{}];
    if (self.thirdParty) {
        [headers removeObjectForKey:@"Cookie"];
    } else if (request.HTTPShouldHandleCookies && !BRHeader(headers, @"Cookie")) {
        NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
        if (cookies.count) {
            NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
            if (cookieHeader.length) headers[@"Cookie"] = cookieHeader;
        }
    }
    if (self.staleCached) {
        NSDictionary *old = ((NSHTTPURLResponse *)self.staleCached.response).allHeaderFields;
        NSString *etag = BRHeader(old, @"ETag");
        NSString *lastModified = BRHeader(old, @"Last-Modified");
        if (etag.length) headers[@"If-None-Match"] = etag;
        if (lastModified.length) headers[@"If-Modified-Since"] = lastModified;
    }
    NSString *stored = BRStoredAuthorization(BRAuthKeyForURL(url));
    if (stored && !BRHeader(headers, @"Authorization")) headers[@"Authorization"] = stored;
    NSData *body = request.HTTPBody ?: BRReadBodyStream(request.HTTPBodyStream);

    // 3. Go
    BOOL mainDocument = !request.mainDocumentURL || [url isEqual:request.mainDocumentURL];
    if (mainDocument) BRLog(@"%@ %@ (main document)", method, url.absoluteString);
    self.counted = YES;
    BRProgressRequestStarted(request);
    [self sendRequestWithMethod:method headers:headers body:body];
}

// Starts (or restarts, after a 401) the network request. Callbacks of a superseded request are ignored.
- (void)sendRequestWithMethod:(NSString *)method headers:(NSDictionary *)headers body:(NSData *)body
{
    NSURLRequest *request = self.request;
    NSURL *url = request.URL;
    self.sentMethod = method;
    self.sentHeaders = headers;
    self.sentBody = body;
    BRHTTPRequest *r = [[BRHTTPRequest alloc] initWithMethod:method URL:url];
    r.headers = headers;
    r.body = body;
    r.verifyTLS = [BRSettings verifyTLS];
    r.connectTimeout = 20;
    r.readTimeout = request.timeoutInterval > 0 ? MAX(20, request.timeoutInterval) : 60;
    r.highPriority = !request.mainDocumentURL || [url isEqual:request.mainDocumentURL];
    __weak BRURLProtocol *weakSelf = self;
    __weak BRHTTPRequest *weakR = r;
    r.onHeaders = ^(NSInteger status, NSDictionary *hdrs) { BRURLProtocol *s = weakSelf; if (s && s.httpRequest == weakR) [s handleHeaders:status]; };
    r.onData = ^(NSData *chunk) { BRURLProtocol *s = weakSelf; if (s && s.httpRequest == weakR) [s handleData:chunk]; };
    r.onComplete = ^(NSError *error) { BRURLProtocol *s = weakSelf; if (s && s.httpRequest == weakR) [s handleComplete:error]; };
    self.httpRequest = r;
    [r start];
}

// A 401 with a Basic challenge: ask the user (once per request) and repeat the request with the answer.
// Runs on the request's worker thread, which waits for the dialog. Returns YES when the request was restarted.
- (BOOL)handleAuthenticationChallenge:(NSString *)challenge
{
    if (self.authAttempted || !g_authHandler || !g_authPromptLock) return NO;
    self.authAttempted = YES;
    NSURL *url = self.request.URL;
    NSString *key = BRAuthKeyForURL(url);
    NSString *realm = BRRealmFromChallenge(challenge);
    if (BRHeader(self.sentHeaders, @"Authorization")) BRStoreAuthorization(key, nil);   // stored credentials were refused
    dispatch_semaphore_wait(g_authPromptLock, DISPATCH_TIME_FOREVER);
    NSString *stored = BRStoredAuthorization(key);   // another request may have asked meanwhile
    if (!stored && !self.stopped) {
        dispatch_semaphore_t answered = dispatch_semaphore_create(0);
        __block NSString *user = nil, *password = nil;
        BRAuthenticationHandler handler = g_authHandler;
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(url.host ?: @"", realm, ^(NSString *u, NSString *p) { user = u; password = p; dispatch_semaphore_signal(answered); });
        });
        dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)));
        if (user.length) {
            NSData *pair = [[NSString stringWithFormat:@"%@:%@", user, password ?: @""] dataUsingEncoding:NSUTF8StringEncoding];
            stored = [@"Basic " stringByAppendingString:BRBase64Encode(pair)];
            BRStoreAuthorization(key, stored);
        }
    }
    dispatch_semaphore_signal(g_authPromptLock);
    if (!stored || self.stopped) return NO;
    BRLog(@"Authenticating to %@ (%@)", url.host, realm);
    NSMutableDictionary *headers = [self.sentHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *k in [headers allKeys]) if ([k caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) [headers removeObjectForKey:k];
    headers[@"Authorization"] = stored;
    [self.httpRequest cancel];
    [self sendRequestWithMethod:self.sentMethod headers:headers body:self.sentBody];
    return YES;
}

- (void)noteFinishedForProgress
{
    if (!self.counted) return;
    self.counted = NO;
    BRProgressRequestFinished(self.request);
}

- (void)stopLoading
{
    self.stopped = YES;
    [self.httpRequest cancel];
    self.httpRequest = nil;
    [self noteFinishedForProgress];
}

#pragma mark - Worker thread callbacks

- (NSDictionary *)headerFieldsForWebKit
{
    BRHTTPRequest *r = self.httpRequest;
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSArray *pair in r.responseHeaderPairs) {
        NSString *name = pair[0];
        NSString *value = pair[1];
        NSString *lname = [name lowercaseString];
        if ([lname isEqualToString:@"connection"] || [lname isEqualToString:@"transfer-encoding"] || [lname isEqualToString:@"keep-alive"]) continue;
        if (r.decodedContentEncoding && ([lname isEqualToString:@"content-encoding"] || [lname isEqualToString:@"content-length"])) continue;
        NSString *existingKey = nil;
        for (NSString *k in fields) {
            if ([k caseInsensitiveCompare:name] == NSOrderedSame) { existingKey = k; break; }
        }
        if (existingKey) fields[existingKey] = [NSString stringWithFormat:@"%@, %@", fields[existingKey], value];
        else fields[name] = value;
    }
    return fields;
}

- (void)handleHeaders:(NSInteger)status
{
    if (self.stopped || self.done) return;
    BRHTTPRequest *r = self.httpRequest;
    if (!r) return;
    NSURL *url = self.request.URL;

    // HTTP authentication: ask the user and repeat the request
    if (status == 401) {
        NSString *challenge = r.responseHeaders[@"www-authenticate"] ?: @"";
        if ([[challenge lowercaseString] hasPrefix:@"basic"] && [self handleAuthenticationChallenge:challenge]) return;
    }

    // Cookies go into the shared jar so document.cookie and later requests see them.
    if (self.request.HTTPShouldHandleCookies && r.setCookieHeaders.count && !self.thirdParty) {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSString *value in r.setCookieHeaders) {
            NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": value } forURL:url];
            if (cookies.count) [jar setCookies:cookies forURL:url mainDocumentURL:self.request.mainDocumentURL ?: url];
        }
    }

    // Revalidated cache entry
    if (status == 304 && self.staleCached) {
        self.done = YES;
        [r cancel];
        NSTimeInterval maxAge = BRMaxAgeForResponse(r.responseHeaders, r.setCookieHeaders.count > 0);
        NSNumber *oldMaxAge = self.staleCached.userInfo[BRCacheMaxAgeKey];
        if (maxAge < 0 && oldMaxAge) maxAge = [oldMaxAge doubleValue];
        [self storeResponse:(NSHTTPURLResponse *)self.staleCached.response data:self.staleCached.data maxAge:MAX(maxAge, 0)];
        [self serveCachedResponse:self.staleCached];
        return;
    }

    // Redirects: hand the new request to WebKit, which starts a fresh load (through this protocol again).
    if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
        NSString *location = r.responseHeaders[@"location"];
        NSURL *target = location.length ? [[NSURL URLWithString:location relativeToURL:url] absoluteURL] : nil;
        if (!target) {
            // Some servers emit spaces or non-ASCII characters in Location.
            NSString *escaped = [location stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            target = escaped.length ? [[NSURL URLWithString:escaped relativeToURL:url] absoluteURL] : nil;
        }
        if (target) {
            self.done = YES;
            [r cancel];
            NSMutableURLRequest *redirect = [self.request mutableCopy];
            redirect.URL = target;
            NSString *method = [self.request.HTTPMethod uppercaseString] ?: @"GET";
            BOOL toGET = (status == 303) || ((status == 301 || status == 302) && ![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"]);
            if (toGET) {
                redirect.HTTPMethod = @"GET";
                redirect.HTTPBody = nil;
                redirect.HTTPBodyStream = nil;
                [redirect setValue:nil forHTTPHeaderField:@"Content-Type"];
                [redirect setValue:nil forHTTPHeaderField:@"Content-Length"];
            }
            [redirect setValue:nil forHTTPHeaderField:@"Cookie"];   // cookies for the new URL are added on the next pass
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:[self headerFieldsForWebKit]];
            [self performOnClientThread:^{
                [self.client URLProtocol:self wasRedirectedToRequest:redirect redirectResponse:response];
                // The client ignores this error; it is the documented way to end the current load after a redirect.
                [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
            }];
            return;
        }
    }

    // Normal response
    if (!self.request.mainDocumentURL || [url isEqual:self.request.mainDocumentURL]) {
        BRLog(@"%@ %@ -> %ld %@ [%@]", self.request.HTTPMethod ?: @"GET", url.absoluteString, (long)status,
              r.responseHeaders[@"content-type"] ?: @"", r.tlsInfo ?: @"");
        @synchronized ([BRURLProtocol class]) {
            g_lastMainURL = url;
            g_lastMainTLS = [[url.scheme lowercaseString] isEqualToString:@"https"] ? [r.tlsInfo copy] : nil;
            g_lastMainContentType = [r.responseHeaders[@"content-type"] copy];
        }
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:[self headerFieldsForWebKit]];
    self.response = response;
    self.cacheMaxAge = -1;
    self.cacheBody = nil;
    NSString *method = [self.request.HTTPMethod uppercaseString] ?: @"GET";
    if ([method isEqualToString:@"GET"] && status == 200) {
        NSTimeInterval maxAge = BRMaxAgeForResponse(r.responseHeaders, r.setCookieHeaders.count > 0);
        long long declared = [r.responseHeaders[@"content-length"] longLongValue];
        if (maxAge >= 0 && declared <= (long long)BRMaxCacheableBody) {
            self.cacheMaxAge = maxAge;
            self.cacheBody = [NSMutableData data];
        }
    }

    // Stylesheets and documents are rewritten for the old engine before WebKit sees them.
    NSString *ctype = [r.responseHeaders[@"content-type"] lowercaseString] ?: @"";
    NSString *kind = nil;
    if (status >= 200 && status < 300 && ![method isEqualToString:@"HEAD"] && [BRSettings cssFixEnabled] && [BRCSSRewriter shared].available) {
        NSString *path = [url.path lowercaseString] ?: @"";
        NSString *accept = [BRHeader(self.request.allHTTPHeaderFields, @"Accept") lowercaseString] ?: @"";
        if ([ctype hasPrefix:@"text/css"]) kind = @"css";
        else if ([ctype hasPrefix:@"text/html"] || [ctype hasPrefix:@"application/xhtml+xml"]) kind = @"html";
        else if (!ctype.length && [accept hasPrefix:@"text/css"]) kind = @"css";
        (void)path;
        long long declared = [r.responseHeaders[@"content-length"] longLongValue];
        if (declared > (long long)BRMaxRewriteBody) kind = nil;
    }
    // WOFF2 fonts are decoded to TTF (no JavaScript involved, so this works even without the rewriter)
    if (!kind && status >= 200 && status < 300 && ![method isEqualToString:@"HEAD"]) {
        NSString *path = [url.path lowercaseString] ?: @"";
        if ([ctype hasPrefix:@"font/woff2"] || [ctype hasPrefix:@"application/font-woff2"] || [ctype hasPrefix:@"application/x-font-woff2"] ||
            [path hasSuffix:@".woff2"] || [url.absoluteString rangeOfString:@".woff2?"].location != NSNotFound) {
            long long declared = [r.responseHeaders[@"content-length"] longLongValue];
            if (declared <= 8 * 1024 * 1024) kind = @"font";
        } else if ([ctype hasPrefix:@"font/woff"] || [ctype hasPrefix:@"application/font-woff"] || [ctype hasPrefix:@"application/x-font-woff"] ||
                   [path hasSuffix:@".woff"] || [url.absoluteString rangeOfString:@".woff?"].location != NSNotFound) {
            long long declared = [r.responseHeaders[@"content-length"] longLongValue];
            if (declared <= 8 * 1024 * 1024) kind = @"woff";
        } else if ([ctype hasPrefix:@"font/ttf"] || [ctype hasPrefix:@"font/otf"] || [ctype hasPrefix:@"font/sfnt"] ||
                   [ctype hasPrefix:@"application/x-font-ttf"] || [ctype hasPrefix:@"application/x-font-opentype"] ||
                   [ctype hasPrefix:@"application/font-sfnt"] || [ctype hasPrefix:@"application/vnd.ms-opentype"] ||
                   [path hasSuffix:@".ttf"] || [path hasSuffix:@".otf"]) {
            // plain TrueType/OpenType: only variable fonts need work (variation tables are dropped)
            long long declared = [r.responseHeaders[@"content-length"] longLongValue];
            if (declared <= 8 * 1024 * 1024) kind = @"sfnt";
        } else if ([ctype hasPrefix:@"image/webp"] || [path hasSuffix:@".webp"] || [url.absoluteString rangeOfString:@".webp?"].location != NSNotFound) {
            long long declared = [r.responseHeaders[@"content-length"] longLongValue];
            if (declared <= 6 * 1024 * 1024) kind = @"webp";
        }
    }
    if (kind) {
        self.rewriteKind = kind;
        self.rewriteBuffer = [NSMutableData data];
        self.pendingStatus = status;
        self.pendingHeaderFields = response.allHeaderFields;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"charset\\s*=\\s*\"?([A-Za-z0-9_-]+)" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:ctype options:0 range:NSMakeRange(0, ctype.length)];
        self.rewriteCharset = (m && m.numberOfRanges > 1) ? [ctype substringWithRange:[m rangeAtIndex:1]] : nil;
        return;   // didReceiveResponse follows once the rewritten body is ready
    }
    [self performOnClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    }];
}

// The body grew beyond the rewrite limit: send what we have unchanged and stream the rest.
- (void)abandonRewrite
{
    NSData *buffered = self.rewriteBuffer;
    self.rewriteBuffer = nil;
    self.rewriteKind = nil;
    NSHTTPURLResponse *response = self.response;
    if (self.cacheBody) [self.cacheBody appendData:buffered];
    [self performOnClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (buffered.length) [self.client URLProtocol:self didLoadData:buffered];
    }];
}

- (void)finishRewrite
{
    NSData *buffered = self.rewriteBuffer ?: [NSData data];
    self.rewriteBuffer = nil;
    NSString *kind = self.rewriteKind;
    if ([kind isEqualToString:@"font"] || [kind isEqualToString:@"woff"] || [kind isEqualToString:@"sfnt"] || [kind isEqualToString:@"webp"]) {
        // synchronous, on the worker thread
        BOOL isFont = [kind isEqualToString:@"font"];
        BOOL isWOFF = [kind isEqualToString:@"woff"];
        BOOL isSFNT = [kind isEqualToString:@"sfnt"];
        NSData *converted = isFont ? [BRFontConverter ttfDataFromWOFF2:buffered] :
                            isWOFF ? [BRFontConverter ttfDataFromWOFF:buffered] :
                            isSFNT ? [BRFontConverter staticFontDataFromSFNT:buffered] : [BRImageConverter pngDataFromWebP:buffered];
        NSMutableDictionary *f = [self.pendingHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        NSData *out = converted ?: buffered;
        if (converted && !isSFNT) BRSetHeaderField(f, @"Content-Type", (isFont || isWOFF) ? @"font/ttf" : @"image/png");
        BRSetHeaderField(f, @"Content-Length", [NSString stringWithFormat:@"%lu", (unsigned long)out.length]);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:self.pendingStatus HTTPVersion:@"HTTP/1.1" headerFields:f];
        if (self.cacheBody && out.length <= BRMaxCacheableBody) [self storeResponse:response data:out maxAge:self.cacheMaxAge];
        self.cacheBody = nil;
        [self performOnClientThread:^{
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (out.length) [self.client URLProtocol:self didLoadData:out];
            [self.client URLProtocolDidFinishLoading:self];
        }];
        return;
    }
    NSString *charset = self.rewriteCharset;
    NSInteger status = self.pendingStatus;
    NSDictionary *fields = self.pendingHeaderFields;
    NSURL *url = self.request.URL;
    NSURL *page = self.request.mainDocumentURL ?: url;
    BOOL cacheable = (self.cacheBody != nil);
    NSTimeInterval maxAge = self.cacheMaxAge;
    self.cacheBody = nil;
    BOOL mainFrame = !self.request.mainDocumentURL || [url isEqual:self.request.mainDocumentURL];
    [[BRCSSRewriter shared] rewriteData:buffered kind:kind charset:charset pageURL:page mainFrame:mainFrame completion:^(NSData *out, NSString *outCharset) {
        if (self.stopped) return;
        NSMutableDictionary *f = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *ctype = BRHeader(f, @"Content-Type") ?: ([kind isEqualToString:@"css"] ? @"text/css" : [kind isEqualToString:@"js"] ? @"text/javascript" : @"text/html");
        NSRange semi = [ctype rangeOfString:@";"];
        NSString *mediaType = semi.location == NSNotFound ? ctype : [ctype substringToIndex:semi.location];
        if (outCharset.length) {
            BRSetHeaderField(f, @"Content-Type", [NSString stringWithFormat:@"%@; charset=%@", [mediaType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], outCharset]);
        }
        BRSetHeaderField(f, @"Content-Length", [NSString stringWithFormat:@"%lu", (unsigned long)out.length]);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:f];
        if (cacheable && out.length <= BRMaxCacheableBody) [self storeResponse:response data:out maxAge:maxAge];
        [[BRCSSRewriter shared] registerManifestInData:out pageURL:page];
        [self performOnClientThread:^{
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (out.length) [self.client URLProtocol:self didLoadData:out];
            [self.client URLProtocolDidFinishLoading:self];
        }];
    }];
}

- (void)handleData:(NSData *)chunk
{
    if (self.stopped || self.done) return;
    if (self.rewriteBuffer) {
        [self.rewriteBuffer appendData:chunk];
        if (self.rewriteBuffer.length > BRMaxRewriteBody) [self abandonRewrite];
        return;
    }
    if (self.cacheBody) {
        if (self.cacheBody.length + chunk.length > BRMaxCacheableBody) self.cacheBody = nil;
        else [self.cacheBody appendData:chunk];
    }
    [self performOnClientThread:^{
        [self.client URLProtocol:self didLoadData:chunk];
    }];
}

- (void)handleComplete:(NSError *)error
{
    [self noteFinishedForProgress];
    if (self.stopped || self.done) return;
    self.done = YES;
    if (error) {
        NSError *urlError = BRURLErrorFromError(error, self.request.URL);
        BRLog(@"%@ %@ failed: %@", self.request.HTTPMethod, self.request.URL.absoluteString, error.localizedDescription);
        [self performOnClientThread:^{
            [self.client URLProtocol:self didFailWithError:urlError];
        }];
        return;
    }
    if (self.rewriteBuffer) {
        [self finishRewrite];
        return;
    }
    if (self.cacheBody && self.response) [self storeResponse:self.response data:self.cacheBody maxAge:self.cacheMaxAge];
    self.cacheBody = nil;
    [self performOnClientThread:^{
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

#pragma mark - Cache

- (void)serveCachedResponse:(NSCachedURLResponse *)cached
{
    self.done = YES;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)cached.response;
    NSData *data = cached.data;
    NSString *cachedType = [BRHeader(response.allHeaderFields, @"Content-Type") lowercaseString] ?: @"";
    if ([cachedType hasPrefix:@"text/css"] || [cachedType hasPrefix:@"text/html"]) {
        [[BRCSSRewriter shared] registerManifestInData:data pageURL:self.request.mainDocumentURL ?: self.request.URL];
    }
    [self performOnClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (data.length) [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

- (void)storeResponse:(NSHTTPURLResponse *)response data:(NSData *)data maxAge:(NSTimeInterval)maxAge
{
    if (!response || !data) return;
    if ([BRSettings privateMode]) return;   // private browsing leaves nothing on disk
    NSDictionary *info = @{ BRCacheStoredAtKey: @([NSDate timeIntervalSinceReferenceDate]), BRCacheMaxAgeKey: @(maxAge) };
    NSCachedURLResponse *c = [[NSCachedURLResponse alloc] initWithResponse:response data:data userInfo:info storagePolicy:NSURLCacheStorageAllowed];
    [[NSURLCache sharedURLCache] storeCachedResponse:c forRequest:self.request];
}

- (void)serveInternalResource
{
    NSString *path = self.request.URL.path ?: @"";
    NSData *body = nil;
    NSString *type = @"text/javascript; charset=utf-8";
    NSString *cacheControl = @"max-age=31536000";
    if ([path hasPrefix:@"/polyfills"] && [path hasSuffix:@".js"]) {
        body = [BRCSSRewriter polyfillBundle];
    } else if ([path isEqualToString:@"/manifest"]) {
        // :has() / @container entries collected for the page named in ?doc= (see BRCSSRewriter)
        NSString *query = self.request.URL.query ?: @"";
        NSString *doc = nil;
        for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
            if ([pair hasPrefix:@"doc="]) doc = [[pair substringFromIndex:4] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        }
        body = [[BRCSSRewriter shared] manifestJSONForPageURLString:doc ?: self.request.mainDocumentURL.absoluteString];
        type = @"application/json; charset=utf-8";
        cacheControl = @"no-store";
    } else if ([path hasPrefix:@"/indexeddbshim"] && [path hasSuffix:@".js"]) {
        NSString *file = [[NSBundle mainBundle] pathForResource:@"indexeddbshim" ofType:@"js" inDirectory:@"js"];
        body = file ? [NSData dataWithContentsOfFile:file] : nil;
    } else if ([path isEqualToString:@"/browserscore.js"] || [path isEqualToString:@"/cssfix.js"]) {
        // the browserscore runner and the CSS rewriter itself (the runner asks it what a page would get)
        NSString *file = [[NSBundle mainBundle] pathForResource:[path.lastPathComponent stringByDeletingPathExtension] ofType:@"js"];
        body = file ? [NSData dataWithContentsOfFile:file] : nil;
    } else if ([path isEqualToString:@"/browserscore-features.js"]) {
        // flattened browserscore/features definitions, generated at build time
        NSString *file = [[NSBundle mainBundle] pathForResource:@"browserscore-features" ofType:@"js" inDirectory:@"js"];
        body = file ? [NSData dataWithContentsOfFile:file] : nil;
    } else if ([path isEqualToString:@"/csstest.html"] || [path isEqualToString:@"/browserscore.html"]) {
        // bundled test pages served like web pages: they go through the CSS rewriter and get the polyfills
        NSString *file = [[NSBundle mainBundle] pathForResource:[path.lastPathComponent stringByDeletingPathExtension] ofType:@"html"];
        body = file ? [NSData dataWithContentsOfFile:file] : nil;
        type = @"text/html; charset=utf-8";
        if (body && [BRSettings cssFixEnabled] && [BRCSSRewriter shared].available) {
            self.done = YES;
            self.rewriteKind = @"html";
            self.rewriteBuffer = [body mutableCopy];
            self.rewriteCharset = @"utf-8";
            self.pendingStatus = 200;
            self.pendingHeaderFields = @{ @"Content-Type": type, @"Cache-Control": @"no-store" };
            [self finishRewrite];
            return;
        }
    }
    self.done = YES;
    if (!body) {
        [self failWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist
                                            userInfo:@{ NSURLErrorFailingURLStringErrorKey: self.request.URL.absoluteString ?: @"" }]];
        return;
    }
    NSDictionary *fields = @{ @"Content-Type": type, @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
                              @"Cache-Control": cacheControl, @"Access-Control-Allow-Origin": @"*" };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:fields];
    BOOL noStore = [cacheControl isEqualToString:@"no-store"];
    [self performOnClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:noStore ? NSURLCacheStorageNotAllowed : NSURLCacheStorageAllowedInMemoryOnly];
        [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

// Empty script / stylesheet or a blank image, so the page does not wait or show broken elements.
- (void)serveBlockedResponse
{
    NSString *accept = BRHeader(self.request.allHTTPHeaderFields, @"Accept") ?: @"";
    NSData *body = [NSData data];
    NSString *type = @"text/javascript";
    if ([accept rangeOfString:@"image"].location != NSNotFound || BRLooksLikeImageRequest(self.request)) {
        body = [NSData dataWithBytes:BRBlankGIF length:sizeof(BRBlankGIF)];
        type = @"image/gif";
    } else if ([accept rangeOfString:@"text/css"].location != NSNotFound) {
        type = @"text/css";
    } else if ([accept rangeOfString:@"text/html"].location != NSNotFound) {
        type = @"text/html";
    }
    NSDictionary *fields = @{ @"Content-Type": type, @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length], @"Cache-Control": @"no-store" };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:fields];
    self.done = YES;
    [self performOnClientThread:^{
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (body.length) [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
    }];
}

- (void)failWithError:(NSError *)error
{
    self.done = YES;
    [self performOnClientThread:^{
        [self.client URLProtocol:self didFailWithError:error];
    }];
}

@end
