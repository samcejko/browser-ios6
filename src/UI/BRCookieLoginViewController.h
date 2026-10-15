#import <UIKit/UIKit.h>

// "Log in with cookies": the user logs in to a site in another (modern) browser and pastes that site's cookies here.
// We store them in the shared jar for the site, so Surfari is logged in without ever showing the login CAPTCHA -
// Cloudflare Turnstile and the like need a JavaScript engine newer than this one. Presented modally from the browser.
@interface BRCookieLoginViewController : UIViewController

// host: the site the cookies are for (e.g. "www.furaffinity.net"); secure: the page was loaded over https.
- (instancetype)initWithHost:(NSString *)host secure:(BOOL)secure;

// Called after the cookies were stored (with how many); the browser reloads the page so the logged-in version shows.
@property (nonatomic, copy) void (^onStored)(NSUInteger count);

@end
