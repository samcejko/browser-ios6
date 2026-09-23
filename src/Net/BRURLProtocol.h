#import <Foundation/Foundation.h>

// NSURLProtocol that serves every http/https request of the app (including all UIWebView loads)
// through BRHTTPRequest, i.e. through our own TLS stack. Handles cookies, redirects and a simple
// HTTP cache on top of NSURLCache.
// Posted on the main thread while a page loads: userInfo page (URL string), started and finished (NSNumber).
extern NSString * const BRPageProgressNotification;

@interface BRURLProtocol : NSURLProtocol

+ (void)registerProtocol;

// What the last main document told us (for the lock icon and download detection)
+ (NSURL *)lastMainDocumentURL;
+ (NSString *)lastMainDocumentTLSInfo;       // "TLSv1.2 TLS-ECDHE-..." or nil for plain http
+ (NSString *)lastMainDocumentContentType;

@end
