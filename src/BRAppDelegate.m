#import "BRAppDelegate.h"
#import "BRBrowserViewController.h"
#import "BRURLProtocol.h"
#import "BRTLSSocket.h"
#import "BRCommon.h"

@implementation BRAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?";
    BRLog(@"Browser %@ starting on %@ (iOS %@)", version, [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion);

    // Our own HTTP cache (filled explicitly by BRURLProtocol) and a permissive cookie jar, like a browser.
    NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:64 * 1024 * 1024 diskPath:@"browser-cache"];
    [NSURLCache setSharedURLCache:cache];
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];

    // Every http/https load of the UIWebView goes through our TLS stack from now on.
    [BRURLProtocol registerProtocol];
    [BRTLSSocket warmUp];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.browserViewController = [[BRBrowserViewController alloc] init];
    self.window.rootViewController = self.browserViewController;
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    BRLog(@"Memory warning");
}

@end
