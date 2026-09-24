#import <Foundation/Foundation.h>

// NSURLProtocol that serves every http/https request of the app (including all UIWebView loads)
// through BRHTTPRequest, i.e. through our own TLS stack. Handles cookies, redirects and a simple
// HTTP cache on top of NSURLCache.
// Posted on the main thread while a page loads: userInfo page (URL string), started and finished (NSNumber).
extern NSString * const BRPageProgressNotification;

// Asked on the main thread when a server wants HTTP Basic authentication. The completion may be called
// from any thread; nil user means cancelled.
typedef void (^BRAuthenticationHandler)(NSString *host, NSString *realm, void (^completion)(NSString *user, NSString *password));

@interface BRURLProtocol : NSURLProtocol

+ (void)registerProtocol;
+ (void)setAuthenticationHandler:(BRAuthenticationHandler)handler;
+ (void)forgetCredentials;                    // session credentials (Basic auth) are dropped

// What the last main document told us (for the lock icon and download detection)
+ (NSURL *)lastMainDocumentURL;
+ (NSString *)lastMainDocumentTLSInfo;       // "TLSv1.2 TLS-ECDHE-..." or nil for plain http
+ (NSString *)lastMainDocumentContentType;

@end
