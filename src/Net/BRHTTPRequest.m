#import "BRHTTPRequest.h"
#import "BRTLSSocket.h"
#import "BRCommon.h"

#include <zlib.h>
#include <string.h>
#include <stdlib.h>

typedef NS_ENUM(NSInteger, BRChunkState) {
    BRChunkStateSize = 0,
    BRChunkStateData,
    BRChunkStateDataEnd,
    BRChunkStateTrailer,
    BRChunkStateDone,
};

static const NSUInteger BRInflateBufferSize = 32768;
static const long BRMaxConcurrentConnections = 10;

static dispatch_semaphore_t BRConnectionSlots(void)
{
    static dispatch_semaphore_t slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slots = dispatch_semaphore_create(BRMaxConcurrentConnections); });
    return slots;
}

@interface BRHTTPRequest ()
@property (nonatomic, strong) BRTLSSocket *socket;
@property (nonatomic, strong) BRHTTPRequest *selfRetain;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSArray *responseHeaderPairs;
@property (nonatomic, strong) NSArray *setCookieHeaders;
@property (nonatomic, strong) NSData *responseBody;
@property (nonatomic) BOOL isCancelled;
@property (nonatomic) BOOL isFinished;
@property (nonatomic) BOOL decodedContentEncoding;
@property (nonatomic, copy) NSString *tlsInfo;
@property (nonatomic, strong) NSMutableData *accumulated;

// body decoding state
@property (nonatomic) BOOL chunked;
@property (nonatomic) long long contentLength;      // -1 unknown
@property (nonatomic) long long bodyReceived;       // raw (wire) body bytes
@property (nonatomic) BRChunkState chunkState;
@property (nonatomic) long long chunkRemaining;
@property (nonatomic) BOOL hasSlot;
@property (nonatomic) BOOL bodyError;
@end

@implementation BRHTTPRequest {
    z_stream _zstream;
    BOOL _zinit;
    BOOL _zactive;
    uint8_t *_zout;
}

- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)url
{
    self = [super init];
    if (self) {
        _method = [method length] ? [method uppercaseString] : @"GET";
        _url = url;
        _connectTimeout = 20;
        _readTimeout = 60;
        _verifyTLS = YES;
        _contentLength = -1;
        _accumulated = [NSMutableData data];
    }
    return self;
}

- (void)dealloc
{
    if (_zinit) inflateEnd(&_zstream);
    free(_zout);
}

+ (NSString *)defaultUserAgent
{
    NSString *osv = [[UIDevice currentDevice].systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *device = BRIsPad() ? @"iPad" : @"iPhone";
    return [NSString stringWithFormat:@"Mozilla/5.0 (%@; CPU OS %@ like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B146 Safari/8536.25", device, osv];
}

+ (NSString *)acceptLanguage
{
    NSArray *langs = [NSLocale preferredLanguages];
    NSMutableArray *parts = [NSMutableArray array];
    double q = 1.0;
    BOOL hasEnglish = NO;
    for (NSString *l in langs) {
        if (parts.count >= 4) break;
        if ([l hasPrefix:@"en"]) hasEnglish = YES;
        if (q >= 1.0) [parts addObject:l];
        else [parts addObject:[NSString stringWithFormat:@"%@;q=%.1f", l, q]];
        q -= 0.2;
    }
    if (!hasEnglish) [parts addObject:[NSString stringWithFormat:@"en;q=%.1f", MAX(0.1, q)]];
    return parts.count ? [parts componentsJoinedByString:@", "] : @"en";
}

- (void)start
{
    self.selfRetain = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            [self run];
        }
    });
}

- (void)cancel
{
    if (self.isFinished) return;
    self.isCancelled = YES;
    [self.socket cancel];
}

#pragma mark - Request

- (BOOL)isSecure
{
    return [[self.url.scheme lowercaseString] isEqualToString:@"https"];
}

- (int)port
{
    NSNumber *p = self.url.port;
    if (p) return [p intValue];
    return [self isSecure] ? 443 : 80;
}

// Path and query exactly as written in the URL (percent-encoded), without the fragment.
- (NSString *)requestTarget
{
    NSString *abs = self.url.absoluteString ?: @"/";
    NSRange schemeEnd = [abs rangeOfString:@"://"];
    NSString *rest = schemeEnd.location == NSNotFound ? abs : [abs substringFromIndex:schemeEnd.location + 3];
    NSRange slash = [rest rangeOfString:@"/"];
    NSString *target = slash.location == NSNotFound ? @"/" : [rest substringFromIndex:slash.location];
    NSRange hash = [target rangeOfString:@"#"];
    if (hash.location != NSNotFound) target = [target substringToIndex:hash.location];
    if (!target.length) target = @"/";
    return target;
}

- (NSData *)serializedRequest
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ %@ HTTP/1.1\r\n", self.method, [self requestTarget]];
    NSString *host = self.url.host ?: @"";
    int port = [self port];
    BOOL defaultPort = ([self isSecure] && port == 443) || (![self isSecure] && port == 80);
    [s appendFormat:@"Host: %@\r\n", defaultPort ? host : [NSString stringWithFormat:@"%@:%d", host, port]];
    NSMutableSet *given = [NSMutableSet set];
    for (NSString *key in self.headers) {
        NSString *lk = [key lowercaseString];
        if ([lk isEqualToString:@"host"] || [lk isEqualToString:@"content-length"] || [lk isEqualToString:@"connection"] ||
            [lk isEqualToString:@"accept-encoding"] || [lk isEqualToString:@"transfer-encoding"] || [lk isEqualToString:@"expect"]) continue;
        NSString *value = [[self.headers[key] description] stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
        value = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [given addObject:lk];
        [s appendFormat:@"%@: %@\r\n", key, value];
    }
    if (![given containsObject:@"user-agent"]) [s appendFormat:@"User-Agent: %@\r\n", [BRHTTPRequest defaultUserAgent]];
    if (![given containsObject:@"accept"]) [s appendString:@"Accept: */*\r\n"];
    if (![given containsObject:@"accept-language"]) [s appendFormat:@"Accept-Language: %@\r\n", [BRHTTPRequest acceptLanguage]];
    [s appendString:@"Accept-Encoding: gzip, deflate\r\n"];
    [s appendString:@"Connection: close\r\n"];
    if (self.body || [self.method isEqualToString:@"POST"] || [self.method isEqualToString:@"PUT"] || [self.method isEqualToString:@"PATCH"]) {
        [s appendFormat:@"Content-Length: %lu\r\n", (unsigned long)self.body.length];
    }
    [s appendString:@"\r\n"];
    NSMutableData *d = [[s dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (self.body) [d appendData:self.body];
    return d;
}

#pragma mark - Completion

- (void)releaseSlot
{
    if (self.hasSlot) {
        self.hasSlot = NO;
        dispatch_semaphore_signal(BRConnectionSlots());
    }
}

- (void)finishWithError:(NSError *)error
{
    if (self.isFinished) return;
    self.isFinished = YES;
    [self.socket close];
    self.socket = nil;
    [self releaseSlot];
    if (!self.onData) self.responseBody = [self.accumulated copy];
    self.accumulated = nil;
    BRHTTPCompleteBlock done = self.onComplete;
    self.onComplete = nil;
    self.onData = nil;
    self.onHeaders = nil;
    if (done) done(error);
    self.selfRetain = nil;
}

#pragma mark - Body decoding

- (void)deliverDecodedBytes:(const void *)bytes length:(NSUInteger)length
{
    if (!length) return;
    BRHTTPDataBlock cb = self.onData;
    if (cb) cb([NSData dataWithBytes:bytes length:length]);
    else [self.accumulated appendBytes:bytes length:length];
}

- (BOOL)setupInflate
{
    memset(&_zstream, 0, sizeof(_zstream));
    if (inflateInit2(&_zstream, 15 + 32) != Z_OK) return NO;   // auto-detects gzip and zlib headers
    _zinit = YES;
    _zout = (uint8_t *)malloc(BRInflateBufferSize);
    if (!_zout) return NO;
    _zactive = YES;
    return YES;
}

// Raw body bytes from the wire (after transfer decoding). Returns NO on a content decoding error.
- (BOOL)deliverBodyBytes:(const void *)bytes length:(NSUInteger)length
{
    if (!length) return YES;
    self.bodyReceived += length;
    if (!_zactive) {
        [self deliverDecodedBytes:bytes length:length];
        return YES;
    }
    _zstream.next_in = (Bytef *)bytes;
    _zstream.avail_in = (uInt)length;
    while (_zstream.avail_in > 0) {
        _zstream.next_out = _zout;
        _zstream.avail_out = (uInt)BRInflateBufferSize;
        int rc = inflate(&_zstream, Z_NO_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
            BRLog(@"inflate failed (%d) for %@", rc, self.url);
            return NO;
        }
        NSUInteger produced = BRInflateBufferSize - _zstream.avail_out;
        [self deliverDecodedBytes:_zout length:produced];
        if (rc == Z_STREAM_END) {
            _zactive = NO;   // anything after the end of the stream is ignored
            break;
        }
        if (rc == Z_BUF_ERROR && produced == 0) break;   // needs more input
    }
    return YES;
}

// Returns YES when the whole body has been consumed.
- (BOOL)consumeBody:(NSMutableData *)buffer
{
    if (!self.chunked) {
        if (buffer.length) {
            if (![self deliverBodyBytes:buffer.bytes length:buffer.length]) { self.bodyError = YES; return YES; }
            buffer.length = 0;
        }
        return self.contentLength >= 0 && self.bodyReceived >= self.contentLength;
    }
    // Chunked transfer encoding state machine.
    for (;;) {
        const uint8_t *bytes = (const uint8_t *)buffer.bytes;
        NSUInteger len = buffer.length;
        if (self.chunkState == BRChunkStateSize || self.chunkState == BRChunkStateTrailer) {
            NSUInteger lineEnd = NSNotFound;
            for (NSUInteger i = 0; i + 1 < len; i++) {
                if (bytes[i] == '\r' && bytes[i + 1] == '\n') { lineEnd = i; break; }
            }
            if (lineEnd == NSNotFound) return NO;   // need more data
            NSString *line = [[NSString alloc] initWithBytes:bytes length:lineEnd encoding:NSASCIIStringEncoding] ?: @"";
            [buffer replaceBytesInRange:NSMakeRange(0, lineEnd + 2) withBytes:NULL length:0];
            if (self.chunkState == BRChunkStateTrailer) {
                if (line.length == 0) { self.chunkState = BRChunkStateDone; return YES; }
                continue;
            }
            if (line.length == 0) continue;   // tolerate stray blank lines
            NSRange semi = [line rangeOfString:@";"];
            NSString *hex = semi.location == NSNotFound ? line : [line substringToIndex:semi.location];
            unsigned long long size = strtoull([hex UTF8String], NULL, 16);
            if (size == 0) {
                self.chunkState = BRChunkStateTrailer;
                continue;
            }
            self.chunkRemaining = (long long)size;
            self.chunkState = BRChunkStateData;
            continue;
        }
        if (self.chunkState == BRChunkStateData) {
            if (len == 0) return NO;
            NSUInteger take = (NSUInteger)MIN((long long)len, self.chunkRemaining);
            if (![self deliverBodyBytes:bytes length:take]) { self.bodyError = YES; return YES; }
            [buffer replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
            self.chunkRemaining -= take;
            if (self.chunkRemaining == 0) self.chunkState = BRChunkStateDataEnd;
            continue;
        }
        if (self.chunkState == BRChunkStateDataEnd) {
            if (len < 2) return NO;
            [buffer replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];   // CRLF after the chunk
            self.chunkState = BRChunkStateSize;
            continue;
        }
        return YES; // done
    }
}

#pragma mark - Headers

// 0 = need more data, 1 = final headers parsed, 2 = interim (1xx) response skipped, -1 = error.
- (int)parseHeadersFromBuffer:(NSMutableData *)buffer error:(NSError **)error
{
    const uint8_t *bytes = (const uint8_t *)buffer.bytes;
    NSUInteger len = buffer.length;
    NSUInteger end = NSNotFound;
    for (NSUInteger i = 0; i + 3 < len; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n' && bytes[i + 2] == '\r' && bytes[i + 3] == '\n') { end = i; break; }
    }
    if (end == NSNotFound) {
        if (len > 64 * 1024) {
            if (error) *error = BRMakeError(BRErrorBadResponse, L(@"The server sent an invalid response."));
            return -1;
        }
        return 0;
    }
    NSString *head = [[NSString alloc] initWithBytes:bytes length:end encoding:NSISOLatin1StringEncoding] ?: @"";
    [buffer replaceBytesInRange:NSMakeRange(0, end + 4) withBytes:NULL length:0];
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *statusLine = lines.count ? lines[0] : @"";
    if (![statusLine hasPrefix:@"HTTP/"]) {
        if (error) *error = BRMakeError(BRErrorBadResponse, [NSString stringWithFormat:L(@"Unexpected response: %@"), statusLine.length > 80 ? [statusLine substringToIndex:80] : statusLine]);
        return -1;
    }
    NSArray *parts = [statusLine componentsSeparatedByString:@" "];
    NSInteger status = parts.count >= 2 ? [parts[1] integerValue] : 0;
    if (status < 100 || status > 999) {
        if (error) *error = BRMakeError(BRErrorBadResponse, [NSString stringWithFormat:L(@"Unexpected response: %@"), statusLine]);
        return -1;
    }
    if (status < 200) return 2;   // 100 Continue, 103 Early Hints: the real headers follow

    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!name.length) continue;
        [pairs addObject:@[name, value]];
        NSString *lname = [name lowercaseString];
        if ([lname isEqualToString:@"set-cookie"]) {
            [cookies addObject:value];
            continue;
        }
        NSString *existing = headers[lname];
        headers[lname] = existing ? [NSString stringWithFormat:@"%@, %@", existing, value] : value;
    }
    self.statusCode = status;
    self.responseHeaders = headers;
    self.responseHeaderPairs = pairs;
    self.setCookieHeaders = cookies;
    NSString *te = [headers[@"transfer-encoding"] lowercaseString];
    self.chunked = te && [te rangeOfString:@"chunked"].location != NSNotFound;
    NSString *cl = headers[@"content-length"];
    self.contentLength = (cl && !self.chunked) ? [cl longLongValue] : -1;
    NSString *ce = [[headers[@"content-encoding"] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([ce isEqualToString:@"gzip"] || [ce isEqualToString:@"x-gzip"] || [ce isEqualToString:@"deflate"]) {
        if ([self setupInflate]) self.decodedContentEncoding = YES;
    }
    return 1;
}

#pragma mark - Worker

- (void)run
{
    // Limit the number of simultaneous connections (TLS handshakes are CPU heavy on this hardware).
    dispatch_semaphore_t slots = BRConnectionSlots();
    while (dispatch_semaphore_wait(slots, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC))) != 0) {
        if (self.isCancelled) {
            [self finishWithError:BRMakeError(BRErrorCancelled, L(@"Cancelled"))];
            return;
        }
    }
    self.hasSlot = YES;
    if (self.isCancelled) {
        [self finishWithError:BRMakeError(BRErrorCancelled, L(@"Cancelled"))];
        return;
    }

    self.socket = [[BRTLSSocket alloc] init];
    self.socket.plain = ![self isSecure];
    NSError *error = nil;
    if (![self.socket connectToHost:self.url.host port:[self port] verify:self.verifyTLS
                   connectTimeoutMs:(int)(self.connectTimeout * 1000) readTimeoutMs:(int)(self.readTimeout * 1000) error:&error]) {
        [self finishWithError:error ?: BRMakeError(BRErrorConnect, L(@"Connection failed."))];
        return;
    }
    self.tlsInfo = [NSString stringWithFormat:@"%@ %@", self.socket.tlsVersion ?: @"", self.socket.cipherSuite ?: @""];
    if (![self.socket writeData:[self serializedRequest] error:&error]) {
        [self finishWithError:error ?: BRMakeError(BRErrorConnectionLost, L(@"Sending the request failed."))];
        return;
    }

    NSMutableData *buffer = [NSMutableData data];
    BOOL headersDone = NO;
    BOOL bodyDone = NO;
    const NSUInteger chunkSize = 16384;
    uint8_t *tmp = (uint8_t *)malloc(chunkSize);
    if (!tmp) {
        [self finishWithError:BRMakeError(BRErrorNetwork, @"Out of memory")];
        return;
    }
    while (!bodyDone) {
        NSError *readError = nil;
        NSInteger n = [self.socket readIntoBuffer:tmp maxLength:chunkSize error:&readError];
        if (n < 0) {
            free(tmp);
            [self finishWithError:readError ?: BRMakeError(BRErrorConnectionLost, L(@"Connection lost."))];
            return;
        }
        if (n == 0) {
            // EOF
            if (!headersDone) {
                free(tmp);
                [self finishWithError:BRMakeError(BRErrorBadResponse, L(@"The server closed the connection without responding."))];
                return;
            }
            // The body ends with the connection (also for incomplete chunked / content-length bodies).
            [self consumeBody:buffer];
            if (self.chunked || self.contentLength >= 0) {
                BRLog(@"HTTP body ended early (chunked=%d, received=%lld) for %@", self.chunked, self.bodyReceived, self.url);
            }
            bodyDone = YES;
            break;
        }
        [buffer appendBytes:tmp length:(NSUInteger)n];
        if (!headersDone) {
            NSError *hErr = nil;
            int rc = 0;
            while (!headersDone) {
                rc = [self parseHeadersFromBuffer:buffer error:&hErr];
                if (rc < 0) {
                    free(tmp);
                    [self finishWithError:hErr ?: BRMakeError(BRErrorBadResponse, L(@"The server sent an invalid response."))];
                    return;
                }
                if (rc == 0) break;          // need more bytes
                if (rc == 2) continue;       // interim response, parse the next block
                headersDone = YES;
            }
            if (!headersDone) continue;
            NSInteger status = self.statusCode;
            BRHTTPHeadersBlock hb = self.onHeaders;
            self.onHeaders = nil;
            if (hb) hb(status, self.responseHeaders);
            if (self.isCancelled) {
                free(tmp);
                [self finishWithError:BRMakeError(BRErrorCancelled, L(@"Cancelled"))];
                return;
            }
            if ([self.method isEqualToString:@"HEAD"] || status == 204 || status == 304) {
                bodyDone = YES;
                break;
            }
        }
        if ([self consumeBody:buffer]) bodyDone = YES;
        if (self.bodyError) {
            free(tmp);
            [self finishWithError:BRMakeError(BRErrorBadResponse, L(@"Content decoding failed."))];
            return;
        }
    }
    free(tmp);
    [self finishWithError:nil];
}

@end
