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
#import "BRLibrary.h"
#import "BRCommon.h"
#include <dlfcn.h>

#pragma mark - surfari: links

// What follows "surfari:" (leading slashes dropped), nil for any other scheme.
static NSString *BRSchemeTarget(NSURL *url)
{
    if (![[url.scheme lowercaseString] isEqualToString:@"surfari"]) return nil;
    NSString *s = url.absoluteString ?: @"";
    NSString *target = [s substringFromIndex:MIN(s.length, url.scheme.length + 1)];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    return target;
}

// The page a public link opens, nil when the target is not an address (a command) or not an http/https one: a
// javascript: target would run in whatever site the current tab shows, file: and data: would load local or forged pages.
static NSURL *BRPublicPageURL(NSString *target)
{
    NSString *address = target;
    if ([[address lowercaseString] hasPrefix:@"open?url="]) {
        address = [[address substringFromIndex:@"open?url=".length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    if (!address.length) return nil;
    // an explicit scheme ("https:", "javascript:"); "example.com:8443" is a host with a port
    NSRange colon = [address rangeOfString:@":"];
    BOOL hasScheme = NO;
    if (colon.location != NSNotFound && colon.location > 0) {
        NSCharacterSet *schemeChars = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-"];
        unichar next = colon.location + 1 < address.length ? [address characterAtIndex:colon.location + 1] : 0;
        hasScheme = [[address substringToIndex:colon.location] rangeOfCharacterFromSet:[schemeChars invertedSet]].location == NSNotFound
                    && !(next >= '0' && next <= '9');
    }
    if (!hasScheme) {
        // a command is one word (eval?..., home); an address has a dot, a port or [IPv6] in its host
        NSUInteger end = [address rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]].location;
        NSString *head = end == NSNotFound ? address : [address substringToIndex:end];
        if ([head rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".:["]].location == NSNotFound) return nil;
        address = [@"https://" stringByAppendingString:address];
    }
    NSURL *page = [NSURL URLWithString:address];
    NSString *scheme = [page.scheme lowercaseString];
    if (!page.host.length || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;
    return page;
}

// Same length and same bytes, compared in constant time.
static BOOL BRSameSecret(NSString *a, NSString *b)
{
    NSData *x = [a dataUsingEncoding:NSUTF8StringEncoding], *y = [b dataUsingEncoding:NSUTF8StringEncoding];
    if (!x.length || x.length != y.length) return NO;
    const uint8_t *p = x.bytes, *q = y.bytes;
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < x.length; i++) diff |= p[i] ^ q[i];
    return diff == 0;
}

// A developer command whose first key= parameter is the debug key, returned without that parameter (the commands
// read their parameters as before: set?key=<debug key>&key=BRJSFixEnabled&... still finds its own key=). nil when
// there is no debug key on the device or the link does not carry it.
static NSString *BRAuthorizedCommand(NSString *target)
{
    NSRange qm = [target rangeOfString:@"?"];
    if (qm.location == NSNotFound) return nil;
    NSString *given = nil;
    NSMutableArray *params = [NSMutableArray array];
    for (NSString *pair in [[target substringFromIndex:qm.location + 1] componentsSeparatedByString:@"&"]) {
        if (!given && [pair hasPrefix:@"key="]) given = [[pair substringFromIndex:4] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        else if (pair.length) [params addObject:pair];
    }
    NSString *expected = BRDebugKey();
    if (!given || !expected || !BRSameSecret(given, expected)) return nil;
    NSString *name = [target substringToIndex:qm.location];
    return params.count ? [NSString stringWithFormat:@"%@?%@", name, [params componentsJoinedByString:@"&"]] : name;
}

@implementation BRAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // First of all: after an update it drops stale debugging switches - before the first BRLog fixes for the whole run
    // whether the log is on (BRDebugLog), and before applyEngineTiers reads BRJSCMode - and recovers the cookie jar
    // before any request. (+initialize would run it too, but only at the first use of BRSettings.)
    [BRSettings prepareAtLaunch];
    BRLog(@"Surfari %@ (%@) starting on %@ (iOS %@)", [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?",
          [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"] ?: @"?", [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion);
    // before any script is compiled
    [BRJSEngine applyEngineTiers];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Safe start. A page that crashes WebKit after it has loaded (painting, the GPU driver) became the restored tab and
    // crashed every launch again: a stranger has no SSH to get out, and on the IPA only deleting the app - bookmarks and
    // all - helped. BRForegroundExits counts the runs in a row that ended while the app was on screen (0 while it is in
    // the background, where iOS ends apps for memory as a matter of course); from two on, the tabs are kept but not
    // loaded and the built-in start page opens. (A run that ended while a page was loading is the browser view's own
    // case, BRLoadingURL: it does not load that page again by itself but offers to, or its lighter version.)
    NSInteger foregroundExits = [defaults integerForKey:@"BRForegroundExits"];
    BOOL crashLoop = foregroundExits >= 2 && ![defaults stringForKey:@"BRLoadingURL"].length && ![BRSettings privateMode];
    if (crashLoop && BRDebugEnabled()) {
        // (a developer's device is ended with killall over SSH all the time; remove the key file to try the safe start)
        BRLog(@"%ld runs in a row ended on screen: no safe start on a developer's device", (long)foregroundExits);
        crashLoop = NO;
    }
    [defaults setInteger:foregroundExits + 1 forKey:@"BRForegroundExits"];
    [defaults synchronize];
    // (a run that has lasted two minutes on screen is no longer part of a loop: the restored page had its time)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([d integerForKey:@"BRForegroundExits"] > 1) {
            [d setInteger:1 forKey:@"BRForegroundExits"];
            [d synchronize];
        }
    });

    // Our own HTTP cache (filled explicitly by BRURLProtocol) and a permissive cookie jar, like a browser. A page that
    // comes back skips the network and the rewriting; memory stays small, it is what the iPad lacks. The disk part is
    // 300 MB, 100 MB when the device has less than 1 GB free at launch (it was 1.5 GB, sized for the owner's iPad: on a
    // nearly full 16 GB device the cache took most of what was left).
    // Cached bodies are stored after rewriting: whenever the rewriters change, the cache starts over in a directory of
    // its own and the old one is deleted in the background. (Emptying a full cache on the main thread took longer than
    // iOS allows for a launch: the app was killed at its first start after an update.)
    // 23: the first public build - the smaller cache starts empty instead of CFNetwork trimming a full 1.5 GB one at
    // launch, and no page rewritten by the shims of a pre-release build is served
    static const NSInteger BRCacheFormatVersion = 23;
    // (the rewriters' checksum too: a fixed jsfix.js went unused while the cache kept serving the scripts the old one
    // had lowered - YouTube's es5 build stayed blank after the symbol `in` fix until the cache was emptied)
    // The size is part of the name for the same reason: going down to 100 MB starts a new cache and the big one is
    // deleted in the background like an old format. Back to 300 MB only at 1.5 GB free, so that the space this deletion
    // frees does not switch it back at the next start (and every switch would start the cache over).
    NSNumber *freeBytes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL][NSFileSystemFreeSize];
    BOOL smallCache = [defaults boolForKey:@"BRSmallHTTPCache"];
    if (freeBytes) smallCache = [freeBytes unsignedLongLongValue] < (smallCache ? 1536ull : 1024ull) * 1024 * 1024;
    [defaults setBool:smallCache forKey:@"BRSmallHTTPCache"];
    NSUInteger diskCapacity = (smallCache ? 100 : 300) * 1024 * 1024;
    NSString *cacheName = [NSString stringWithFormat:@"browser-cache-%ld-%dm-%@", (long)BRCacheFormatVersion, smallCache ? 100 : 300, [BRCSSRewriter rewriterTag]];
    NSURLCache *cache = [[BRURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:diskCapacity diskPath:cacheName];
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
    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    // WebKit reads its feature switches from the app's defaults: WebGL exists in the iOS 6 engine
    // but is switched off for third party apps.
    [defaults setBool:YES forKey:@"WebKitWebGLEnabled"];
    // Developer extras (the inspector's backend) and CSS shaders (an experiment WebKit never shipped) only on a
    // developer's device: no page needs them, and the shaders are one more way into the GPU driver that crashes.
    // (Removed rather than left unset: earlier builds stored YES in the preferences file.)
    if (BRDebugEnabled()) {
        [defaults setBool:YES forKey:@"WebKitDeveloperExtras"];
        [defaults setBool:YES forKey:@"WebKitCSSCustomFilterEnabled"];
    } else {
        [defaults removeObjectForKey:@"WebKitDeveloperExtras"];
        [defaults removeObjectForKey:@"WebKitCSSCustomFilterEnabled"];
    }
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
    // (the watchdog's backtraces only go to the log, and it signals WebKit's thread during slow loads)
    if (BRDebugEnabled()) [BRWatchdog start];
    [BRMemory start];
    [BRTLSSocket warmUp];
    [BRAdBlock warmUp];
    [BRCSSRewriter warmUp];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.browserViewController = [[BRBrowserViewController alloc] init];
    // (a launch link that will be ignored, a command without the key, must not cost the user the restored tabs)
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    NSString *launchTarget = [launchURL isKindOfClass:[NSURL class]] ? BRSchemeTarget(launchURL) : nil;
    BOOL linkTakesTab = launchTarget.length && (BRPublicPageURL(launchTarget) || BRAuthorizedCommand(launchTarget));
    BOOL safeStart = crashLoop && !linkTakesTab;   // (a link opens a page of its own: the restored one stays unloaded anyway)
    self.browserViewController.skipRestore = linkTakesTab || safeStart;
    self.window.rootViewController = self.browserViewController;
    self.window.backgroundColor = [[BRTheme shared] pageBackgroundColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:[[BRTheme shared] statusBarStyle] animated:NO];
    if (safeStart) {
        // the bundled start page, not a chosen home page: that may be the very page that crashes
        NSURL *start = [[NSBundle mainBundle] URLForResource:@"home" withExtension:@"html"];
        if (start) [self.browserViewController loadURL:start];
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Safe start")
                                                        message:L(@"The app closed unexpectedly twice in a row, so this time it opened the start page instead of the last page. Your tabs are kept.")
                                                       delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil];
        [alert show];
    }
    return YES;
}

// Public: surfari:<address> opens a web page, http or https only, a bare host gets https:// (surfari:example.com,
// surfari:https://example.com/a?b=c), and so does surfari://open?url=<percent-encoded address>.
// Everything else is a developer command (`uiopen` over SSH) and works only with the debug key K (the content of
// Library/surfari-debug-key) as its first parameter: surfari:snapshot?key=K, surfari:eval?key=K&js=... Web pages and
// other apps can open this scheme too, so a command without the right key is ignored without a trace.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    // (the web view never hands surfari: links on; one the app opened itself could only have come from a page)
    if ([sourceApplication isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) return NO;
    NSString *target = BRSchemeTarget(url);
    if (!target.length) return NO;
    NSURL *page = BRPublicPageURL(target);
    if (page) {
        BRLog(@"Opening %@ from %@", page.absoluteString, sourceApplication ?: @"?");
        [self.browserViewController loadURL:page];
        return YES;
    }
    NSString *command = BRAuthorizedCommand(target);
    return command ? [self runDebugCommand:command] : NO;
}

// The developer commands, the debug key already checked and removed. Results go to tmp/ and to the log.
- (BOOL)runDebugCommand:(NSString *)target
{
    if ([target isEqualToString:@"home"]) {
        [self.browserViewController goHome];
        return YES;
    }
    if ([target hasPrefix:@"eval?"] || [target hasPrefix:@"eval/?"]) {
        // surfari:eval?key=K&js=<percent-encoded JavaScript> evaluates in the current page and logs the result
        NSRange js = [target rangeOfString:@"js="];
        NSString *code = js.location == NSNotFound ? @"" : [[target substringFromIndex:js.location + js.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *result = [self.browserViewController evaluateJavaScript:code];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"];
        [result ?: @"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"eval (%lu chars): %@", (unsigned long)result.length, result.length > 600 ? [result substringToIndex:600] : result);
        return YES;
    }
    if ([target hasPrefix:@"evalfile?"]) {
        // surfari:evalfile?key=K&path=<file> checks that a script file parses and runs in the current page (testing polyfills on the real engine)
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
        // surfari:set?key=K&key=BRJSFixEnabled&value=0&type=bool  (debugging switches over SSH; the defaults key is the
        // second key= or a name=)
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        for (NSString *pair in [[target substringFromIndex:4] componentsSeparatedByString:@"&"]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            q[[pair substringToIndex:eq.location]] = [[pair substringFromIndex:eq.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
        }
        NSString *key = q[@"name"] ?: q[@"key"], *value = q[@"value"] ?: @"", *type = q[@"type"] ?: @"string";
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
        // surfari:ua?key=K&host=m.youtube.com&mode=2  (a site's identity, as the "request desktop/mobile version" buttons
        // set it; mode -1 removes it)
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
        // surfari:dump?key=K writes the current DOM to tmp/dump.html
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
        // surfari:jsfixtest?key=K&input=<file>&opts=<json>&jsfix=<other jsfix.js> measures the transpiler on a file
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
        // surfari:mem?key=K logs WebKit's memory numbers (to tmp/eval.txt as well); &relieve=1 frees first;
        // &types=1 frees first and adds the objects by kind (a walk over the whole heap)
        if (![target isEqualToString:@"mem"]) [BRMemory relieve:@"requested"];
        NSString *report = [BRMemory webKitReport];
        if ([target hasSuffix:@"types=1"]) report = [report stringByAppendingFormat:@"\n%@", [BRMemory webKitTypesReport]];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Memory report: %@", report);
        return YES;
    }
    if ([target hasPrefix:@"profile"]) {
        // surfari:profile?key=K&secs=30 samples the WebThread for that long: where its time went, to tmp/profile.txt
        // (&thread=main: the main thread, which the WebThread waits for on every delegate message; &thread=js and
        // &thread=js3: the transpilers, where surfari:jsfixtest runs too; any other thread by its name)
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
        // surfari:symbols?key=K&addrs=0x39c63180,0x39c63096 names addresses of a crash report from the same boot (the
        // shared cache sits at the same place in every process until a restart), to tmp/symbols.txt
        NSRange ar = [target rangeOfString:@"addrs="];
        NSString *list = ar.location == NSNotFound ? @"" : [[target substringFromIndex:ar.location + ar.length] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *report = [BRProfiler symbolicate:list ?: @""];
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"symbols.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Symbols: %@", report.length > 1500 ? [report substringToIndex:1500] : report);
        return YES;
    }
    if ([target isEqualToString:@"requests"]) {
        // surfari:requests?key=K: what the page still waits for (a page whose load never ends), also to tmp/eval.txt
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
        // surfari:pasteboard?key=K writes the general pasteboard text to tmp/eval.txt (clipboard shims)
        NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
        [text writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"Pasteboard: %@", text.length > 200 ? [text substringToIndex:200] : text);
        return YES;
    }
    if ([target isEqualToString:@"history"]) {
        // surfari:history?key=K logs WebKit's back/forward lists (the long-press menu of the arrows) to tmp/eval.txt
        NSString *result = [self.browserViewController historyDescription];
        [result ?: @"" writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"eval.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BRLog(@"History: %@", result);
        return YES;
    }
    if ([target hasPrefix:@"goback?"] || [target hasPrefix:@"type?"] || [target hasPrefix:@"auth?"]) {
        // surfari:goback?key=K&n=1 (index into the last surfari:history back list), surfari:type?key=K&text=<address bar
        // text>, surfari:auth?key=K&user=u&password=p answers the pending login dialog
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
        // surfari:press?key=K&n=<index> presses a button of the alert or action sheet on screen, surfari:press?key=K&title=<text>
        // a button whose title holds the text (checking the UI over SSH)
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
        // surfari:screen?key=K writes what the screen really shows to tmp/screen.png, videos included (the layers a
        // snapshot cannot draw), through the system's own screen grab (private UIKit, resolved at run time)
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
        // surfari:snapshot?key=K writes the screen to tmp/screen.png (checking the UI over SSH)
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
    BRLog(@"Unknown command %@", target);
    return NO;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    NSString *busy = [BRMemory activity];
    BRLog(@"Memory warning at %ld MB, %ld MB available%@%@", (long)BRResidentMemoryMB(), [BRMemory availableMB], busy.length ? @", busy: " : @"", busy ?: @"");
    // (a memory kill often follows: the last bookmark or visit must be on disk by then)
    [[BRLibrary shared] flush];
    [[BRConnectionPool shared] drain];
    [BRMemory relieve:@"memory warning"];   // both script engines (recreated on the next use), page garbage, caches
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // (a suspended app is killed without notice: what the library still holds must be on disk before that)
    [[BRLibrary shared] flush];
    [[BRConnectionPool shared] drain];
    // (a kill in the background is not a page that is too big for the iPad, nor a page that crashes the app)
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BRLoadingURL"];
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"BRForegroundExits"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // (on screen again: if this run ends now, it is one run that ended on screen - the ones before it ended well)
    [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"BRForegroundExits"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [[BRLibrary shared] flush];
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"BRForegroundExits"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
