#import "BRMemory.h"
#import "BRCommon.h"
#import "BRJSEngine.h"

#import <objc/message.h>
#include <dlfcn.h>

static NSMutableDictionary *g_activities;
static long g_lastLoggedMB;
static long g_peakMB;
static CFAbsoluteTime g_lastRelief;
static CFAbsoluteTime g_lastReport;

static const long BRMemoryLogStepMB = 24;         // a jump this big gets a log line
static const long BRMemoryReportFromMB = 160;     // jumps above this also log WebKit's numbers
static const long BRMemoryDefaultReliefMB = 240;

// Calls into WebKit from the main thread need the web thread lock (UIKit takes it the same way; it is released at
// the end of the main run loop cycle).
static void BRWebLock(void)
{
    static void (*lockFn)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lockFn = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock"); });
    if (lockFn) lockFn();
}

static id BRCallClass(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static BOOL BRCallClassVoid(NSString *className, NSString *selectorName)
{
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL))objc_msgSend)(cls, sel);
    return YES;
}

@implementation BRMemory

+ (void)setActivity:(NSString *)activity forKey:(NSString *)key
{
    if (!key) return;
    @synchronized (self) {
        if (!g_activities) g_activities = [NSMutableDictionary dictionary];
        if (activity.length) g_activities[key] = [activity copy];
        else [g_activities removeObjectForKey:key];
    }
}

+ (NSString *)activity
{
    @synchronized (self) {
        return g_activities.count ? [[g_activities allValues] componentsJoinedByString:@" + "] : nil;
    }
}

+ (void)resetPeak
{
    @synchronized (self) { g_peakMB = (long)BRResidentMemoryMB(); }
}

+ (long)peakMB
{
    @synchronized (self) { return MAX(g_peakMB, (long)BRResidentMemoryMB()); }
}

+ (long)reliefThresholdMB
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:@"BRMemoryReliefMB"] ? (long)[d integerForKey:@"BRMemoryReliefMB"] : BRMemoryDefaultReliefMB;
}

+ (void)sample
{
    long mb = (long)BRResidentMemoryMB();
    if (mb <= 0) return;
    long last;
    BOOL jump;
    @synchronized (self) {
        if (mb > g_peakMB) g_peakMB = mb;
        last = g_lastLoggedMB;
        jump = labs(mb - last) >= BRMemoryLogStepMB;
        if (jump) g_lastLoggedMB = mb;
    }
    if (jump) {
        NSString *what = [self activity];
        BRLog(@"Memory %ld MB (%@%ld)%@%@", mb, mb >= last ? @"+" : @"-", labs(mb - last), what.length ? @", busy: " : @"", what ?: @"");
        if (mb >= BRMemoryReportFromMB && CFAbsoluteTimeGetCurrent() - g_lastReport > 10) {
            g_lastReport = CFAbsoluteTimeGetCurrent();
            dispatch_async(dispatch_get_main_queue(), ^{ BRLog(@"Memory report: %@", [BRMemory webKitReport]); });
        }
    }
    long threshold = [self reliefThresholdMB];
    if (threshold > 0 && mb >= threshold && CFAbsoluteTimeGetCurrent() - g_lastRelief > 20) {
        g_lastRelief = CFAbsoluteTimeGetCurrent();
        dispatch_async(dispatch_get_main_queue(), ^{ [BRMemory relieve:[NSString stringWithFormat:@"%ld MB", mb]]; });
    }
}

+ (NSString *)webKitReport
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"resident %ld MB", (long)BRResidentMemoryMB()];
    BRWebLock();
    NSDictionary *m = BRCallClass(@"WebCoreStatistics", @"memoryStatistics");
    if ([m isKindOfClass:[NSDictionary class]]) {
        long heap = [m[@"JavaScriptHeapSize"] longValue] >> 20, heapFree = [m[@"JavaScriptFreeSize"] longValue] >> 20;
        long committed = [m[@"FastMallocCommittedVMBytes"] longValue] >> 20, freeList = [m[@"FastMallocFreeListBytes"] longValue] >> 20;
        long jit = [m[@"JavaScriptJITSize"] longValue] >> 20;
        [s appendFormat:@", page JS heap %ld MB (+%ld free), FastMalloc %ld MB (%ld free), JIT %ld MB", heap, heapFree, committed, freeList, jit];
    }
    Class stats = NSClassFromString(@"WebCoreStatistics");
    SEL countSel = NSSelectorFromString(@"javaScriptObjectsCount");
    if (stats && [stats respondsToSelector:countSel]) [s appendFormat:@", %lu JS objects", (unsigned long)((size_t (*)(id, SEL))objc_msgSend)(stats, countSel)];
    SEL globalsSel = NSSelectorFromString(@"javaScriptGlobalObjectsCount");
    if (stats && [stats respondsToSelector:globalsSel]) [s appendFormat:@" in %lu globals", (unsigned long)((size_t (*)(id, SEL))objc_msgSend)(stats, globalsSel)];
    // WebCache statistics: counts, sizes, live sizes, decoded sizes (one dictionary each, keyed by resource type)
    NSArray *list = BRCallClass(@"WebCache", @"statistics");
    if ([list isKindOfClass:[NSArray class]] && list.count >= 4 && [list[0] isKindOfClass:[NSDictionary class]] &&
        [list[1] isKindOfClass:[NSDictionary class]] && [list[3] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *count = list[0], *size = list[1], *decoded = list[3];
        [s appendFormat:@", memory cache: %ld images %ld MB (decoded %ld MB), CSS %ld KB, scripts %ld KB",
         [count[@"Images"] longValue], [size[@"Images"] longValue] >> 20, [decoded[@"Images"] longValue] >> 20,
         [size[@"CSS"] longValue] >> 10, [size[@"JavaScript"] longValue] >> 10];
    }
    NSString *what = [self activity];
    if (what.length) [s appendFormat:@", busy: %@", what];
    return s;
}

+ (void)relieve:(NSString *)reason
{
    long before = (long)BRResidentMemoryMB();
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    // our two script engines: whole heaps, recreated on the next use (0.3 to 0.5 s each)
    [[BRJSEngine transpiler] resetContext];
    [[BRJSEngine shared] resetContext];
    BRWebLock();
    // the pages' garbage, then WebKit's free lists back to the system
    BRCallClassVoid(@"WebCoreStatistics", @"garbageCollectJavaScriptObjects");
    // resources no page uses and the decoded copies of images (redecoded when painted); the iOS variant keeps the
    // application caches that +empty would delete
    BRCallClassVoid(@"WebCache", @"emptyInMemoryResources");
    BRCallClassVoid(@"WebCoreStatistics", @"returnFreeMemoryToSystem");
    long ms = (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000);
    // the engines release on their own threads, and the WebThread prunes the cache in its own turn
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BRLog(@"Memory relief (%@): %ld -> %ld MB, %ld ms on the main thread; %@", reason, before, (long)BRResidentMemoryMB(), ms, [BRMemory webKitReport]);
    });
}

@end
