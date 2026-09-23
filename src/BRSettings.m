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
    switch ([self userAgentMode]) {
        case 1:   // Safari 6 on OS X: the same engine generation, servers send pages the engine can render
            return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_8_5) AppleWebKit/536.30.1 (KHTML, like Gecko) Version/6.0.5 Safari/536.30.1";
        case 2:   // a current iPad: modern pages, which may or may not survive the old engine
            return @"Mozilla/5.0 (iPad; CPU OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1";
    }
    return nil;
}

+ (NSString *)userAgentModeTitle:(NSInteger)mode
{
    switch (mode) {
        case 1: return L(@"Desktop (Safari 6)");
        case 2: return L(@"Modern iPad (Safari 17)");
    }
    return L(@"iPad with iOS 6");
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
    }
    return @"DuckDuckGo";
}

+ (NSInteger)searchEngineCount
{
    return 4;
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

+ (NSURL *)searchURLForQuery:(NSString *)query
{
    NSString *q = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault, (__bridge CFStringRef)(query ?: @""), NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    NSString *base;
    switch ([self searchEngine]) {
        case 1: base = @"https://www.google.com/search?q="; break;
        case 2: base = @"https://www.bing.com/search?q="; break;
        case 3: base = @"https://search.seznam.cz/?q="; break;
        default: base = @"https://lite.duckduckgo.com/lite/?q="; break;
    }
    return [NSURL URLWithString:[base stringByAppendingString:q ?: @""]];
}

+ (NSURL *)homeURL
{
    return [[NSBundle mainBundle] URLForResource:@"home" withExtension:@"html"];
}

+ (BOOL)isHomeURL:(NSURL *)url
{
    return url != nil && [url isFileURL] && [[url lastPathComponent] isEqualToString:@"home.html"];
}

@end
