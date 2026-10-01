#import "BRMediaProxy.h"
#import "BRHTTPRequest.h"
#import "BRTLSSocket.h"
#import "BRSettings.h"
#import "BRCommon.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <poll.h>
#include <CommonCrypto/CommonDigest.h>

static const NSUInteger BRMediaProxyMaxEntries = 4000;   // (an HLS stream registers every segment it lists)
static const NSUInteger BRWebSocketMaxEntries = 200;     // (handed out, not yet connected)

@interface BRMediaProxy ()
@property (nonatomic) int listenFD;
@property (nonatomic) uint16_t port;
@property (nonatomic, copy) NSString *secret;
@property (nonatomic, strong) NSMutableDictionary *entries;    // id -> @[url, page url]
@property (nonatomic, strong) NSMutableDictionary *idsByURL;   // absolute URL -> id
@property (nonatomic, strong) NSMutableArray *order;           // ids, oldest first
@property (nonatomic) NSUInteger nextId;
@property (nonatomic, copy) NSString *wsSecret;                // (a secret of its own: pages see the socket addresses)
@property (nonatomic, strong) NSMutableDictionary *wsEntries;  // id -> @[url, page url]
@property (nonatomic, strong) NSMutableArray *wsOrder;
@end

static NSString *BRBase64(const unsigned char *p, size_t n)
{
    static const char *T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSMutableString *s = [NSMutableString stringWithCapacity:(n + 2) / 3 * 4];
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16 | (i + 1 < n ? (uint32_t)p[i + 1] << 8 : 0) | (i + 2 < n ? (uint32_t)p[i + 2] : 0);
        [s appendFormat:@"%c%c%c%c", T[(v >> 18) & 63], T[(v >> 12) & 63], i + 1 < n ? T[(v >> 6) & 63] : '=', i + 2 < n ? T[v & 63] : '='];
    }
    return s;
}

// Sec-WebSocket-Accept for a Sec-WebSocket-Key (RFC 6455)
static NSString *BRWebSocketAccept(NSString *key)
{
    NSData *d = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    return BRBase64(digest, sizeof(digest));
}

// The lines of a request or response head: the first line's words, and the headers with lowercase names (Set-Cookie
// values collected apart)
static NSDictionary *BRParseHead(NSData *head, NSArray **firstLine, NSMutableArray *setCookies)
{
    NSString *text = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] ?: @"";
    NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
    if (firstLine) *firstLine = [lines.firstObject componentsSeparatedByString:@" "];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[lines[i] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([name isEqualToString:@"set-cookie"]) { [setCookies addObject:value]; continue; }
        headers[name] = value;
    }
    return headers;
}

// (cookies go with the media request only to the page's own site when third-party cookies are blocked, as in
// BRURLProtocol: the registrable domain is the last two labels)
static BOOL BRMediaSameSite(NSURL *a, NSURL *b)
{
    NSString *ha = [a.host lowercaseString], *hb = [b.host lowercaseString];
    if (!ha.length || !hb.length || [ha isEqualToString:hb]) return YES;
    NSArray *pa = [ha componentsSeparatedByString:@"."], *pb = [hb componentsSeparatedByString:@"."];
    if (pa.count < 2 || pb.count < 2) return NO;
    return [pa[pa.count - 1] isEqualToString:pb[pb.count - 1]] && [pa[pa.count - 2] isEqualToString:pb[pb.count - 2]];
}

static BOOL BRSendAll(int fd, const void *bytes, size_t length)
{
    const char *p = bytes;
    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n;
        length -= (size_t)n;
    }
    return YES;
}

static BOOL BRSendString(int fd, NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
    return BRSendAll(fd, d.bytes, d.length);
}

static NSString *BRReasonPhrase(NSInteger status)
{
    switch (status) {
        case 200: return @"OK";
        case 206: return @"Partial Content";
        case 304: return @"Not Modified";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 416: return @"Range Not Satisfiable";
        case 502: return @"Bad Gateway";
        default: return @"Status";
    }
}

// the response head for the player: the headers of the file (the length only when the body is passed as it came)
static NSString *BRResponseHead(NSInteger status, NSDictionary *headers, BOOL keepLength)
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, BRReasonPhrase(status)];
    NSArray *names = @[@[@"content-type", @"Content-Type"], @[@"content-length", @"Content-Length"], @[@"content-range", @"Content-Range"],
                       @[@"accept-ranges", @"Accept-Ranges"], @[@"last-modified", @"Last-Modified"], @[@"etag", @"ETag"],
                       @[@"cache-control", @"Cache-Control"], @[@"expires", @"Expires"]];
    for (NSArray *n in names) {
        NSString *v = headers[n[0]];
        if (!v.length || ([n[0] isEqualToString:@"content-length"] && !keepLength)) continue;
        [s appendFormat:@"%@: %@\r\n", n[1], v];
    }
    [s appendString:@"Connection: close\r\n\r\n"];
    return s;
}

@implementation BRMediaProxy

+ (instancetype)shared
{
    static BRMediaProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        proxy = [[BRMediaProxy alloc] init];
        [proxy startServer];
    });
    return proxy;
}

- (void)startServer
{
    self.entries = [NSMutableDictionary dictionary];
    self.idsByURL = [NSMutableDictionary dictionary];
    self.order = [NSMutableArray array];
    NSMutableString *secret = [NSMutableString string];
    for (int i = 0; i < 4; i++) [secret appendFormat:@"%08x", arc4random()];
    self.secret = secret;
    NSMutableString *wsSecret = [NSMutableString string];
    for (int i = 0; i < 4; i++) [wsSecret appendFormat:@"%08x", arc4random()];
    self.wsSecret = wsSecret;
    self.wsEntries = [NSMutableDictionary dictionary];
    self.wsOrder = [NSMutableArray array];
    self.listenFD = -1;
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { BRLog(@"Media proxy: no socket (%d)", errno); return; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = 0;   // (any free port)
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0 || getsockname(fd, (struct sockaddr *)&addr, &length) != 0) {
        BRLog(@"Media proxy: cannot listen (%d)", errno);
        close(fd);
        return;
    }
    self.port = ntohs(addr.sin_port);
    self.listenFD = fd;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    BRLog(@"Media proxy listening on 127.0.0.1:%u", self.port);
}

- (NSString *)proxyURLStringForURL:(NSURL *)url pageURL:(NSURL *)pageURL
{
    if (self.listenFD < 0 || !url.absoluteString.length) return nil;
    NSString *ident;
    @synchronized (self) {
        NSString *key = url.absoluteString;
        ident = self.idsByURL[key];
        if (!ident) {
            ident = [NSString stringWithFormat:@"%lu", (unsigned long)++self.nextId];
            self.entries[ident] = @[url, pageURL ?: url];
            self.idsByURL[key] = ident;
            [self.order addObject:ident];
            while (self.order.count > BRMediaProxyMaxEntries) {
                NSString *old = self.order[0];
                NSArray *e = self.entries[old];
                if (e) [self.idsByURL removeObjectForKey:[e[0] absoluteString]];
                [self.entries removeObjectForKey:old];
                [self.order removeObjectAtIndex:0];
            }
        }
    }
    // (the last part of the path keeps the kind of file for the player: .m3u8, .mp4)
    NSString *last = url.lastPathComponent.length && ![url.lastPathComponent isEqualToString:@"/"] ? url.lastPathComponent : @"media";
    last = [last stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"media";
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/%@/%@/%@", self.port, self.secret, ident, last];
}

- (NSString *)webSocketURLStringForURL:(NSURL *)url pageURL:(NSURL *)pageURL
{
    if (self.listenFD < 0 || !url.host.length) return nil;
    NSString *ident;
    @synchronized (self) {
        ident = [NSString stringWithFormat:@"%lu", (unsigned long)++self.nextId];
        self.wsEntries[ident] = @[url, pageURL ?: url];
        [self.wsOrder addObject:ident];
        while (self.wsOrder.count > BRWebSocketMaxEntries) {
            [self.wsEntries removeObjectForKey:self.wsOrder[0]];
            [self.wsOrder removeObjectAtIndex:0];
        }
    }
    return [NSString stringWithFormat:@"ws://127.0.0.1:%u/%@/%@", self.port, self.wsSecret, ident];
}

// (taken: one connection per id)
- (NSArray *)webSocketEntryForPath:(NSString *)path
{
    NSArray *parts = [path componentsSeparatedByString:@"/"];   // "", ws secret, id
    if (parts.count < 3 || ![parts[1] isEqualToString:self.wsSecret]) return nil;
    @synchronized (self) {
        NSArray *entry = self.wsEntries[parts[2]];
        if (entry) { [self.wsEntries removeObjectForKey:parts[2]]; [self.wsOrder removeObject:parts[2]]; }
        return entry;
    }
}

- (NSArray *)entryForPath:(NSString *)path
{
    NSArray *parts = [path componentsSeparatedByString:@"/"];   // "", secret, id, name
    if (parts.count < 3 || ![parts[1] isEqualToString:self.secret]) return nil;
    @synchronized (self) { return self.entries[parts[2]]; }
}

- (void)acceptLoop
{
    @autoreleasepool { [[NSThread currentThread] setName:@"BRMediaProxy"]; }
    for (;;) {
        @autoreleasepool {
            int c = accept(self.listenFD, NULL, NULL);
            if (c < 0) {
                if (errno != EINTR) usleep(200000);
                continue;
            }
            int on = 1;
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
            [NSThread detachNewThreadSelector:@selector(serveConnection:) toTarget:self withObject:@(c)];
        }
    }
}

- (void)serveConnection:(NSNumber *)socketNumber
{
    @autoreleasepool {
        int fd = socketNumber.intValue;
        [[NSThread currentThread] setName:@"BRMediaProxy connection"];
        struct timeval tv = { 30, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        NSMutableData *buffer = [NSMutableData data];
        NSData *blank = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange end = NSMakeRange(NSNotFound, 0);
        char chunk[4096];
        while (buffer.length < 32768) {
            ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
            if (n <= 0) break;
            [buffer appendBytes:chunk length:(NSUInteger)n];
            end = [buffer rangeOfData:blank options:0 range:NSMakeRange(0, buffer.length)];
            if (end.location != NSNotFound) break;
        }
        if (end.location == NSNotFound) { close(fd); return; }
        NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        NSString *method = requestLine.count >= 2 ? [requestLine[0] uppercaseString] : nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            headers[[[lines[i] substringToIndex:colon.location] lowercaseString]] =
                [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        NSArray *socketEntry = requestLine.count >= 2 && [method isEqualToString:@"GET"] ? [self webSocketEntryForPath:requestLine[1]] : nil;
        if (socketEntry) {
            NSUInteger after = end.location + end.length;
            NSData *early = after < buffer.length ? [buffer subdataWithRange:NSMakeRange(after, buffer.length - after)] : nil;
            [self relayWebSocket:socketEntry headers:headers early:early to:fd];
            close(fd);
            return;
        }
        NSArray *entry = requestLine.count >= 2 ? [self entryForPath:requestLine[1]] : nil;
        if (!entry || !([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"])) {
            BRSendString(fd, @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            close(fd);
            return;
        }
        [self relayEntry:entry method:method headers:headers to:fd];
        close(fd);
    }
}

// One request of the player, through the app's network layer: redirects followed here, the body passed on as it
// comes (a player that lets go ends the request), an HLS playlist rewritten first.
- (void)relayEntry:(NSArray *)entry method:(NSString *)method headers:(NSDictionary *)playerHeaders to:(int)fd
{
    NSURL *url = entry[0], *page = entry[1];
    for (int hop = 0; hop < 6; hop++) {
        NSMutableDictionary *h = [NSMutableDictionary dictionary];
        h[@"Accept"] = playerHeaders[@"accept"] ?: @"*/*";
        if (playerHeaders[@"range"]) h[@"Range"] = playerHeaders[@"range"];
        if (playerHeaders[@"if-range"]) h[@"If-Range"] = playerHeaders[@"if-range"];
        if (page && ![page isEqual:url]) h[@"Referer"] = page.absoluteString;
        if (![BRSettings blockThirdPartyCookies] || BRMediaSameSite(url, page)) {
            NSArray *cookies = nil;
            @synchronized (BRCookieLock()) { cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]; }
            NSString *cookie = cookies.count ? [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"] : nil;
            if (cookie.length) h[@"Cookie"] = cookie;
        }
        BRHTTPRequest *r = [[BRHTTPRequest alloc] initWithMethod:method URL:url];
        r.headers = h;
        r.verifyTLS = [BRSettings verifyTLS];
        r.highPriority = YES;   // (a stream holds its connection for minutes: none of the page's connection slots)
        r.connectTimeout = 20;
        r.readTimeout = 60;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSURL *redirect = nil;
        __block BOOL playlist = NO, headSent = NO, broken = NO;
        __block NSInteger playlistStatus = 200;
        __block NSDictionary *playlistHeaders = nil;
        NSMutableData *collected = [NSMutableData data];
        __weak BRHTTPRequest *weakR = r;
        r.onHeaders = ^(NSInteger status, NSDictionary *hdrs) {
            NSString *location = hdrs[@"location"];
            if (status >= 300 && status < 400 && status != 304 && location.length) {
                redirect = [[NSURL URLWithString:location relativeToURL:url] absoluteURL];
                return;
            }
            NSString *type = [hdrs[@"content-type"] lowercaseString] ?: @"";
            playlist = status < 300 && ([type rangeOfString:@"mpegurl"].location != NSNotFound || [[url.path lowercaseString] hasSuffix:@".m3u8"]);
            if (playlist) { playlistStatus = status; playlistHeaders = hdrs; return; }
            NSString *encoding = [hdrs[@"content-encoding"] lowercaseString] ?: @"";
            BOOL keepLength = !encoding.length || [encoding isEqualToString:@"identity"];
            headSent = YES;
            if (!BRSendString(fd, BRResponseHead(status, hdrs, keepLength))) { broken = YES; [weakR cancel]; }
        };
        r.onData = ^(NSData *data) {
            if (redirect || broken) return;
            if (playlist) { [collected appendData:data]; return; }
            if (!BRSendAll(fd, data.bytes, data.length)) { broken = YES; [weakR cancel]; }
        };
        r.onComplete = ^(NSError *error) { dispatch_semaphore_signal(done); };
        [r start];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (redirect && !broken) { url = redirect; continue; }
        if (playlist && !broken) {
            NSString *text = [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:collected encoding:NSISOLatin1StringEncoding] ?: @"";
            NSData *body = [[self rewritePlaylist:text baseURL:url pageURL:page] dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableDictionary *hh = [playlistHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
            hh[@"content-type"] = @"application/vnd.apple.mpegurl";
            hh[@"content-length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
            [hh removeObjectForKey:@"content-range"];
            if (BRSendString(fd, BRResponseHead(playlistStatus == 206 ? 200 : playlistStatus, hh, YES)) && ![method isEqualToString:@"HEAD"]) BRSendAll(fd, body.bytes, body.length);
            return;
        }
        if (!headSent && !broken) BRSendString(fd, @"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
}

// One WebSocket of the page: the real one opened through the app's network layer, then WebCore's handshake answered,
// then the bytes passed both ways on this thread (poll on both sockets; the TLS socket is used from this thread only).
- (void)relayWebSocket:(NSArray *)entry headers:(NSDictionary *)client early:(NSData *)early to:(int)fd
{
    NSURL *url = entry[0], *page = entry[1];
    NSString *key = client[@"sec-websocket-key"];
    if (!key.length || ![[client[@"upgrade"] lowercaseString] isEqualToString:@"websocket"]) {
        BRSendString(fd, @"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    BOOL secure = [[url.scheme lowercaseString] isEqualToString:@"wss"];
    int port = url.port ? url.port.intValue : (secure ? 443 : 80);
    NSString *host = url.host;
    // (the same address as http(s), for the cookie jar)
    NSURL *httpURL = [NSURL URLWithString:[(secure ? @"https" : @"http") stringByAppendingString:[url.absoluteString substringFromIndex:url.scheme.length]]] ?: url;
    BRTLSSocket *up = [[BRTLSSocket alloc] init];
    up.plain = !secure;
    NSError *error = nil;
    if (![up connectToHost:host port:port verify:[BRSettings verifyTLS] connectTimeoutMs:20000 readTimeoutMs:20000 error:&error]) {
        BRLog(@"WebSocket proxy: %@ failed: %@", host, error.localizedDescription);
        BRSendString(fd, @"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        [up close];
        return;
    }
    // the request target: path and query as written, no fragment
    NSString *abs = url.absoluteString;
    NSRange schemeEnd = [abs rangeOfString:@"://"];
    NSString *rest = schemeEnd.location == NSNotFound ? abs : [abs substringFromIndex:schemeEnd.location + 3];
    NSRange slash = [rest rangeOfString:@"/"], query = [rest rangeOfString:@"?"];
    NSString *target = slash.location != NSNotFound && (query.location == NSNotFound || slash.location < query.location) ? [rest substringFromIndex:slash.location] :
        query.location != NSNotFound ? [@"/" stringByAppendingString:[rest substringFromIndex:query.location]] : @"/";
    NSRange hash = [target rangeOfString:@"#"];
    if (hash.location != NSNotFound) target = [target substringToIndex:hash.location];
    unsigned char nonce[16];
    for (int i = 0; i < 16; i++) nonce[i] = (unsigned char)arc4random_uniform(256);
    NSString *upKey = BRBase64(nonce, sizeof(nonce));
    BOOL defaultPort = (secure && port == 443) || (!secure && port == 80);
    NSMutableString *req = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\n", target, defaultPort ? host : [NSString stringWithFormat:@"%@:%d", host, port]];
    [req appendFormat:@"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %@\r\n", upKey];
    // (the page's own Origin, as WebCore sent it: servers check it; no extensions, so the frames stay as WebCore makes them)
    if (client[@"origin"]) [req appendFormat:@"Origin: %@\r\n", client[@"origin"]];
    if (client[@"sec-websocket-protocol"]) [req appendFormat:@"Sec-WebSocket-Protocol: %@\r\n", client[@"sec-websocket-protocol"]];
    [req appendFormat:@"User-Agent: %@\r\n", [BRSettings userAgentOverrideForURL:httpURL] ?: [BRHTTPRequest defaultUserAgent]];
    if (client[@"accept-language"]) [req appendFormat:@"Accept-Language: %@\r\n", client[@"accept-language"]];
    [req appendString:@"Pragma: no-cache\r\nCache-Control: no-cache\r\n"];
    BOOL cookiesAllowed = ![BRSettings blockThirdPartyCookies] || BRMediaSameSite(url, page);
    if (cookiesAllowed) {
        NSArray *cookies = nil;
        @synchronized (BRCookieLock()) { cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:httpURL]; }
        NSString *cookie = cookies.count ? [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"] : nil;
        if (cookie.length) [req appendFormat:@"Cookie: %@\r\n", cookie];
    }
    [req appendString:@"\r\n"];
    if (![up writeData:[req dataUsingEncoding:NSUTF8StringEncoding] error:&error]) {
        BRLog(@"WebSocket proxy: %@ handshake not sent: %@", host, error.localizedDescription);
        BRSendString(fd, @"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        [up close];
        return;
    }
    // the server's answer
    NSMutableData *acc = [NSMutableData data];
    NSData *blank = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange headEnd = NSMakeRange(NSNotFound, 0);
    unsigned char buf[16384];
    while (acc.length < 65536) {
        NSInteger n = [up readIntoBuffer:buf maxLength:sizeof(buf) error:&error];
        if (n <= 0) break;
        [acc appendBytes:buf length:(NSUInteger)n];
        headEnd = [acc rangeOfData:blank options:0 range:NSMakeRange(0, acc.length)];
        if (headEnd.location != NSNotFound) break;
    }
    NSArray *status = nil;
    NSMutableArray *setCookies = [NSMutableArray array];
    NSDictionary *answer = headEnd.location != NSNotFound ? BRParseHead([acc subdataWithRange:NSMakeRange(0, headEnd.location)], &status, setCookies) : nil;
    if (!answer || status.count < 2 || ![status[1] isEqualToString:@"101"] ||
        ![answer[@"sec-websocket-accept"] isEqualToString:BRWebSocketAccept(upKey)]) {
        BRLog(@"WebSocket proxy: %@ refused (%@)", host, status.count >= 2 ? status[1] : (error.localizedDescription ?: @"no answer"));
        BRSendString(fd, @"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        [up close];
        return;
    }
    if (cookiesAllowed && setCookies.count) {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSString *value in setCookies) {
            NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": value } forURL:httpURL];
            if (cookies.count) { @synchronized (BRCookieLock()) { [jar setCookies:cookies forURL:httpURL mainDocumentURL:page ?: httpURL]; } }
        }
    }
    // WebCore's handshake answered
    NSMutableString *reply = [NSMutableString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n", BRWebSocketAccept(key)];
    if (answer[@"sec-websocket-protocol"]) [reply appendFormat:@"Sec-WebSocket-Protocol: %@\r\n", answer[@"sec-websocket-protocol"]];
    [reply appendString:@"\r\n"];
    NSUInteger after = headEnd.location + headEnd.length;
    BOOL ok = BRSendString(fd, reply) && (after >= acc.length || BRSendAll(fd, (const char *)acc.bytes + after, acc.length - after));
    if (ok && early.length) ok = [up writeData:early error:NULL];
    BRLog(@"WebSocket proxy: %@ open (%@)", host, secure ? (up.tlsVersion ?: @"TLS") : @"plain");
    // (a record that started arriving is complete within this; between frames the sockets wait in poll)
    [up setReadTimeoutMs:15000];
    // (a pool per round: a socket stays open for hours, and what a round autoreleases must not pile up till then)
    while (ok) {
        @autoreleasepool {
            if ([up hasBufferedData]) {
                NSInteger n = [up readIntoBuffer:buf maxLength:sizeof(buf) error:NULL];
                if (n <= 0 || !BRSendAll(fd, buf, (size_t)n)) ok = NO;
                continue;
            }
            struct pollfd p[2] = { { fd, POLLIN, 0 }, { up.fileDescriptor, POLLIN, 0 } };
            int r = poll(p, 2, 60000);
            if (r < 0) { if (errno != EINTR) ok = NO; continue; }
            if (r == 0) continue;
            if (p[0].revents & (POLLIN | POLLHUP | POLLERR)) {
                ssize_t n = recv(fd, buf, sizeof(buf), 0);
                if (n <= 0 || ![up writeData:[NSData dataWithBytesNoCopy:buf length:(NSUInteger)n freeWhenDone:NO] error:NULL]) { ok = NO; continue; }
            }
            if (p[1].revents & (POLLIN | POLLHUP | POLLERR)) {
                NSInteger n = [up readIntoBuffer:buf maxLength:sizeof(buf) error:NULL];
                if (n <= 0 || !BRSendAll(fd, buf, (size_t)n)) ok = NO;
            }
        }
    }
    BRLog(@"WebSocket proxy: %@ closed", host);
    [up close];
}

// Every URI of an HLS playlist (media lines, URI="..." of keys, maps, renditions) as an absolute proxy URL.
- (NSString *)rewritePlaylist:(NSString *)text baseURL:(NSURL *)base pageURL:(NSURL *)page
{
    NSRegularExpression *uriAttr = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!t.length) continue;
        if ([t hasPrefix:@"#"]) {
            NSMutableString *m = [t mutableCopy];
            NSArray *found = [uriAttr matchesInString:t options:0 range:NSMakeRange(0, t.length)];
            for (NSTextCheckingResult *r in [found reverseObjectEnumerator]) {
                NSURL *abs = [[NSURL URLWithString:[t substringWithRange:[r rangeAtIndex:1]] relativeToURL:base] absoluteURL];
                NSString *proxied = abs ? [self proxyURLStringForURL:abs pageURL:page] : nil;
                if (proxied) [m replaceCharactersInRange:[r rangeAtIndex:1] withString:proxied];
            }
            [out addObject:m];
            continue;
        }
        NSURL *abs = [[NSURL URLWithString:t relativeToURL:base] absoluteURL];
        [out addObject:(abs ? [self proxyURLStringForURL:abs pageURL:page] : nil) ?: t];
    }
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

@end
