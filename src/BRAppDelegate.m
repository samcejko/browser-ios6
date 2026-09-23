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

// browser:https://example.com  or  browser://open?url=https://example.com  (also handy for `uiopen` over SSH)
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    NSString *target = nil;
    NSRange q = [s rangeOfString:@"url="];
    if (q.location != NSNotFound) {
        target = [[s substringFromIndex:q.location + q.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    } else if ([s hasPrefix:@"browser:"]) {
        target = [s substringFromIndex:@"browser:".length];
        while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    }
    if (!target.length) return YES;
    if ([target rangeOfString:@"://"].location == NSNotFound) target = [@"https://" stringByAppendingString:target];
    NSURL *targetURL = [NSURL URLWithString:target];
    if (!targetURL) return NO;
    BRLog(@"Opening %@ from %@", targetURL.absoluteString, sourceApplication ?: @"?");
    [self.browserViewController loadURL:targetURL];
    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    BRLog(@"Memory warning");
}

@end
