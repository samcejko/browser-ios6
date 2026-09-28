#import "BRMediaProxy.h"
#import "BRHTTPRequest.h"
#import "BRSettings.h"
#import "BRCommon.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static const NSUInteger BRMediaProxyMaxEntries = 4000;   // (an HLS stream registers every segment it lists)

@interface BRMediaProxy ()
@property (nonatomic) int listenFD;
@property (nonatomic) uint16_t port;
@property (nonatomic, copy) NSString *secret;
@property (nonatomic, strong) NSMutableDictionary *entries;    // id -> @[url, page url]
@property (nonatomic, strong) NSMutableDictionary *idsByURL;   // absolute URL -> id
@property (nonatomic, strong) NSMutableArray *order;           // ids, oldest first
@property (nonatomic) NSUInteger nextId;
@end

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
