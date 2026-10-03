#import <Foundation/Foundation.h>

// Logins kept in the keychain (internet passwords, server = the site's host without "www." and with a port that is not
// 443, protocol https, this device only), offered by the page shim when a login form is sent and filled in on the
// user's tap - on https pages with certificate verification on alone (the browser view controller sees to that).
// Nothing of them is ever logged.
@interface BRPasswords : NSObject

+ (NSString *)siteForHost:(NSString *)host;                     // lowercase, without "www." (a ":port" stays)
+ (NSArray *)accountsForHost:(NSString *)host;                  // account names (may hold @"" for a password alone)
+ (NSString *)passwordForHost:(NSString *)host account:(NSString *)account;
+ (BOOL)hasPassword:(NSString *)password account:(NSString *)account host:(NSString *)host;
+ (BOOL)savePassword:(NSString *)password account:(NSString *)account host:(NSString *)host;
+ (BOOL)neverForHost:(NSString *)host;                           // the user said "never for this site"
+ (void)setNeverForHost:(NSString *)host;
+ (NSUInteger)count;
+ (void)deleteAll;

@end
