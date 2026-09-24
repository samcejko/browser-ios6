#import "BRSettings.h"
#import "BRCommon.h"

static NSString * const BRVerifyTLSKey = @"BRVerifyTLS";

@implementation BRSettings

+ (BOOL)verifyTLS
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:BRVerifyTLSKey];
    return v ? [v boolValue] : YES;
}

+ (void)setVerifyTLS:(BOOL)verify
{
    [[NSUserDefaults standardUserDefaults] setBool:verify forKey:BRVerifyTLSKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)adBlockEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BRAdBlock"];
    return v ? [v boolValue] : YES;
}

+ (void)setAdBlockEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"BRAdBlock"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)cssFixEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BRCSSFix"];
    return v ? [v boolValue] : YES;
}

+ (void)setCSSFixEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"BRCSSFix"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)jsFixEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BRJSFix"];
    return v ? [v boolValue] : YES;
}

+ (void)setJSFixEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"BRJSFix"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)transpileEnabled
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BRTranspile"];
    return v ? [v boolValue] : YES;
}

+ (void)setTranspileEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"BRTranspile"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSInteger)userAgentMode
{
    NSInteger m = [[NSUserDefaults standardUserDefaults] integerForKey:@"BRUserAgentMode"];
    return (m >= 0 && m <= 2) ? m : 0;
}

+ (void)setUserAgentMode:(NSInteger)mode
{
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"BRUserAgentMode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)userAgentOverride
{
    return [self userAgentStringForMode:[self userAgentMode]];
}

+ (NSString *)userAgentModeTitle:(NSInteger)mode
{
    switch (mode) {
        case 1: return L(@"Desktop (Safari 6)");
        case 2: return L(@"Modern iPad (Safari 17)");
    }
    return L(@"iPad with iOS 6");
}

static NSString *BRHostKey(NSString *host)
{
    NSString *h = [host lowercaseString] ?: @"";
    if ([h hasPrefix:@"www."]) h = [h substringFromIndex:4];
    return h;
}

+ (BOOL)adBlockDisabledForHost:(NSString *)host
{
    NSString *key = BRHostKey(host);
    if (!key.length) return NO;
    return [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BRAdBlockHosts"][key] boolValue];
}

+ (void)setAdBlockDisabled:(BOOL)disabled forHost:(NSString *)host
{
    NSString *key = BRHostKey(host);
    if (!key.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *hosts = [[d dictionaryForKey:@"BRAdBlockHosts"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (disabled) hosts[key] = @YES; else [hosts removeObjectForKey:key];
    [d setObject:hosts forKey:@"BRAdBlockHosts"];
    [d synchronize];
}

// Sites that refuse the iOS 6 identity outright but render (well enough) as a current iPad
static NSInteger BRBuiltInUserAgentMode(NSString *hostKey)
{
    // Google search answers "your browser is no longer supported" to Safari 6; the modern page renders its results
    if ([hostKey hasPrefix:@"google."] || [hostKey rangeOfString:@".google."].location != NSNotFound) return 2;
    return -1;
}

+ (NSInteger)defaultUserAgentModeForHost:(NSString *)host
{
    NSInteger global = [self userAgentMode];
    if (global != 0) return global;
    NSInteger builtIn = BRBuiltInUserAgentMode(BRHostKey(host));
    return builtIn >= 0 ? builtIn : global;
}

+ (NSInteger)userAgentModeForHost:(NSString *)host
{
    NSDictionary *overrides = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BRUserAgentHosts"];
    NSNumber *m = overrides[BRHostKey(host)];
    if (m && [m integerValue] >= 0 && [m integerValue] <= 2) return [m integerValue];
    return [self defaultUserAgentModeForHost:host];
}

+ (void)setUserAgentMode:(NSInteger)mode forHost:(NSString *)host
{
    NSString *key = BRHostKey(host);
    if (!key.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *overrides = [[d dictionaryForKey:@"BRUserAgentHosts"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (mode < 0 || mode == [self defaultUserAgentModeForHost:host]) [overrides removeObjectForKey:key];
    else overrides[key] = @(mode);
    [d setObject:overrides forKey:@"BRUserAgentHosts"];
    [d synchronize];
}

+ (NSString *)userAgentStringForMode:(NSInteger)mode
{
    switch (mode) {
        case 1:   // Safari 6 on OS X: the same engine generation, servers send pages the engine can render
            return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_8_5) AppleWebKit/536.30.1 (KHTML, like Gecko) Version/6.0.5 Safari/536.30.1";
        case 2:   // a current iPad: modern pages, which may or may not survive the old engine
            return @"Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1";
    }
    return nil;
}

+ (NSString *)userAgentOverrideForURL:(NSURL *)url
{
    return [self userAgentStringForMode:[self userAgentModeForHost:url.host]];
}

+ (BOOL)darkTheme
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"BRDarkTheme"];
}

+ (void)setDarkTheme:(BOOL)dark
{
    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"BRDarkTheme"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSInteger)searchEngine
{
    NSInteger e = [[NSUserDefaults standardUserDefaults] integerForKey:@"BRSearchEngine"];
    return (e >= 0 && e < [self searchEngineCount]) ? e : 0;
}

+ (void)setSearchEngine:(NSInteger)engine
{
    [[NSUserDefaults standardUserDefaults] setInteger:engine forKey:@"BRSearchEngine"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)searchEngineTitle:(NSInteger)engine
{
    switch (engine) {
        case 1: return @"Google";
        case 2: return @"Bing";
        case 3: return @"Seznam";
        case 4: {
            NSString *host = [NSURL URLWithString:[self customSearchTemplate] ?: @""].host;
            return host.length ? host : L(@"Custom");
        }
    }
    return @"DuckDuckGo";
}

+ (NSInteger)searchEngineCount
{
    return 5;
}

+ (NSString *)customSearchTemplate
{
    NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"BRCustomSearch"];
    return ([t rangeOfString:@"%s"].location != NSNotFound && [[NSURL URLWithString:[t stringByReplacingOccurrencesOfString:@"%s" withString:@"x"]].scheme.lowercaseString hasPrefix:@"http"]) ? t : nil;
}

+ (void)setCustomSearchTemplate:(NSString *)urlTemplate
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (urlTemplate.length) [d setObject:urlTemplate forKey:@"BRCustomSearch"];
    else [d removeObjectForKey:@"BRCustomSearch"];
    [d synchronize];
}

+ (NSInteger)textSizePercent
{
    NSInteger p = [[NSUserDefaults standardUserDefaults] integerForKey:@"BRTextSizePercent"];
    return (p >= 50 && p <= 300) ? p : 100;
}

+ (void)setTextSizePercent:(NSInteger)percent
{
    [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:@"BRTextSizePercent"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)privateMode
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"BRPrivateMode"];
}

+ (void)setPrivateMode:(BOOL)enabled
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (enabled == [self privateMode]) return;
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    if (enabled) {
        // remember the cookies of the normal session; they come back when private browsing ends
        NSMutableArray *snapshot = [NSMutableArray array];
        for (NSHTTPCookie *c in jar.cookies) {
            NSMutableDictionary *props = [NSMutableDictionary dictionary];
            for (NSString *k in c.properties) {
                id v = c.properties[k];
                if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) props[k] = v;
                else if ([v isKindOfClass:[NSDate class]]) props[k] = @{ @"date": @([v timeIntervalSince1970]) };
            }
            [snapshot addObject:props];
        }
        [d setObject:snapshot forKey:@"BRPrivateCookieSnapshot"];
    } else {
        for (NSHTTPCookie *c in [jar.cookies copy]) [jar deleteCookie:c];
        for (NSDictionary *props in [d arrayForKey:@"BRPrivateCookieSnapshot"]) {
            NSMutableDictionary *p = [props mutableCopy];
            for (NSString *k in props) {
                id v = props[k];
                if ([v isKindOfClass:[NSDictionary class]] && v[@"date"]) p[k] = [NSDate dateWithTimeIntervalSince1970:[v[@"date"] doubleValue]];
            }
            NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:p];
            if (c) [jar setCookie:c];
        }
        [d removeObjectForKey:@"BRPrivateCookieSnapshot"];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    }
    [d setBool:enabled forKey:@"BRPrivateMode"];
    [d synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BRPrivateModeDidChangeNotification" object:nil];
}

static BOOL BRBoolSetting(NSString *key, BOOL fallback)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}

static void BRSetBoolSetting(NSString *key, BOOL value)
{
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)doNotTrack { return BRBoolSetting(@"BRDoNotTrack", NO); }
+ (void)setDoNotTrack:(BOOL)enabled { BRSetBoolSetting(@"BRDoNotTrack", enabled); }
+ (BOOL)blockThirdPartyCookies { return BRBoolSetting(@"BRBlockThirdPartyCookies", YES); }
+ (void)setBlockThirdPartyCookies:(BOOL)enabled { BRSetBoolSetting(@"BRBlockThirdPartyCookies", enabled); }
+ (BOOL)loadImages { return BRBoolSetting(@"BRLoadImages", YES); }
+ (void)setLoadImages:(BOOL)enabled { BRSetBoolSetting(@"BRLoadImages", enabled); }
+ (BOOL)hideCookieBanners { return BRBoolSetting(@"BRHideCookieBanners", YES); }
+ (void)setHideCookieBanners:(BOOL)enabled { BRSetBoolSetting(@"BRHideCookieBanners", enabled); }
+ (BOOL)pagesDark { return BRBoolSetting(@"BRPagesDark", NO); }
+ (void)setPagesDark:(BOOL)enabled { BRSetBoolSetting(@"BRPagesDark", enabled); }

+ (NSURL *)searchURLForQuery:(NSString *)query
{
    NSString *q = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault, (__bridge CFStringRef)(query ?: @""), NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    NSString *base;
    switch ([self searchEngine]) {
        case 1: base = @"https://www.google.com/search?q="; break;
        case 2: base = @"https://www.bing.com/search?q="; break;
        case 3: base = @"https://search.seznam.cz/?q="; break;
        case 4: {
            NSString *t = [self customSearchTemplate];
            if (t) return [NSURL URLWithString:[t stringByReplacingOccurrencesOfString:@"%s" withString:q ?: @""]];
            base = @"https://lite.duckduckgo.com/lite/?q=";
            break;
        }
        default: base = @"https://lite.duckduckgo.com/lite/?q="; break;
    }
    return [NSURL URLWithString:[base stringByAppendingString:q ?: @""]];
}

+ (NSString *)homePageURLString
{
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"BRHomePage"];
    return [[NSURL URLWithString:s ?: @""].scheme.lowercaseString hasPrefix:@"http"] ? s : nil;
}

+ (void)setHomePageURLString:(NSString *)urlString
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (urlString.length) [d setObject:urlString forKey:@"BRHomePage"];
    else [d removeObjectForKey:@"BRHomePage"];
    [d synchronize];
}

+ (NSURL *)homeURL
{
    NSString *custom = [self homePageURLString];
    if (custom) return [NSURL URLWithString:custom];
    return [[NSBundle mainBundle] URLForResource:@"home" withExtension:@"html"];
}

+ (BOOL)isHomeURL:(NSURL *)url
{
    return url != nil && [url isFileURL] && [[url lastPathComponent] isEqualToString:@"home.html"];
}

@end
