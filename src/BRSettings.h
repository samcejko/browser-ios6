#import <Foundation/Foundation.h>

// User preferences (NSUserDefaults) and a few fixed URLs.
@interface BRSettings : NSObject

+ (BOOL)verifyTLS;                       // default YES
+ (void)setVerifyTLS:(BOOL)verify;
+ (BOOL)adBlockEnabled;                  // default YES
+ (void)setAdBlockEnabled:(BOOL)enabled;
+ (BOOL)cssFixEnabled;                   // default YES: rewrite modern CSS for the old engine
+ (void)setCSSFixEnabled:(BOOL)enabled;
+ (BOOL)jsFixEnabled;                    // default YES: JavaScript polyfills injected into pages
+ (void)setJSFixEnabled:(BOOL)enabled;
// 0 = iPad with iOS 6 (the engine's own identity), 1 = desktop Safari 6, 2 = a current iPad (Safari 17)
+ (NSInteger)userAgentMode;
+ (void)setUserAgentMode:(NSInteger)mode;
+ (NSString *)userAgentOverride;         // nil for mode 0
+ (NSString *)userAgentModeTitle:(NSInteger)mode;

+ (BOOL)darkTheme;                       // default NO
+ (void)setDarkTheme:(BOOL)dark;

+ (NSURL *)searchURLForQuery:(NSString *)query;
+ (NSURL *)homeURL;                      // the bundled start page
+ (BOOL)isHomeURL:(NSURL *)url;

@end
