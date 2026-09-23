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

+ (NSURL *)searchURLForQuery:(NSString *)query
{
    NSString *q = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault, (__bridge CFStringRef)(query ?: @""), NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    return [NSURL URLWithString:[@"https://lite.duckduckgo.com/lite/?q=" stringByAppendingString:q ?: @""]];
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
