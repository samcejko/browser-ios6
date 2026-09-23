#import "BRTLSSocket.h"
#import "BRCommon.h"

#include "mbedtls/build_info.h"
#include "mbedtls/ssl.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"
#if defined(MBEDTLS_PSA_CRYPTO_C)
#include "psa/crypto.h"
#endif

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

static mbedtls_x509_crt g_cacert;
static BOOL g_caLoaded = NO;
static NSInteger g_caCount = 0;
static dispatch_once_t g_caOnce;

#pragma mark - Session cache (TLS session resumption)

#define BR_SESSION_CACHE_SIZE 32
#define BR_SESSION_MAX_AGE (6 * 3600)

typedef struct {
    char key[280];
    mbedtls_ssl_session session;
    time_t savedAt;
    int used;
} BRSessionEntry;

static BRSessionEntry g_sessions[BR_SESSION_CACHE_SIZE];
static pthread_mutex_t g_sessionLock = PTHREAD_MUTEX_INITIALIZER;

static void BRSessionKey(NSString *host, int port, char *out, size_t outLen)
{
    snprintf(out, outLen, "%s:%d", [[host lowercaseString] UTF8String] ?: "", port);
}

// Installs a remembered session into the context (before the handshake). Returns YES when one was found.
static BOOL BRSessionLoad(const char *key, mbedtls_ssl_context *ssl)
{
    BOOL ok = NO;
    pthread_mutex_lock(&g_sessionLock);
    for (int i = 0; i < BR_SESSION_CACHE_SIZE; i++) {
        BRSessionEntry *e = &g_sessions[i];
        if (!e->used || strcmp(e->key, key) != 0) continue;
        if (time(NULL) - e->savedAt > BR_SESSION_MAX_AGE) {
            mbedtls_ssl_session_free(&e->session);
            e->used = 0;
            break;
        }
        ok = mbedtls_ssl_set_session(ssl, &e->session) == 0;
        break;
    }
    pthread_mutex_unlock(&g_sessionLock);
    return ok;
}

static void BRSessionStore(const char *key, mbedtls_ssl_context *ssl)
{
    mbedtls_ssl_session s;
    mbedtls_ssl_session_init(&s);
    if (mbedtls_ssl_get_session(ssl, &s) != 0) {
        mbedtls_ssl_session_free(&s);
        return;
    }
    pthread_mutex_lock(&g_sessionLock);
    int slot = -1;
    for (int i = 0; i < BR_SESSION_CACHE_SIZE; i++) {
        if (g_sessions[i].used && strcmp(g_sessions[i].key, key) == 0) { slot = i; break; }
    }
    if (slot < 0) {
        for (int i = 0; i < BR_SESSION_CACHE_SIZE; i++) {
            if (!g_sessions[i].used) { slot = i; break; }
        }
    }
    if (slot < 0) {
        slot = 0;
        for (int i = 1; i < BR_SESSION_CACHE_SIZE; i++) {
            if (g_sessions[i].savedAt < g_sessions[slot].savedAt) slot = i;
        }
    }
    BRSessionEntry *e = &g_sessions[slot];
    if (e->used) mbedtls_ssl_session_free(&e->session);
    e->session = s;   // ownership of the session's buffers moves into the table
    strlcpy(e->key, key, sizeof(e->key));
    e->savedAt = time(NULL);
    e->used = 1;
    pthread_mutex_unlock(&g_sessionLock);
}

static void BRSessionForget(const char *key)
{
    pthread_mutex_lock(&g_sessionLock);
    for (int i = 0; i < BR_SESSION_CACHE_SIZE; i++) {
        BRSessionEntry *e = &g_sessions[i];
        if (e->used && strcmp(e->key, key) == 0) {
            mbedtls_ssl_session_free(&e->session);
            e->used = 0;
        }
    }
    pthread_mutex_unlock(&g_sessionLock);
}

#pragma mark - Helpers

static NSString *BRMbedError(int ret)
{
    char buf[200];
    mbedtls_strerror(ret, buf, sizeof(buf));
    return [NSString stringWithFormat:@"%s (-0x%04x)", buf, (unsigned int)(-ret)];
}

static void BRSetError(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = BRMakeError(code, message);
}

static void BRLoadCABundle(void)
{
    mbedtls_x509_crt_init(&g_cacert);
#if defined(MBEDTLS_PSA_CRYPTO_C)
    psa_status_t st = psa_crypto_init();
    if (st != PSA_SUCCESS) BRLog(@"psa_crypto_init failed: %d", (int)st);
#endif
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (!path) {
        BRLog(@"cacert.pem is missing from the app bundle");
        return;
    }
    NSData *pem = [NSData dataWithContentsOfFile:path];
    if (!pem.length) {
        BRLog(@"cacert.pem is empty");
        return;
    }
    NSMutableData *buf = [pem mutableCopy];
    uint8_t zero = 0;
    [buf appendBytes:&zero length:1];   // PEM input must be NUL terminated, length includes the NUL
    int ret = mbedtls_x509_crt_parse(&g_cacert, (const unsigned char *)buf.bytes, buf.length);
    if (ret < 0) {
        BRLog(@"CA bundle parse failed: %@", BRMbedError(ret));
        return;
    }
    NSInteger n = 0;
    for (mbedtls_x509_crt *c = &g_cacert; c != NULL && c->version != 0; c = c->next) n++;
    g_caCount = n;
    g_caLoaded = n > 0;
    BRLog(@"CA bundle loaded: %ld roots (%d unparsable)", (long)n, ret);
}

@implementation BRTLSSocket {
    mbedtls_net_context _net;
    mbedtls_ssl_context _ssl;
    mbedtls_ssl_config _conf;
    mbedtls_entropy_context _entropy;
    mbedtls_ctr_drbg_context _ctr;
    BOOL _initialized;
    BOOL _connected;
    volatile BOOL _cancelled;
    uint32_t _readTimeoutMs;
    char _sessionKey[280];
}

+ (void)ensureCALoaded
{
    dispatch_once(&g_caOnce, ^{ BRLoadCABundle(); });
}

+ (void)warmUp
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [BRTLSSocket ensureCALoaded];
    });
}

+ (BOOL)caBundleAvailable
{
    [self ensureCALoaded];
    return g_caLoaded;
}

+ (NSInteger)caCertificateCount
{
    [self ensureCALoaded];
    return g_caCount;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        mbedtls_net_init(&_net);
        mbedtls_ssl_init(&_ssl);
        mbedtls_ssl_config_init(&_conf);
        mbedtls_entropy_init(&_entropy);
        mbedtls_ctr_drbg_init(&_ctr);
        _initialized = YES;
        _sessionKey[0] = 0;
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

#pragma mark - TCP connect with timeout

static int BRConnectTCP(NSString *host, int port, int timeoutMs, NSError **error)
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);
    struct addrinfo *res = NULL;
    int gai = getaddrinfo([host UTF8String], portStr, &hints, &res);
    if (gai != 0 || !res) {
        BRSetError(error, BRErrorDNS, [NSString stringWithFormat:L(@"Could not resolve %@ (%s). Is the device online?"), host, gai_strerror(gai)]);
        return -1;
    }
    int fd = -1;
    int lastErr = 0;
    for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { lastErr = errno; continue; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno != EINPROGRESS) {
            lastErr = errno;
            close(fd);
            fd = -1;
            continue;
        }
        if (rc != 0) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            pfd.revents = 0;
            int pr = poll(&pfd, 1, timeoutMs);
            if (pr <= 0) {
                lastErr = (pr == 0) ? ETIMEDOUT : errno;
                close(fd);
                fd = -1;
                continue;
            }
            int soerr = 0;
            socklen_t slen = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
            if (soerr != 0) {
                lastErr = soerr;
                close(fd);
                fd = -1;
                continue;
            }
        }
        fcntl(fd, F_SETFL, flags);   // back to blocking mode
        break;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        NSString *why = lastErr == ETIMEDOUT ? L(@"connection timed out") : [NSString stringWithUTF8String:strerror(lastErr)];
        BRSetError(error, lastErr == ETIMEDOUT ? BRErrorTimeout : BRErrorConnect,
                   [NSString stringWithFormat:L(@"Could not connect to %@: %@"), host, why]);
    }
    return fd;
}

#pragma mark - TLS

- (BOOL)connectToHost:(NSString *)host port:(int)port verify:(BOOL)verify
     connectTimeoutMs:(int)connectMs readTimeoutMs:(int)readMs error:(NSError **)error
{
    _readTimeoutMs = (uint32_t)readMs;
    if (self.plain) {
        int fd = BRConnectTCP(host, port, connectMs, error);
        if (fd < 0) return NO;
        @synchronized (self) {
            _net.fd = fd;
        }
        _connected = YES;
        return YES;
    }

    [BRTLSSocket ensureCALoaded];
    int ret;
    const char *pers = "browser-ios6";

    if ((ret = mbedtls_ctr_drbg_seed(&_ctr, mbedtls_entropy_func, &_entropy, (const unsigned char *)pers, strlen(pers))) != 0) {
        BRSetError(error, BRErrorTLS, [NSString stringWithFormat:@"RNG seed failed: %@", BRMbedError(ret)]);
        return NO;
    }
    if ((ret = mbedtls_ssl_config_defaults(&_conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT)) != 0) {
        BRSetError(error, BRErrorTLS, [NSString stringWithFormat:@"TLS config failed: %@", BRMbedError(ret)]);
        return NO;
    }
    mbedtls_ssl_conf_min_tls_version(&_conf, MBEDTLS_SSL_VERSION_TLS1_2);
    if (verify) {
        if (!g_caLoaded) {
            BRSetError(error, BRErrorCertificate, L(@"The certificate bundle is missing, cannot verify the server."));
            return NO;
        }
        mbedtls_ssl_conf_authmode(&_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&_conf, &g_cacert, NULL);
    } else {
        mbedtls_ssl_conf_authmode(&_conf, MBEDTLS_SSL_VERIFY_NONE);
    }
    mbedtls_ssl_conf_rng(&_conf, mbedtls_ctr_drbg_random, &_ctr);
    mbedtls_ssl_conf_read_timeout(&_conf, (uint32_t)readMs);
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
    mbedtls_ssl_conf_session_tickets(&_conf, MBEDTLS_SSL_SESSION_TICKETS_ENABLED);
#endif

    if ((ret = mbedtls_ssl_setup(&_ssl, &_conf)) != 0) {
        BRSetError(error, BRErrorTLS, [NSString stringWithFormat:@"TLS setup failed: %@", BRMbedError(ret)]);
        return NO;
    }
    if ((ret = mbedtls_ssl_set_hostname(&_ssl, [host UTF8String])) != 0) {
        BRSetError(error, BRErrorTLS, [NSString stringWithFormat:@"TLS hostname failed: %@", BRMbedError(ret)]);
        return NO;
    }
    BRSessionKey(host, port, _sessionKey, sizeof(_sessionKey));
    BOOL resuming = BRSessionLoad(_sessionKey, &_ssl);

    int fd = BRConnectTCP(host, port, connectMs, error);
    if (fd < 0) return NO;
    @synchronized (self) {
        _net.fd = fd;
    }
    if (_cancelled) {
        BRSetError(error, BRErrorCancelled, L(@"Cancelled"));
        return NO;
    }
    mbedtls_ssl_set_bio(&_ssl, &_net, mbedtls_net_send, NULL, mbedtls_net_recv_timeout);

    while ((ret = mbedtls_ssl_handshake(&_ssl)) != 0) {
        if (_cancelled) {
            BRSetError(error, BRErrorCancelled, L(@"Cancelled"));
            return NO;
        }
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (resuming) BRSessionForget(_sessionKey);
        if (ret == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
            uint32_t flags = mbedtls_ssl_get_verify_result(&_ssl);
            char vbuf[512];
            mbedtls_x509_crt_verify_info(vbuf, sizeof(vbuf), "", flags);
            NSString *info = [[NSString stringWithUTF8String:vbuf] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *hint = (flags & (MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE)) ?
                L(@"Check the date and time of this device.") : L(@"Certificate verification can be turned off in Settings.");
            BRSetError(error, BRErrorCertificate, [NSString stringWithFormat:L(@"Server certificate rejected: %@. %@"), info, hint]);
            return NO;
        }
        if (ret == MBEDTLS_ERR_SSL_TIMEOUT) {
            BRSetError(error, BRErrorTimeout, L(@"TLS handshake timed out."));
            return NO;
        }
        BRSetError(error, BRErrorTLS, [NSString stringWithFormat:L(@"TLS handshake failed: %@"), BRMbedError(ret)]);
        return NO;
    }
    _connected = YES;
    BRSessionStore(_sessionKey, &_ssl);
    return YES;
}

- (NSString *)cipherSuite
{
    if (!_connected || self.plain) return nil;
    const char *cs = mbedtls_ssl_get_ciphersuite(&_ssl);
    return cs ? [NSString stringWithUTF8String:cs] : nil;
}

- (NSString *)tlsVersion
{
    if (!_connected) return nil;
    if (self.plain) return @"plain";
    const char *v = mbedtls_ssl_get_version(&_ssl);
    return v ? [NSString stringWithUTF8String:v] : nil;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error
{
    const unsigned char *p = (const unsigned char *)data.bytes;
    size_t left = data.length;
    while (left > 0) {
        if (_cancelled) {
            BRSetError(error, BRErrorCancelled, L(@"Cancelled"));
            return NO;
        }
        int ret = self.plain ? mbedtls_net_send(&_net, p, left) : mbedtls_ssl_write(&_ssl, p, left);
        if (ret > 0) {
            p += ret;
            left -= (size_t)ret;
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        BRSetError(error, BRErrorConnectionLost, [NSString stringWithFormat:L(@"Sending the request failed: %@"), BRMbedError(ret)]);
        return NO;
    }
    return YES;
}

- (NSInteger)readIntoBuffer:(void *)buffer maxLength:(NSUInteger)maxLength error:(NSError **)error
{
    for (;;) {
        if (_cancelled) {
            BRSetError(error, BRErrorCancelled, L(@"Cancelled"));
            return -1;
        }
        int ret = self.plain ? mbedtls_net_recv_timeout(&_net, (unsigned char *)buffer, maxLength, _readTimeoutMs)
                             : mbedtls_ssl_read(&_ssl, (unsigned char *)buffer, maxLength);
        if (ret > 0) return ret;
        if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (ret == MBEDTLS_ERR_NET_CONN_RESET) return 0;   // abrupt close without close_notify
        if (ret == MBEDTLS_ERR_SSL_TIMEOUT) {
            BRSetError(error, BRErrorTimeout, L(@"The server stopped responding (timeout)."));
            return -1;
        }
        BRSetError(error, BRErrorConnectionLost, [NSString stringWithFormat:L(@"Receiving the response failed: %@"), BRMbedError(ret)]);
        return -1;
    }
}

- (void)cancel
{
    _cancelled = YES;
    @synchronized (self) {
        if (_net.fd >= 0) shutdown(_net.fd, SHUT_RDWR);
    }
}

- (void)close
{
    if (!_initialized) return;
    if (_connected && !_cancelled && !self.plain) {
        mbedtls_ssl_close_notify(&_ssl);
    }
    @synchronized (self) {
        mbedtls_net_free(&_net);
    }
    mbedtls_ssl_free(&_ssl);
    mbedtls_ssl_config_free(&_conf);
    mbedtls_ctr_drbg_free(&_ctr);
    mbedtls_entropy_free(&_entropy);
    _initialized = NO;
    _connected = NO;
}

@end
