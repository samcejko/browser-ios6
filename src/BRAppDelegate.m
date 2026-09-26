#import "BRAppDelegate.h"
#import <QuartzCore/QuartzCore.h>
#import "BRBrowserViewController.h"
#import "BRTheme.h"
#import "BRURLProtocol.h"
#import "BRHTTPRequest.h"
#import "BRSettings.h"
#import "BRTLSSocket.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRCSSRewriter.h"
#import "BRJSEngine.h"
#import "BRWatchdog.h"
#import "BRMemory.h"
#import "BRCommon.h"

@implementation BRAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?";
    BRLog(@"Browser %@ starting on %@ (iOS %@)", version, [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion);
    // before any script is compiled
    [BRJSEngine applyEngineTiers];

    // Our own HTTP cache (filled explicitly by BRURLProtocol) and a permissive cookie jar, like a browser. The disk part
    // is big (the user offered 2.5 GB for caches: 1.5 GB here, 1 GB of lowered scripts): a page that comes back skips
    // the network and the rewriting; memory stays small, it is what the iPad lacks.
    NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:1536 * 1024 * 1024 diskPath:@"browser-cache"];
    [NSURLCache setSharedURLCache:cache];
    // Cached bodies are stored after rewriting; drop them whenever the rewriters change.
    static const NSInteger BRCacheFormatVersion = 19;   // scripts left unlowered for lack of memory were cached as they were
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults integerForKey:@"BRCacheFormatVersion"] != BRCacheFormatVersion) {
        [cache removeAllCachedResponses];
        [defaults setInteger:BRCacheFormatVersion forKey:@"BRCacheFormatVersion"];
        [defaults synchronize];
        BRLog(@"HTTP cache cleared (format version %ld)", (long)BRCacheFormatVersion);
    }
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    // WebKit reads its feature switches from the app's defaults: WebGL exists in the iOS 6 engine
    // but is switched off for third party apps.
    [defaults setBool:YES forKey:@"WebKitWebGLEnabled"];
    [defaults setBool:YES forKey:@"WebKitDeveloperExtras"];
    [defaults setBool:YES forKey:@"WebKitCSSCustomFilterEnabled"];
    // memory on a 512 MB device: no back/forward page cache, big images decoded through the disk cache
    [defaults setBool:NO forKey:@"WebKitUsesPageCachePreferenceKey"];
    [defaults setBool:YES forKey:@"WebKitDiskImageCacheEnabled"];
    [defaults setInteger:2 * 1024 * 1024 forKey:@"WebKitDiskImageCacheMinimumImageSize"];

    // navigator.userAgent of the web view: the same identity the network layer sends (UIWebView's own
    // string lacks the Safari token and many sites treat it as an embedded view)
    NSString *identity = [BRSettings userAgentOverride] ?: [BRHTTPRequest defaultUserAgent];
    [defaults registerDefaults:@{ @"UserAgent": identity }];

    // Every http/https load of the UIWebView goes through our TLS stack from now on.
    [BRURLProtocol registerProtocol];
    [BRWatchdog start];
    [BRMemory start];
    [BRTLSSocket warmUp];
    [BRAdBlock warmUp];
    [BRCSSRewriter warmUp];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.browserViewController = [[BRBrowserViewController alloc] init];
    self.browserViewController.skipRestore = launchOptions[UIApplicationLaunchOptionsURLKey] != nil;
    self.window.rootViewController = self.browserViewController;
    self.window.backgroundColor = [[BRTheme shared] pageBackgroundColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:[[BRTheme shared] statusBarStyle] animated:NO];
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
    if ([target hasPrefix:@"eval?"] || [target hasPrefix:@"eval/?"]) {
        // browser:eval?js=<percent-encoded JavaScript> evaluates in the current page and logs the result
        NSRange js = [target rangeOfString:@"js="];
        NSString *code = js.location == NSNotFound ? @"" : [[target substringFromIndex:js.location + js.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *result = [self.browserViewController evaluateJavaScript:code];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"];
        [result ?: @"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"eval (%lu chars): %@", (unsigned long)result.length, result.length > 600 ? [result substringToIndex:600] : result);
        return YES;
    }
    if ([target hasPrefix:@"evalfile?"]) {
        // browser:evalfile?path=<file> checks that a script file parses and runs in the current page (testing polyfills on the real engine)
        NSRange p = [target rangeOfString:@"path="];
        NSString *path = p.location == NSNotFound ? @"" : [[target substringFromIndex:p.location + p.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *source = path.length ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        NSString *result;
        if (!source) {
            result = [NSString stringWithFormat:@"cannot read %@", path];
        } else {
            NSData *json = [NSJSONSerialization dataWithJSONObject:@[source] options:0 error:NULL];
            NSString *literal = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[\"\"]";
            literal = [literal substringWithRange:NSMakeRange(1, literal.length - 2)];
            NSString *code = [NSString stringWithFormat:@"(function(src){var r='';try{new Function(src);r='parses';}catch(e){return 'PARSE ERROR: '+e.message;}"
                                                         "try{(0,eval)(src);r+=', runs';}catch(e2){r+=', RUN ERROR: '+e2.message+' | '+(e2.stack||'').slice(0,400);}return r;})(%@)", literal];
            result = [self.browserViewController evaluateJavaScript:code];
        }
        NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"];
        [result ?: @"" writeToFile:out atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"evalfile %@: %@", path.lastPathComponent, result);
        return YES;
    }
    if ([target hasPrefix:@"set?"]) {
        // browser:set?key=BRJSFixEnabled&value=0&type=bool  (debugging switches over SSH)
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        for (NSString *pair in [[target substringFromIndex:4] componentsSeparatedByString:@"&"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            q[[pair substringToIndex:eq.location]] = [[pair substringFromIndex:eq.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        }
        NSString *key = q[@"key"], *value = q[@"value"] ?: @"", *type = q[@"type"] ?: @"string";
        if (key.length) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            if ([type isEqualToString:@"bool"]) [d setBool:[value boolValue] forKey:key];
            else if ([type isEqualToString:@"int"]) [d setInteger:[value integerValue] forKey:key];
            else if ([type isEqualToString:@"remove"]) [d removeObjectForKey:key];
            else [d setObject:value forKey:key];
            [d synchronize];
            [[NSURLCache sharedURLCache] removeAllCachedResponses];
            BRLog(@"Setting %@ = %@ (%@)", key, value, type);
        }
        return YES;
    }
    if ([target isEqualToString:@"dump"]) {
        // browser:dump writes the current DOM to tmp/dump.html
        NSString *html = [self.browserViewController evaluateJavaScript:@"document.documentElement.outerHTML"];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dump.html"];
        BOOL ok = [html ?: @"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"DOM dump %@: %@ (%lu chars)", ok ? @"written to" : @"failed for", path, (unsigned long)html.length);
        return YES;
    }
    if ([target isEqualToString:@"reader"]) {
        [self.browserViewController showReader];
        return YES;
    }
    if ([target hasPrefix:@"jsfixtest?"]) {
        // browser:jsfixtest?input=<file>&opts=<json>&jsfix=<other jsfix.js> measures the transpiler on a file
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        for (NSString *pair in [[target substringFromIndex:@"jsfixtest?".length] componentsSeparatedByString:@"&"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            q[[pair substringToIndex:eq.location]] = [[pair substringFromIndex:eq.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        }
        [BRCSSRewriter runTranspileTest:q];
        return YES;
    }
    if ([target isEqualToString:@"mem"] || [target isEqualToString:@"mem?relieve=1"]) {
        // browser:mem logs WebKit's memory numbers (to tmp/eval.txt as well); browser:mem?relieve=1 frees first
        if ([target hasSuffix:@"relieve=1"]) [BRMemory relieve:@"requested"];
        NSString *report = [BRMemory webKitReport];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Memory report: %@", report);
        return YES;
    }
    if ([target isEqualToString:@"pdf"]) {
        [self.browserViewController savePageAsPDF];
        return YES;
    }
    if ([target isEqualToString:@"source"]) {
        [self.browserViewController showSource];
        return YES;
    }
    if ([target isEqualToString:@"translate"]) {
        [self.browserViewController translateCurrentPage];
        return YES;
    }
    if ([target isEqualToString:@"pasteboard"]) {
        // browser:pasteboard writes the general pasteboard text to tmp/eval.txt (clipboard shims)
        NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
        [text writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Pasteboard: %@", text.length > 200 ? [text substringToIndex:200] : text);
        return YES;
    }
    if ([target isEqualToString:@"history"]) {
        // browser:history logs WebKit's back/forward lists (the long-press menu of the arrows) to tmp/eval.txt
        NSString *result = [self.browserViewController historyDescription];
        [result ?: @"" writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"History: %@", result);
        return YES;
    }
    if ([target hasPrefix:@"goback?"] || [target hasPrefix:@"type?"] || [target hasPrefix:@"auth?"]) {
        // browser:goback?n=1 (index into the last browser:history back list), browser:type?text=<address bar text>,
        // browser:auth?user=u&password=p answers the pending login dialog
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        NSRange qm = [target rangeOfString:@"?"];
        for (NSString *pair in [[target substringFromIndex:qm.location + 1] componentsSeparatedByString:@"&"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            q[[pair substringToIndex:eq.location]] = [[pair substringFromIndex:eq.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        }
        if ([target hasPrefix:@"goback?"]) [self.browserViewController goToHistoryItemAtIndex:[q[@"n"] integerValue]];
        else if ([target hasPrefix:@"type?"]) [self.browserViewController navigateToTypedText:q[@"text"] ?: @""];
        else [self.browserViewController answerAuthenticationWithUser:q[@"user"] ?: @"" password:q[@"password"] ?: @""];
        return YES;
    }
    if ([target isEqualToString:@"snapshot"]) {
        // browser:snapshot writes the screen to tmp/screen.png (checking the UI over SSH)
        // every visible window (alerts and action sheets live in windows of their own)
        CGSize size = [UIScreen mainScreen].bounds.size;
        UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha <= 0) continue;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, w.frame.origin.x, w.frame.origin.y);
            [w.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
        BRLog(@"Snapshot %@: %@", ok ? @"written to" : @"failed for", path);
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
    NSString *busy = [BRMemory activity];
    BRLog(@"Memory warning at %ld MB, %ld MB available%@%@", (long)BRResidentMemoryMB(), [BRMemory availableMB], busy.length ? @", busy: " : @"", busy ?: @"");
    [[BRConnectionPool shared] drain];
    [BRMemory relieve:@"memory warning"];   // both script engines (recreated on the next use), page garbage, caches
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [[BRConnectionPool shared] drain];
    // (a kill in the background is not a page that is too big for the iPad)
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BRLoadingURL"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
