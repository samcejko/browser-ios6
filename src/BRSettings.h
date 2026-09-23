#import <Foundation/Foundation.h>

// User preferences (NSUserDefaults) and a few fixed URLs.
@interface BRSettings : NSObject

+ (BOOL)verifyTLS;                       // default YES
+ (void)setVerifyTLS:(BOOL)verify;
+ (BOOL)adBlockEnabled;                  // default YES
+ (void)setAdBlockEnabled:(BOOL)enabled;
+ (BOOL)cssFixEnabled;                   // default YES: rewrite modern CSS for the old engine
+ (void)setCSSFixEnabled:(BOOL)enabled;

+ (NSURL *)searchURLForQuery:(NSString *)query;
+ (NSURL *)homeURL;                      // the bundled start page
+ (BOOL)isHomeURL:(NSURL *)url;

@end
