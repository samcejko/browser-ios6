#import "BRPasswords.h"
#import "BRCommon.h"
#import <Security/Security.h>

@implementation BRPasswords

+ (NSString *)siteForHost:(NSString *)host
{
    NSString *h = [host lowercaseString] ?: @"";
    return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

static NSMutableDictionary *BRPasswordQuery(NSString *site)
{
    return [@{ (__bridge id)kSecClass: (__bridge id)kSecClassInternetPassword, (__bridge id)kSecAttrServer: site } mutableCopy];
}

+ (NSArray *)accountsForHost:(NSString *)host
{
    NSString *site = [self siteForHost:host];
    if (!site.length) return @[];
    NSMutableDictionary *q = BRPasswordQuery(site);
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    q[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) != errSecSuccess || !result) return @[];
    NSArray *items = (__bridge_transfer NSArray *)result;
    NSMutableArray *accounts = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if ([account isKindOfClass:[NSString class]]) [accounts addObject:account];
    }
    return accounts;
}

+ (NSString *)passwordForHost:(NSString *)host account:(NSString *)account
{
    NSString *site = [self siteForHost:host];
    if (!site.length) return nil;
    NSMutableDictionary *q = BRPasswordQuery(site);
    q[(__bridge id)kSecAttrAccount] = account ?: @"";
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)hasPassword:(NSString *)password account:(NSString *)account host:(NSString *)host
{
    NSString *kept = [self passwordForHost:host account:account];
    return kept && [kept isEqualToString:password ?: @""];
}

+ (BOOL)savePassword:(NSString *)password account:(NSString *)account host:(NSString *)host
{
    NSString *site = [self siteForHost:host];
    NSData *data = [password ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    if (!site.length || !data.length) return NO;
    NSMutableDictionary *q = BRPasswordQuery(site);
    q[(__bridge id)kSecAttrAccount] = account ?: @"";
    SecItemDelete((__bridge CFDictionaryRef)q);
    q[(__bridge id)kSecValueData] = data;
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlocked;
    q[(__bridge id)kSecAttrLabel] = site;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    if (status != errSecSuccess) BRLog(@"Keeping a login for %@ failed (%d)", site, (int)status);
    return status == errSecSuccess;
}

+ (BOOL)neverForHost:(NSString *)host
{
    return [[[NSUserDefaults standardUserDefaults] arrayForKey:@"BRPasswordNever"] containsObject:[self siteForHost:host]];
}

+ (void)setNeverForHost:(NSString *)host
{
    NSString *site = [self siteForHost:host];
    if (!site.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *never = [[d arrayForKey:@"BRPasswordNever"] mutableCopy] ?: [NSMutableArray array];
    if (![never containsObject:site]) [never addObject:site];
    [d setObject:never forKey:@"BRPasswordNever"];
    [d synchronize];
}

+ (NSUInteger)count
{
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassInternetPassword, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                         (__bridge id)kSecReturnAttributes: @YES };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) != errSecSuccess || !result) return 0;
    NSArray *items = (__bridge_transfer NSArray *)result;
    return items.count;
}

+ (void)deleteAll
{
    SecItemDelete((__bridge CFDictionaryRef)@{ (__bridge id)kSecClass: (__bridge id)kSecClassInternetPassword });
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BRPasswordNever"];
}

@end
