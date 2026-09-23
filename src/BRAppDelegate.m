#import "BRAppDelegate.h"
#import "BRBrowserViewController.h"
#import "BRURLProtocol.h"
#import "BRTLSSocket.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRCSSRewriter.h"
#import "BRJSTranspiler.h"
#import "BRJSEngine.h"
#import "BRCommon.h"

@implementation BRAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?";
    BRLog(@"Browser %@ starting on %@ (iOS %@)", version, [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion);

    // Our own HTTP cache (filled explicitly by BRURLProtocol) and a permissive cookie jar, like a browser.
    NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:64 * 1024 * 1024 diskPath:@"browser-cache"];
    [NSURLCache setSharedURLCache:cache];
    // Cached bodies are stored after rewriting; drop them whenever the rewriters change.
    static const NSInteger BRCacheFormatVersion = 5;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults integerForKey:@"BRCacheFormatVersion"] != BRCacheFormatVersion) {
        [cache removeAllCachedResponses];
        [defaults setInteger:BRCacheFormatVersion forKey:@"BRCacheFormatVersion"];
        [defaults synchronize];
        BRLog(@"HTTP cache cleared (format version %ld)", (long)BRCacheFormatVersion);
    }
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];

    // Every http/https load of the UIWebView goes through our TLS stack from now on.
    [BRURLProtocol registerProtocol];
    [BRTLSSocket warmUp];
    [BRAdBlock warmUp];
    [BRCSSRewriter warmUp];
    [BRJSTranspiler warmUp];

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
    if ([target isEqualToString:@"home"]) {
        [self.browserViewController goHome];
        return YES;
    }
    if ([target isEqualToString:@"selftest"]) {
        [BRJSTranspiler runBenchmark];
        return YES;
    }
    if ([target rangeOfString:@"://"].location == NSNotFound) target = [@"https://" stringByAppendingString:target];
    NSURL *targetURL = [NSURL URLWithString:target];
    if (!targetURL) return NO;
    BRLog(@"Opening %@ from %@", targetURL.absoluteString, sourceApplication ?: @"?");
    [self.browserViewController loadURL:targetURL];
    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    BRLog(@"Memory warning at %ld MB", (long)BRResidentMemoryMB());
    [[BRConnectionPool shared] drain];
    [[BRJSEngine shared] resetContext];   // frees Babel (about 75 MB); it is loaded again when needed
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [[BRConnectionPool shared] drain];
}

@end
