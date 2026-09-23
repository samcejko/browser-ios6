#import <Foundation/Foundation.h>

// NSURLProtocol that serves every http/https request of the app (including all UIWebView loads)
// through BRHTTPRequest, i.e. through our own TLS stack. Handles cookies, redirects and a simple
// HTTP cache on top of NSURLCache.
@interface BRURLProtocol : NSURLProtocol

+ (void)registerProtocol;

@end
