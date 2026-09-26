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

+ (BOOL)isTagManagerScript:(NSData *)body
{
    if (body.length < 200) return NO;
    NSUInteger n = MIN(body.length, (NSUInteger)600);
    NSString *head = [[NSString alloc] initWithBytes:body.bytes length:n encoding:NSISOLatin1StringEncoding];
    NSRange copyright = [head rangeOfString:@"// Copyright 2012 Google Inc. All rights reserved."];
    return copyright.location != NSNotFound && copyright.location < 16 && [head rangeOfString:@"\"resource\""].location != NSNotFound;
}

static NSString * const BRTagGatewaysKey = @"BRTagGateways";

// the path as written (NSURL's path drops a trailing slash), without query and fragment
static NSString *BRRawPath(NSURL *url)
{
    NSString *s = url.absoluteString ?: @"";
    NSRange scheme = [s rangeOfString:@"://"];
    if (scheme.location == NSNotFound) return url.path ?: @"";
    NSUInteger from = scheme.location + 3;
    NSRange slash = [s rangeOfString:@"/" options:0 range:NSMakeRange(from, s.length - from)];
    if (slash.location == NSNotFound) return @"/";
    NSString *rest = [s substringFromIndex:slash.location];
    NSRange end = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    return end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
}

// host + directory of the script: "www.rohlik.cz/ta1w/" (never a whole host)
static NSString *BRTagDirectory(NSURL *url)
{
    NSString *path = BRRawPath(url);
    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound || slash.location == 0 || !url.host.length) return nil;
    return [[NSString stringWithFormat:@"%@%@", url.host, [path substringToIndex:slash.location + 1]] lowercaseString];
}

static NSMutableArray *BRTagGateways(void)
{
    static NSMutableArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:BRTagGatewaysKey];
        list = [NSMutableArray arrayWithArray:[saved isKindOfClass:[NSArray class]] ? saved : @[]];
    });
    return list;
}

+ (void)noteTagScriptAtURL:(NSURL *)url
{
    NSString *dir = BRTagDirectory(url);
    if (!dir) return;
    NSArray *snapshot = nil;
    @synchronized (self) {
        NSMutableArray *list = BRTagGateways();
        if ([list containsObject:dir]) return;
        [list addObject:dir];
        while (list.count > 64) [list removeObjectAtIndex:0];
        snapshot = [list copy];
    }
    [[NSUserDefaults standardUserDefaults] setObject:snapshot forKey:BRTagGatewaysKey];
    BRLog(@"Ad block: Google tag scripts served from %@ (answered with the stub from now on)", dir);
}

+ (BOOL)isKnownTagScriptURL:(NSURL *)url
{
    NSString *s = [[NSString stringWithFormat:@"%@%@", url.host ?: @"", BRRawPath(url)] lowercaseString];
    @synchronized (self) {
        for (NSString *dir in BRTagGateways()) if ([s hasPrefix:dir]) return YES;
    }
    return NO;
}

+ (BOOL)isTagManagerHost:(NSString *)host
{
    NSString *h = [host lowercaseString] ?: @"";
    for (NSString *d in @[@"googletagmanager.com", @"google-analytics.com"])
        if ([h isEqualToString:d] || [h hasSuffix:[@"." stringByAppendingString:d]]) return YES;
    return NO;
}

+ (NSData *)tagScriptStub
{
    static NSData *stub;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *js =
        @"(function(){var w=window,noop=function(){};"
        @"var later=function(f){setTimeout(function(){try{f()}catch(e){}},1)};"
        @"var settle=function(o){if(!o||typeof o!=='object')return;"
        @"if(typeof o.eventCallback==='function'){later(o.eventCallback);o.eventCallback=noop}"
        @"if(typeof o.hitCallback==='function'){later(o.hitCallback);o.hitCallback=noop}"
        @"var last=typeof o.length==='number'&&o.length>0?o[o.length-1]:null;"
        @"if(last&&typeof last==='object'&&typeof last.event_callback==='function'){later(last.event_callback);last.event_callback=noop}};"
        @"var dl=w.dataLayer;"
        @"if(dl&&typeof dl==='object'){"
        @"if(dl.hide&&typeof dl.hide.end==='function'){try{dl.hide.end()}catch(e){}dl.hide.end=noop}"
        @"if(typeof dl.push==='function'&&!dl.push.__brStub){var push=dl.push,p=function(){for(var i=0;i<arguments.length;i++)settle(arguments[i]);return push.apply(this,arguments)};"
        @"p.__brStub=true;dl.push=p;for(var k=0;k<dl.length;k++)settle(dl[k])}}"
        @"if(typeof w.ga==='function'&&w.ga.q&&!w.ga.loaded){var q=w.ga.q;w.ga=function(){settle(arguments[arguments.length-1])};w.ga.loaded=true;"
        @"for(var j=0;j<q.length;j++){var a=q[j];if(a&&a.length)settle(a[a.length-1])}}"
        @"try{var h=document.documentElement;h.className=h.className.replace(/\\basync-hide\\b/g,'')}catch(e){}"
        @"})();";
        stub = [js dataUsingEncoding:NSUTF8StringEncoding];
    });
    return stub;
}

@end
