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
#import "BRProfiler.h"
#import "BRMemory.h"
#import "BRPasswords.h"
#import "BRCommon.h"
#include <dlfcn.h>

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
    // Cached bodies are stored after rewriting: whenever the rewriters change, the cache starts over in a directory of
    // its own and the old one is deleted in the background. (Emptying a full cache on the main thread took longer than
    // iOS allows for a launch: the app was killed at its first start after an update.)
    static const NSInteger BRCacheFormatVersion = 22;   // percentage heights marked (br-pcth), grid-auto-flow column strips
    // (the rewriters' checksum too: a fixed jsfix.js went unused while the cache kept serving the scripts the old one
    // had lowered - YouTube's es5 build stayed blank after the symbol `in` fix until the cache was emptied)
    NSString *cacheName = [NSString stringWithFormat:@"browser-cache-%ld-%@", (long)BRCacheFormatVersion, [BRCSSRewriter rewriterTag]];
    NSURLCache *cache = [[BRURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:1536 * 1024 * 1024 diskPath:cacheName];
    [NSURLCache setSharedURLCache:cache];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            // (iOS 6 keeps the cache as an SQLite file <diskPath> with -shm/-wal files in Caches/<bundle id>)
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString *own = [caches stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier] ?: @""];
            NSString *keepPrefix = [cacheName stringByAppendingString:@"-"];
            for (NSString *dir in @[caches, own]) {
                for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
                    if (![name hasPrefix:@"browser-cache"] || [name isEqualToString:cacheName] || [name hasPrefix:keepPrefix]) continue;
                    NSDate *t0 = [NSDate date];
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
                    BRLog(@"Old HTTP cache %@ deleted in %ld ms (format version %ld)", name, (long)(-[t0 timeIntervalSinceNow] * 1000), (long)BRCacheFormatVersion);
                }
            }
        }
    });
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
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
            // (switches of what the rewriters do make the cached rewritten bodies stale; logging and the like do not -
            // turning BRDebugJSErrors off emptied the cache, and every page loaded as on its first visit)
            if (![key hasPrefix:@"BRDebug"] && ![key hasPrefix:@"BRDump"]) [[NSURLCache sharedURLCache] removeAllCachedResponses];
            BRLog(@"Setting %@ = %@ (%@)", key, value, type);
        }
        return YES;
    }
    if ([target hasPrefix:@"ua?"]) {
        // browser:ua?host=m.youtube.com&mode=2  (a site's identity, as the "request desktop/mobile version" buttons set it;
        // mode -1 removes it)
        NSString *host = nil, *mode = nil;
        for (NSString *pair in [[target substringFromIndex:3] componentsSeparatedByString:@"&"]) {
            if ([pair hasPrefix:@"host="]) host = [pair substringFromIndex:5];
            else if ([pair hasPrefix:@"mode="]) mode = [pair substringFromIndex:5];
        }
        if (host.length && mode.length) {
            [BRSettings setUserAgentMode:[mode integerValue] forHost:host];
            BRLog(@"Identity of %@ set to mode %@", host, mode);
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
    if ([target isEqualToString:@"mem"] || [target isEqualToString:@"mem?relieve=1"] || [target isEqualToString:@"mem?types=1"]) {
        // browser:mem logs WebKit's memory numbers (to tmp/eval.txt as well); browser:mem?relieve=1 frees first;
        // browser:mem?types=1 frees first and adds the objects by kind (a walk over the whole heap)
        if (![target isEqualToString:@"mem"]) [BRMemory relieve:@"requested"];
        NSString *report = [BRMemory webKitReport];
        if ([target hasSuffix:@"types=1"]) report = [report stringByAppendingFormat:@"\n%@", [BRMemory webKitTypesReport]];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Memory report: %@", report);
        return YES;
    }
    if ([target hasPrefix:@"profile"]) {
        // browser:profile?secs=30 samples the WebThread for that long: where its time went, to tmp/profile.txt
        // (&thread=main: the main thread, which the WebThread waits for on every delegate message; &thread=js and
        // &thread=js3: the transpilers, where browser:jsfixtest runs too; any other thread by its name)
        NSRange sr = [target rangeOfString:@"secs="];
        NSInteger secs = sr.location == NSNotFound ? 20 : MAX(1, MIN(120, [[target substringFromIndex:sr.location + sr.length] integerValue]));
        NSRange tr = [target rangeOfString:@"thread="];
        NSString *threadName = tr.location == NSNotFound ? @"WebThread" : [[[target substringFromIndex:tr.location + tr.length] componentsSeparatedByString:@"&"][0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"WebThread";
        if ([threadName isEqualToString:@"js"]) threadName = @"com.samcejko.browser.js2";
        else if ([threadName isEqualToString:@"js3"]) threadName = @"com.samcejko.browser.js3";
        BRLog(@"Profiling the %@ thread for %ld s", threadName, (long)secs);
        [BRProfiler profileThreadNamed:threadName seconds:secs completion:^(NSString *report) {
            [report ?: @"(no profile: no such thread, or one is running)" writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"profile.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            BRLog(@"Profile: %@", report.length > 1500 ? [report substringToIndex:1500] : report);
        }];
        return YES;
    }
    if ([target hasPrefix:@"symbols"]) {
        // browser:symbols?addrs=0x39c63180,0x39c63096 names addresses of a crash report from the same boot (the shared
        // cache sits at the same place in every process until a restart), to tmp/symbols.txt
        NSRange ar = [target rangeOfString:@"addrs="];
        NSString *list = ar.location == NSNotFound ? @"" : [[target substringFromIndex:ar.location + ar.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *report = [BRProfiler symbolicate:list ?: @""];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"symbols.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Symbols: %@", report.length > 1500 ? [report substringToIndex:1500] : report);
        return YES;
    }
    if ([target isEqualToString:@"requests"]) {
        // browser:requests: what the page still waits for (a page whose load never ends), also to tmp/eval.txt
        NSString *report = [BRURLProtocol activeRequestsReport];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Requests: %@", report);
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
    if ([target hasPrefix:@"press?"]) {
        // browser:press?n=<index> presses a button of the alert or action sheet on screen, browser:press?title=<text> a
        // button whose title holds the text (checking the UI over SSH)
        NSString *query = [target substringFromIndex:6];
        NSString *value = [[query substringFromIndex:MIN(query.length, [query rangeOfString:@"="].location + 1)] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        BOOL byTitle = [query hasPrefix:@"title="];
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                NSInteger n = value.integerValue;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                NSInteger n = value.integerValue;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle && [v isKindOfClass:[UIButton class]] && !v.hidden && value.length
                       && [((UIButton *)v).currentTitle rangeOfString:value].location != NSNotFound) {
                [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        BRLog(@"Press %@: %@", query, pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"forgetpasswords"]) {
        [BRPasswords deleteAll];
        BRLog(@"Saved passwords deleted");
        return YES;
    }
    if ([target isEqualToString:@"screen"]) {
        // browser:screen writes what the screen really shows to tmp/screen.png, videos included (the layers a snapshot
        // cannot draw), through the system's own screen grab (private UIKit, resolved at run time)
        CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        CGImageRef shot = grab ? grab() : NULL;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if (shot) {
            ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES];
            CGImageRelease(shot);
        }
        BRLog(@"Screen grab %@: %@", ok ? @"written to" : @"failed for", path);
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
