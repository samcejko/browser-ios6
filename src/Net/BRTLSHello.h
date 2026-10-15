/*
 * The ClientHello Surfari sends, as plain C so that tools/tls-probe can build the very same hello on a desktop.
 * Included by BRTLSSocket.m only (static definitions).
 *
 * Mbed TLS's own hello (TLS 1.2 only, some 70 cipher suites with Camellia, ARIA, CCM and DHE, no ALPN) looks like no
 * browser's, and a Cloudflare site under attack answered it with a TCP reset during the handshake while browsers got
 * through (furaffinity.net, 2026-10). The modern hello follows Chrome on an ARM device without AES instructions, like the
 * iPad 2's Cortex-A9 (where ChaCha20-Poly1305 is also the faster cipher in software, and the constant-time one): TLS 1.3
 * and 1.2, Chrome's cipher suites, groups and signature algorithms, ALPN http/1.1 (the HTTP client speaks HTTP/1.1 only,
 * so never h2), no encrypt-then-MAC. No TLS 1.3 resumption: Mbed TLS resumes with a hello that offers TLS 1.3 alone and
 * its three suites, like no browser, for little gain (a TLS 1.3 handshake takes one round trip either way); the server's
 * tickets are not kept. What Mbed TLS cannot do (GREASE, extension permutation, certificate compression, ECH...) keeps
 * it close to a browser's hello, not equal to it.
 *
 * The legacy hello is the one of the versions before 1.2.0: Mbed TLS's defaults with TLS 1.2 at most. It is the second
 * try for a server that refuses the modern one (an old server without these suites, or one intolerant of TLS 1.3).
 */
#ifndef BR_TLS_HELLO_H
#define BR_TLS_HELLO_H

#include "mbedtls/ssl.h"
#include "mbedtls/net_sockets.h"

static const int g_modernCiphersuites[] = {
    MBEDTLS_TLS1_3_CHACHA20_POLY1305_SHA256,
    MBEDTLS_TLS1_3_AES_128_GCM_SHA256,
    MBEDTLS_TLS1_3_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
    MBEDTLS_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
    MBEDTLS_TLS_RSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_RSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_RSA_WITH_AES_128_CBC_SHA,
    MBEDTLS_TLS_RSA_WITH_AES_256_CBC_SHA,
    0
};

static const uint16_t g_modernGroups[] = {
    MBEDTLS_SSL_IANA_TLS_GROUP_X25519,
    MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1,
    MBEDTLS_SSL_IANA_TLS_GROUP_SECP384R1,
    MBEDTLS_SSL_IANA_TLS_GROUP_NONE
};

#if defined(MBEDTLS_SSL_HANDSHAKE_WITH_CERT_ENABLED)
static const uint16_t g_modernSigAlgs[] = {
    MBEDTLS_TLS1_3_SIG_ECDSA_SECP256R1_SHA256,
    MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA256,
    MBEDTLS_TLS1_3_SIG_RSA_PKCS1_SHA256,
    MBEDTLS_TLS1_3_SIG_ECDSA_SECP384R1_SHA384,
    MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA384,
    MBEDTLS_TLS1_3_SIG_RSA_PKCS1_SHA384,
    MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA512,
    MBEDTLS_TLS1_3_SIG_RSA_PKCS1_SHA512,
    MBEDTLS_TLS1_3_SIG_NONE
};
#endif

#if defined(MBEDTLS_SSL_ALPN)
static const char *g_alpnHTTP11[] = { "http/1.1", NULL };
#endif

/* The hello's protocol options, on a configuration fresh from mbedtls_ssl_config_defaults(). */
static void BRConfigureHello(mbedtls_ssl_config *conf, int legacy)
{
    mbedtls_ssl_conf_min_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_2);
    if (legacy) {
        mbedtls_ssl_conf_max_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_2);
        return;
    }
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
    mbedtls_ssl_conf_max_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_3);
    /* (psk_key_exchange_modes says psk_dhe_ke, as a browser's does; with the tickets dropped it is never used) */
    mbedtls_ssl_conf_tls13_key_exchange_modes(conf, MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL |
                                                    MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL);
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
    /* A read that met a NewSessionTicket returns MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET. Without this Mbed TLS drops
     * the ticket and waits for the next record within the same read: the WebSocket relay, which reads only when poll
     * says there is something, would wait there for the read timeout. The socket does not keep the tickets. */
    mbedtls_ssl_conf_tls13_enable_signal_new_session_tickets(conf, MBEDTLS_SSL_TLS1_3_SIGNAL_NEW_SESSION_TICKETS_ENABLED);
#endif
#else
    mbedtls_ssl_conf_max_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_2);
#endif
    mbedtls_ssl_conf_ciphersuites(conf, g_modernCiphersuites);
    mbedtls_ssl_conf_groups(conf, g_modernGroups);
#if defined(MBEDTLS_SSL_HANDSHAKE_WITH_CERT_ENABLED)
    mbedtls_ssl_conf_sig_algs(conf, g_modernSigAlgs);
#endif
#if defined(MBEDTLS_SSL_ALPN)
    mbedtls_ssl_conf_alpn_protocols(conf, g_alpnHTTP11);
#endif
#if defined(MBEDTLS_SSL_ENCRYPT_THEN_MAC)
    mbedtls_ssl_conf_encrypt_then_mac(conf, MBEDTLS_SSL_ETM_DISABLED);
#endif
}

/*
 * A refusal of the modern hello that the legacy one may get past: the alerts a server sends when it cannot agree on the
 * version or the parameters, an answer Mbed TLS cannot parse, or a server that reads the hello and hangs up. Not a
 * timeout, a cancel, a certificate error, or a server below TLS 1.2 (both hellos stop at 1.2). The legacy hello keeps TLS
 * 1.2 and the same certificate check, so a refusal forged on the way can downgrade a connection to what the versions
 * before 1.2.0 always used, but no further. (Mbed TLS's own check for a downgraded TLS 1.3 server also ends in
 * ILLEGAL_PARAMETER: tried again, but such a refusal never makes the socket remember the server, see BRTLSSocket.m.)
 */
static int BRLegacyHelloMayHelp(int ret, int alert)
{
    switch (ret) {
        case MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE:
            return alert == MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE || alert == MBEDTLS_SSL_ALERT_MSG_ILLEGAL_PARAMETER ||
                   alert == MBEDTLS_SSL_ALERT_MSG_DECODE_ERROR || alert == MBEDTLS_SSL_ALERT_MSG_PROTOCOL_VERSION ||
                   alert == MBEDTLS_SSL_ALERT_MSG_INSUFFICIENT_SECURITY || alert == MBEDTLS_SSL_ALERT_MSG_UNSUPPORTED_EXT;
        case MBEDTLS_ERR_NET_CONN_RESET:
        case MBEDTLS_ERR_SSL_CONN_EOF:
        case MBEDTLS_ERR_SSL_DECODE_ERROR:
        case MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE:
        case MBEDTLS_ERR_SSL_ILLEGAL_PARAMETER:
        case MBEDTLS_ERR_SSL_UNSUPPORTED_EXTENSION:
            return 1;
        default:
            return 0;
    }
}

#endif /* BR_TLS_HELLO_H */
