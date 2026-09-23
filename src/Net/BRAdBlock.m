#import "BRAdBlock.h"
#import "BRCommon.h"

#include <libkern/OSAtomic.h>

static NSSet *g_domains = nil;
static dispatch_once_t g_once;
static volatile int32_t g_blocked = 0;

static void BRLoadDomains(void)
{
    NSMutableSet *set = [NSMutableSet set];
    for (NSString *name in @[@"adblock-base", @"adblock"]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"txt"];
        if (!path) continue;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (!text.length) continue;
        for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [[rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
            if (!line.length || [line hasPrefix:@"#"]) continue;
            // hosts-file style lines ("0.0.0.0 domain") are tolerated
            NSRange space = [line rangeOfString:@" "];
            if (space.location != NSNotFound) line = [line substringFromIndex:space.location + 1];
            if ([line isEqualToString:@"localhost"] || [line rangeOfString:@"."].location == NSNotFound) continue;
            [set addObject:line];
        }
    }
    g_domains = set;
    BRLog(@"Ad block list loaded: %lu domains", (unsigned long)set.count);
}

@implementation BRAdBlock

+ (void)ensureLoaded
{
    dispatch_once(&g_once, ^{ BRLoadDomains(); });
}

+ (void)warmUp
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [BRAdBlock ensureLoaded];
    });
}

+ (NSUInteger)domainCount
{
    [self ensureLoaded];
    return g_domains.count;
}

+ (BOOL)shouldBlockHost:(NSString *)host
{
    if (!host.length) return NO;
    [self ensureLoaded];
    NSSet *domains = g_domains;
    if (!domains.count) return NO;
    NSString *h = [host lowercaseString];
    for (;;) {
        if ([domains containsObject:h]) return YES;
        NSRange dot = [h rangeOfString:@"."];
        if (dot.location == NSNotFound) return NO;
        h = [h substringFromIndex:dot.location + 1];
        if ([h rangeOfString:@"."].location == NSNotFound) return NO;   // never match a bare TLD
    }
}

+ (void)noteBlockedRequest
{
    OSAtomicIncrement32(&g_blocked);
}

+ (NSUInteger)blockedRequestCount
{
    return (NSUInteger)g_blocked;
}

@end
