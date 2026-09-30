#import <Foundation/Foundation.h>

// The media player of iOS 6 loads audio and video with the system's own network stack, which cannot talk to servers
// that offer only current TLS ciphers (developer.mozilla.org's videos: error 4, while the page itself loads through
// the app's network layer). This small HTTP server on 127.0.0.1 hands such media to the player through the app's
// network layer instead: when a media element fails, the page shim asks /mediaproxy (BRURLProtocol) for a proxy URL
// and plays that. Range requests pass through (seeking); HLS playlists are rewritten so that their parts come
// through the proxy too. URLs carry a random secret, so only what the app handed out is served.
@interface BRMediaProxy : NSObject

+ (instancetype)shared;

// http://127.0.0.1:<port>/<secret>/<id>/<last path component>, or nil when the server could not start
- (NSString *)proxyURLStringForURL:(NSURL *)url pageURL:(NSURL *)pageURL;

// WebSockets have the same trouble: WebCore opens wss:// with the system's TLS, which knows neither today's ciphers
// nor today's root certificates (Let's Encrypt), so most secure sockets failed. The page shim asks /wsproxy
// (BRURLProtocol) for ws://127.0.0.1:<port>/<ws secret>/<id> instead; the server here answers WebCore's handshake,
// opens the real socket through the app's TLS (the page's Origin and protocols, the site's cookies) and passes the
// frames through untouched (WebCore masks what it sends, as a client must). One use per id.
- (NSString *)webSocketURLStringForURL:(NSURL *)url pageURL:(NSURL *)pageURL;

@end
