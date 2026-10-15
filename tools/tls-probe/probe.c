/*
 * tls-probe: Surfari's ClientHello (src/Net/BRTLSHello.h) against real servers, built on a desktop with the same Mbed TLS
 * and the same configuration as the app (vendor/mbedtls_config_ios6.h).
 *
 * For each host it connects up to three times: with the modern hello, once more with the TLS 1.2 session the first
 * connection got, if it was a TLS 1.2 one (does the server resume it? the app keeps no TLS 1.3 tickets), and with the
 * legacy hello (the one of Surfari before 1.2.0). It prints the negotiated version, cipher suite and ALPN or the
 * refusal, the HTTP status of a GET of /, how many TLS 1.3 tickets came, what BRTLSSocket would end up with (the modern
 * hello, else the legacy one when BRLegacyHelloMayHelp allows it), and the JA4 fingerprint of both hellos.
 *
 * Build (Linux, with Mbed TLS 3.6.7 unpacked in $M and our configuration installed like .github/workflows/build.yml
 * does it):
 *   gcc -O1 -std=gnu99 -I$M/include -I$M/library -Isrc/Net tools/tls-probe/probe.c tools/tls-probe/glue_linux.c \
 *       $M/library/(every .c file) -lpthread -o tls-probe
 * Run: ./tls-probe /etc/ssl/certs/ca-certificates.crt [host[:port] ...]   (no hosts: the built-in list)
 */
#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include "mbedtls/build_info.h"
#include "mbedtls/ssl.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/error.h"
#include "mbedtls/sha256.h"
#include "psa/crypto.h"
#include "ssl_misc.h"
#include "BRTLSHello.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static mbedtls_x509_crt g_ca;
static mbedtls_entropy_context g_entropy;
static mbedtls_ctr_drbg_context g_drbg;

static const char *g_userAgent =
    "Mozilla/5.0 (iPad; CPU OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Mobile/10B329";

static const char *g_defaultHosts[] = {
    "www.furaffinity.net", "furaffinity.net", "d.furaffinity.net", "e621.net",
    "www.google.com", "www.youtube.com", "en.wikipedia.org", "github.com", "www.reddit.com", "old.reddit.com",
    "x.com", "www.facebook.com", "www.instagram.com", "www.tiktok.com", "www.twitch.tv", "kick.com",
    "open.spotify.com", "discord.com", "www.cloudflare.com", "www.amazon.com", "www.ebay.com", "www.aliexpress.com",
    "www.netflix.com", "www.microsoft.com", "www.apple.com", "www.bbc.co.uk", "www.theguardian.com",
    "www.nytimes.com", "edition.cnn.com", "stackoverflow.com", "medium.com", "www.tumblr.com", "imgur.com",
    "web.archive.org", "lite.duckduckgo.com", "www.bing.com", "www.yahoo.com", "store.steampowered.com",
    "www.deviantart.com", "mastodon.social", "bsky.app", "www.akamai.com", "www.fastly.com", "vercel.com",
    "www.netlify.com", "aws.amazon.com", "www.seznam.cz", "www.idnes.cz", "www.novinky.cz", "www.alza.cz",
    "mapy.com", "www.csfd.cz", "www.ceskatelevize.cz", "repo.samcejko.eu", "samcejko.eu",
    /* badssl.com: what an old or odd server does with each hello */
    "tls-v1-2.badssl.com:1012", "ecc256.badssl.com", "ecc384.badssl.com", "rsa2048.badssl.com",
    "rsa4096.badssl.com", "rsa8192.badssl.com", "sha256.badssl.com", "dh2048.badssl.com",
    "static-rsa.badssl.com", "cbc.badssl.com", "mozilla-modern.badssl.com", "mozilla-intermediate.badssl.com",
    "mozilla-old.badssl.com", "3des.badssl.com", "expired.badssl.com", "wrong.host.badssl.com",
    NULL
};

/* ---------------------------------------------------------------------------------------------------------------- */
/* The first record we send is the ClientHello: kept for the JA4 fingerprint                                          */

typedef struct {
    mbedtls_net_context *net;
    unsigned char hello[4096];
    size_t helloLen;
    int captured;
} capture_t;

static int capture_send(void *ctx, const unsigned char *buf, size_t len)
{
    capture_t *c = (capture_t *)ctx;
    if (!c->captured) {
        size_t room = sizeof(c->hello) - c->helloLen;
        size_t n = len < room ? len : room;
        memcpy(c->hello + c->helloLen, buf, n);
        c->helloLen += n;
        if (c->helloLen >= 5) {
            size_t recLen = ((size_t)c->hello[3] << 8) | c->hello[4];
            if (c->helloLen >= 5 + recLen) c->captured = 1;
        }
    }
    return mbedtls_net_send(c->net, buf, len);
}

/* (every bio callback gets the same context: receiving goes straight to the socket) */
static int capture_recv_timeout(void *ctx, unsigned char *buf, size_t len, uint32_t timeout)
{
    return mbedtls_net_recv_timeout(((capture_t *)ctx)->net, buf, len, timeout);
}

static int is_grease(unsigned v)
{
    return (v & 0x0f0f) == 0x0a0a && ((v >> 8) == (v & 0xff));
}

static int cmp_u16(const void *a, const void *b)
{
    return (int)*(const unsigned *)a - (int)*(const unsigned *)b;
}

static void sha12(const char *text, char out[13])
{
    unsigned char h[32];
    mbedtls_sha256((const unsigned char *)text, strlen(text), h, 0);
    for (int i = 0; i < 6; i++) sprintf(out + 2 * i, "%02x", h[i]);
    out[12] = 0;
}

/* JA4 of a ClientHello record (https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md) */
static void ja4_of(const unsigned char *rec, size_t len, char *out, size_t outLen)
{
    snprintf(out, outLen, "?");
    if (len < 5 + 4 + 2 + 32 + 1 || rec[0] != 22 || rec[5] != 1) return;
    const unsigned char *p = rec + 9, *end = rec + len;
    unsigned legacyVersion = (p[0] << 8) | p[1];
    p += 2 + 32;
    if (p + 1 > end) return;
    p += 1 + p[0];                                                   /* session id */
    if (p + 2 > end) return;
    size_t csLen = (p[0] << 8) | p[1];
    p += 2;
    if (p + csLen > end) return;
    unsigned ciphers[128];
    int nc = 0;
    for (size_t i = 0; i + 1 < csLen && nc < 128; i += 2) {
        unsigned v = (p[i] << 8) | p[i + 1];
        if (!is_grease(v)) ciphers[nc++] = v;
    }
    p += csLen;
    if (p + 1 > end) return;
    p += 1 + p[0];                                                   /* compression methods */
    unsigned exts[64];
    int ne = 0, sni = 0;
    unsigned version = legacyVersion;
    char alpn[3] = "00";
    unsigned sigs[64];
    int ns = 0;
    if (p + 2 <= end) {
        size_t extLen = (p[0] << 8) | p[1];
        p += 2;
        const unsigned char *eend = p + extLen < end ? p + extLen : end;
        while (p + 4 <= eend) {
            unsigned type = (p[0] << 8) | p[1];
            size_t l = (p[2] << 8) | p[3];
            const unsigned char *d = p + 4;
            if (d + l > eend) break;
            if (!is_grease(type)) {
                if (ne < 64) exts[ne++] = type;
                if (type == 0x0000) sni = 1;
                if (type == 0x002b && l >= 1) {                      /* supported_versions: the highest */
                    unsigned best = 0;
                    for (size_t i = 1; i + 1 < l + 1 && i + 1 <= d[0]; i += 2) {
                        unsigned v = (d[i] << 8) | d[i + 1];
                        if (!is_grease(v) && v > best) best = v;
                    }
                    if (best) version = best;
                }
                if (type == 0x0010 && l >= 3) {                      /* ALPN: first and last character of the first */
                    size_t pl = d[2];
                    if (pl >= 1 && 3 + pl <= l) {
                        alpn[0] = (char)d[3];
                        alpn[1] = (char)d[3 + pl - 1];
                    }
                }
                if (type == 0x000d && l >= 2) {                      /* signature_algorithms, in order */
                    for (size_t i = 2; i + 1 < l && ns < 64; i += 2) {
                        unsigned v = (d[i] << 8) | d[i + 1];
                        if (!is_grease(v)) sigs[ns++] = v;
                    }
                }
            }
            p = d + l;
        }
    }
    const char *ver = version == 0x0304 ? "13" : version == 0x0303 ? "12" : version == 0x0302 ? "11" : "00";
    char a[32];
    snprintf(a, sizeof(a), "t%s%c%02d%02d%s", ver, sni ? 'd' : 'i', nc > 99 ? 99 : nc, ne > 99 ? 99 : ne, alpn);

    char buf[2048];
    size_t o = 0;
    qsort(ciphers, (size_t)nc, sizeof(unsigned), cmp_u16);
    buf[0] = 0;
    for (int i = 0; i < nc; i++) o += (size_t)snprintf(buf + o, sizeof(buf) - o, "%s%04x", i ? "," : "", ciphers[i]);
    char b[13];
    sha12(buf, b);

    unsigned sorted[64];
    int nsorted = 0;
    for (int i = 0; i < ne; i++) if (exts[i] != 0x0000 && exts[i] != 0x0010) sorted[nsorted++] = exts[i];
    qsort(sorted, (size_t)nsorted, sizeof(unsigned), cmp_u16);
    o = 0;
    buf[0] = 0;
    for (int i = 0; i < nsorted; i++) o += (size_t)snprintf(buf + o, sizeof(buf) - o, "%s%04x", i ? "," : "", sorted[i]);
    if (ns) {
        o += (size_t)snprintf(buf + o, sizeof(buf) - o, "_");
        for (int i = 0; i < ns; i++) o += (size_t)snprintf(buf + o, sizeof(buf) - o, "%s%04x", i ? "," : "", sigs[i]);
    }
    char c[13];
    sha12(buf, c);
    snprintf(out, outLen, "%s_%s_%s (%d suites, %d extensions)", a, b, c, nc, ne);
}

/* ---------------------------------------------------------------------------------------------------------------- */

typedef struct {
    int ok;
    int ret;
    int alert;
    char version[16];
    char suite[64];
    char alpn[16];
    int http;            /* HTTP status; 0 none, -1 the read failed */
    int tickets;
    int resumed;         /* 1 the server resumed the session, 0 it did not, -1 not tried */
    int haveSession;
    char ja4[160];
} result_t;

static void describe(const result_t *r, char *out, size_t len)
{
    if (r->ok) {
        snprintf(out, len, "%s %s alpn=%s", r->version, r->suite, r->alpn[0] ? r->alpn : "-");
        return;
    }
    char err[120];
    mbedtls_strerror(r->ret, err, sizeof(err));
    if (r->alert) snprintf(out, len, "FAIL -0x%04x alert %d (%s)", (unsigned)-r->ret, r->alert, err);
    else snprintf(out, len, "FAIL -0x%04x (%s)", (unsigned)-r->ret, err);
}

static void connect_once(const char *host, const char *port, int legacy, const mbedtls_ssl_session *resumeFrom,
                         mbedtls_ssl_session *saveTo, result_t *r)
{
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    capture_t cap;
    mbedtls_net_init(&net);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    memset(r, 0, sizeof(*r));
    memset(&cap, 0, sizeof(cap));
    cap.net = &net;
    r->resumed = -1;

    int ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                          MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) goto out;
    BRConfigureHello(&conf, legacy);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&conf, &g_ca, NULL);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &g_drbg);
    mbedtls_ssl_conf_read_timeout(&conf, 12000);
    mbedtls_ssl_conf_session_tickets(&conf, MBEDTLS_SSL_SESSION_TICKETS_ENABLED);
    if ((ret = mbedtls_ssl_setup(&ssl, &conf)) != 0) goto out;
    if ((ret = mbedtls_ssl_set_hostname(&ssl, host)) != 0) goto out;
    int resuming = resumeFrom && mbedtls_ssl_set_session(&ssl, resumeFrom) == 0;
    if ((ret = mbedtls_net_connect(&net, host, port, MBEDTLS_NET_PROTO_TCP)) != 0) goto out;
    mbedtls_ssl_set_bio(&ssl, &cap, capture_send, NULL, capture_recv_timeout);

    int lastResume = 0, lastKex = 0;
    while (!mbedtls_ssl_is_handshake_over(&ssl)) {
        ret = mbedtls_ssl_handshake_step(&ssl);
        if (ssl.handshake) {
            lastResume = ssl.handshake->resume;
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
            lastKex = ssl.handshake->key_exchange_mode;
#endif
        }
        if (ret == 0 || ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
        if (ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
#endif
        if (ret == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE && ssl.in_msg) r->alert = ssl.in_msg[1];
        goto out;
    }
    r->ok = 1;
    snprintf(r->version, sizeof(r->version), "%s", mbedtls_ssl_get_version(&ssl));
    snprintf(r->suite, sizeof(r->suite), "%s", mbedtls_ssl_get_ciphersuite(&ssl));
#if defined(MBEDTLS_SSL_ALPN)
    const char *alpn = mbedtls_ssl_get_alpn_protocol(&ssl);
    snprintf(r->alpn, sizeof(r->alpn), "%s", alpn ? alpn : "");
#endif
    int tls13 = mbedtls_ssl_get_version_number(&ssl) == MBEDTLS_SSL_VERSION_TLS1_3;
    if (resuming) {
        r->resumed = tls13 ? lastKex == MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL : lastResume;
    }
    if (saveTo && !tls13 && mbedtls_ssl_get_session(&ssl, saveTo) == 0) r->haveSession = 1;

    char req[512];
    /* (a GET like the browser's: some servers answer HEAD differently; only the status line is read) */
    int n = snprintf(req, sizeof(req), "GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\n"
                     "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
                     "Accept-Language: en-us\r\nAccept-Encoding: gzip, deflate\r\nConnection: close\r\n\r\n", host, g_userAgent);
    const unsigned char *w = (const unsigned char *)req;
    while (n > 0) {
        int k = mbedtls_ssl_write(&ssl, w, (size_t)n);
        if (k > 0) { w += k; n -= k; continue; }
        if (k == MBEDTLS_ERR_SSL_WANT_READ || k == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
        /* (counted, not kept: the app resumes TLS 1.2 sessions only, see BRTLSHello.h) */
        if (k == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
            r->tickets++;
            continue;
        }
#endif
        r->http = -1;
        goto out;
    }
    char resp[512];
    size_t got = 0;
    for (;;) {
        int k = mbedtls_ssl_read(&ssl, (unsigned char *)resp + got, sizeof(resp) - 1 - got);
        if (k > 0) {
            got += (size_t)k;
            resp[got] = 0;
            if (strstr(resp, "\r\n") || got >= sizeof(resp) - 1) break;
            continue;
        }
        if (k == MBEDTLS_ERR_SSL_WANT_READ || k == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
        if (k == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
            r->tickets++;
            continue;
        }
#endif
        break;
    }
    int major = 0, minor = 0, status = 0;
    if (got && sscanf(resp, "HTTP/%d.%d %d", &major, &minor, &status) == 3) r->http = status;
    else r->http = -1;
    mbedtls_ssl_close_notify(&ssl);

out:
    r->ret = ret;
    if (cap.helloLen) ja4_of(cap.hello, cap.helloLen, r->ja4, sizeof(r->ja4));
    mbedtls_net_free(&net);
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <CA bundle> [host[:port] ...]\n", argv[0]);
        return 2;
    }
    if (psa_crypto_init() != PSA_SUCCESS) {
        fprintf(stderr, "psa_crypto_init failed\n");
        return 1;
    }
    mbedtls_x509_crt_init(&g_ca);
    int ca = mbedtls_x509_crt_parse_file(&g_ca, argv[1]);
    if (ca < 0) {
        fprintf(stderr, "CA bundle %s: -0x%04x\n", argv[1], (unsigned)-ca);
        return 1;
    }
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_drbg);
    if (mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy, (const unsigned char *)"tls-probe", 9) != 0) {
        fprintf(stderr, "RNG seed failed\n");
        return 1;
    }

    const char **hosts = argc > 2 ? (const char **)(argv + 2) : g_defaultHosts;
    printf("| host | modern hello | HTTP | 1.3 tickets (not kept) | 1.2 resumed | legacy hello (up to 1.1.x) | HTTP | BRTLSSocket result |\n");
    printf("|---|---|---|---|---|---|---|---|\n");
    char modernJA4[160] = "", legacyJA4[160] = "";
    int modernOK = 0, legacyOK = 0, finalOK = 0, total = 0, fellBack = 0;
    for (int i = 0; hosts[i]; i++) {
        char host[256], port[8] = "443";
        snprintf(host, sizeof(host), "%s", hosts[i]);
        char *colon = strchr(host, ':');
        if (colon) {
            *colon = 0;
            snprintf(port, sizeof(port), "%s", colon + 1);
        }
        result_t m, again, l;
        mbedtls_ssl_session s;
        mbedtls_ssl_session_init(&s);
        connect_once(host, port, 0, NULL, &s, &m);
        /* (a TLS 1.2 session only, as the app keeps: its resumption hello is a TLS 1.2 one) */
        memset(&again, 0, sizeof(again));
        int triedAgain = m.ok && m.haveSession;
        if (triedAgain) connect_once(host, port, 0, &s, NULL, &again);
        mbedtls_ssl_session_free(&s);
        connect_once(host, port, 1, NULL, NULL, &l);
        if (!modernJA4[0] && m.ja4[0]) snprintf(modernJA4, sizeof(modernJA4), "%s", m.ja4);
        if (!legacyJA4[0] && l.ja4[0]) snprintf(legacyJA4, sizeof(legacyJA4), "%s", l.ja4);

        char md[200], ld[200], fin[64];
        describe(&m, md, sizeof(md));
        describe(&l, ld, sizeof(ld));
        if (m.ok) snprintf(fin, sizeof(fin), "modern");
        else if (BRLegacyHelloMayHelp(m.ret, m.alert)) snprintf(fin, sizeof(fin), l.ok ? "legacy (2nd try)" : "fails (both)");
        else snprintf(fin, sizeof(fin), "fails (no 2nd try)");
        total++;
        modernOK += m.ok;
        legacyOK += l.ok;
        if (m.ok || (BRLegacyHelloMayHelp(m.ret, m.alert) && l.ok)) finalOK++;
        if (!m.ok && BRLegacyHelloMayHelp(m.ret, m.alert) && l.ok) fellBack++;
        const char *res = !triedAgain ? "-" : !again.ok ? "FAIL" : again.resumed == 1 ? "yes" : "NO";
        printf("| %s%s%s | %s | %d | %d | %s | %s | %d | %s |\n", host, colon ? ":" : "", colon ? port : "", md, m.http,
               m.tickets, res, ld, l.http, fin);
        fflush(stdout);
    }
    printf("\nmodern hello OK: %d/%d, legacy hello OK: %d/%d, BRTLSSocket OK: %d/%d (%d through the second try)\n\n",
           modernOK, total, legacyOK, total, finalOK, total, fellBack);
    printf("JA4 modern: `%s`\n\nJA4 legacy: `%s`\n\n", modernJA4, legacyJA4);
    printf("(Chrome 13x desktop for comparison: `t13d1516h2_8daaf6152771_d8a2da3f94cd` - GREASE and the ALPN h2/h1 "
           "differ by design)\n");
    return 0;
}
