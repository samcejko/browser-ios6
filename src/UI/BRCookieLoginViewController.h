#import <UIKit/UIKit.h>

// "Log in with cookies": the user logs in to a site in another (modern) browser and pastes that site's cookies here.
// We store them in the shared jar for the site, so Surfari is logged in without ever showing the login CAPTCHA -
// Cloudflare Turnstile and the like need a JavaScript engine newer than this one. Presented modally from the browser.
@interface BRCookieLoginViewController : UIViewController

// page: the page the cookies are for (http or https). Its host decides where they are stored (that host and its
// subdomains, a leading "www." dropped), its scheme whether they are Secure.
- (instancetype)initWithPageURL:(NSURL *)page;

// Called after the cookies were stored (with how many); the browser loads the page again, past the cache.
@property (nonatomic, copy) void (^onStored)(NSUInteger count);

@end
