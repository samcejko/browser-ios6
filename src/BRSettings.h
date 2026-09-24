#import <Foundation/Foundation.h>

// User preferences (NSUserDefaults) and a few fixed URLs.
@interface BRSettings : NSObject

+ (BOOL)verifyTLS;                       // default YES
+ (void)setVerifyTLS:(BOOL)verify;
+ (BOOL)adBlockEnabled;                  // default YES
+ (void)setAdBlockEnabled:(BOOL)enabled;
+ (BOOL)adBlockDisabledForHost:(NSString *)host;        // per-site exception ("allow ads on this site")
+ (void)setAdBlockDisabled:(BOOL)disabled forHost:(NSString *)host;
+ (BOOL)cssFixEnabled;                   // default YES: rewrite modern CSS for the old engine
+ (void)setCSSFixEnabled:(BOOL)enabled;
+ (BOOL)jsFixEnabled;                    // default YES: JavaScript polyfills injected into pages
+ (void)setJSFixEnabled:(BOOL)enabled;
// 0 = iPad with iOS 6 (the engine's own identity), 1 = desktop Safari 6, 2 = a current iPad (Safari 17)
+ (NSInteger)userAgentMode;
+ (void)setUserAgentMode:(NSInteger)mode;
+ (NSString *)userAgentOverride;         // nil for mode 0
+ (NSString *)userAgentModeTitle:(NSInteger)mode;
// Per-site identity (Safari's "request desktop website"): overrides the global mode for one host
+ (NSInteger)userAgentModeForHost:(NSString *)host;
+ (void)setUserAgentMode:(NSInteger)mode forHost:(NSString *)host;   // -1 removes the override
+ (NSString *)userAgentOverrideForURL:(NSURL *)url;                  // nil when the engine's own identity applies

+ (BOOL)darkTheme;                       // default NO
+ (void)setDarkTheme:(BOOL)dark;

// 0 = DuckDuckGo Lite, 1 = Google, 2 = Bing, 3 = Seznam, 4 = custom template with %s
+ (NSInteger)searchEngine;
+ (void)setSearchEngine:(NSInteger)engine;
+ (NSString *)searchEngineTitle:(NSInteger)engine;
+ (NSInteger)searchEngineCount;
+ (NSString *)customSearchTemplate;      // e.g. https://search.example.com/?q=%s (nil when none)
+ (void)setCustomSearchTemplate:(NSString *)urlTemplate;

+ (NSInteger)textSizePercent;            // 100 = the page's own size
+ (void)setTextSizePercent:(NSInteger)percent;

// Private browsing: no history, no cache writes, cookies restored to the state before it was switched on
+ (BOOL)privateMode;
+ (void)setPrivateMode:(BOOL)enabled;

+ (BOOL)doNotTrack;                      // default NO: sends DNT: 1 and Sec-GPC: 1
+ (void)setDoNotTrack:(BOOL)enabled;
+ (BOOL)blockThirdPartyCookies;          // default YES (like Safari): cookies only for the site shown in the address bar
+ (void)setBlockThirdPartyCookies:(BOOL)enabled;
+ (BOOL)loadImages;                      // default YES; off = data saver, images are served blank
+ (void)setLoadImages:(BOOL)enabled;
+ (BOOL)hideCookieBanners;               // default YES: known consent dialogs are hidden by injected CSS
+ (void)setHideCookieBanners:(BOOL)enabled;
+ (BOOL)pagesDark;                       // default NO: pages are shown inverted (dark) through a CSS filter
+ (void)setPagesDark:(BOOL)enabled;

+ (NSURL *)searchURLForQuery:(NSString *)query;
+ (NSURL *)homeURL;                      // the chosen home page, or the bundled start page
+ (BOOL)isHomeURL:(NSURL *)url;          // the bundled start page (address bar stays empty for it)
+ (NSString *)homePageURLString;         // nil = the bundled start page
+ (void)setHomePageURLString:(NSString *)urlString;

@end
