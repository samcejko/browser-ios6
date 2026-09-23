#import <Foundation/Foundation.h>

// Host based ad and tracker blocking. The domain list (Resources/adblock.txt, one domain per line,
// fetched at build time) is matched against the request host and all of its parent domains.
@interface BRAdBlock : NSObject

+ (void)warmUp;                                  // loads the list on a background queue
+ (BOOL)shouldBlockHost:(NSString *)host;
+ (NSUInteger)domainCount;

+ (void)noteBlockedRequest;
+ (NSUInteger)blockedRequestCount;               // total since launch

@end
