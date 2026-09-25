#import "BRMemory.h"
#import "BRCommon.h"
#import "BRJSEngine.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <unistd.h>

NSString * const BRMemoryEmergencyNotification = @"BRMemoryEmergencyNotification";
NSString * const BRMemoryGraphicsNotification = @"BRMemoryGraphicsNotification";

// Levels by what the whole system has available (free + inactive + purgeable). Measured on the iPad 2 (512 MB):
// with nothing open about 220-250 MB are available, iOS warns at 40-60 MB and kills the frontmost app at 15-25 MB
// (memory can drop 15 MB in a few seconds while a big script is lowered, so the last resort starts well above that).
static const long BRAvailTightMB = 100, BRAvailCriticalMB = 70, BRAvailEmergencyMB = 45;
static volatile BOOL g_pageLoading;
static CFAbsoluteTime g_loadEnded;
static CFAbsoluteTime g_lastEmergency;
static CFAbsoluteTime g_lastGraphics;
// The page's graphics are too big when its layers hold this much (estimated; a normal page has 2-12 MB, one that
// runs away grows by 50 MB a second: 41 -> 268 MB in 5 s on CNN) or there are this many of them (a composited video
// or fixed box makes everything painted over it a layer too: 469 on CNN), less when the system is short, or when
// this much memory went in a few seconds without the app's resident memory growing (GPU memory is not resident).
static const long BRLayersMB = 32, BRLayersTightMB = 16, BRLayersCriticalMB = 8, BRLayersDrawnMax = 150, BRUnexplainedDropMB = 60;

static NSMutableDictionary *g_activities;
static long g_lastLoggedMB;
static long g_lastLoggedAvailable = -1;
static long g_lastLoggedLayerMB;
static long g_peakMB;
static CFAbsoluteTime g_lastRelief;
static CFAbsoluteTime g_lastReport;
static __weak CALayer *g_watchedLayer;

static const long BRMemoryLogStepMB = 24;         // a jump this big gets a log line
static const long BRMemoryLogDropMB = 40;         // and so does a drop of the system's available memory this big
static const long BRMemoryReportFromMB = 160;     // jumps above this also log WebKit's numbers
static const long BRMemoryDefaultReliefMB = 240;

// Calls into WebKit from the main thread need the web thread lock (UIKit takes it the same way; it is released at
// the end of the main run loop cycle). Taking it waits for the page's JavaScript, up to seconds on a heavy page, so
// the regular work goes to the WebThread itself with WebThreadRun instead.
static void BRWebLock(void)
{
    static void (*lockFn)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lockFn = (void (*)(void))dlsym(RTLD_DEFAULT, "WebThreadLock"); });
    if (lockFn) lockFn();
}

typedef void (*BRWebThreadRunFn)(void (^block)(void));

static BRWebThreadRunFn BRWebThreadRun(void)
{
    static BRWebThreadRunFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (BRWebThreadRunFn)dlsym(RTLD_DEFAULT, "WebThreadRun"); });
    return fn;
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

+ (long)availableMB
{
    static host_t host;
    static vm_size_t page;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ host = mach_host_self(); page = 4096; host_page_size(host, &page); });
    vm_statistics_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO_COUNT;
    if (host_statistics(host, HOST_VM_INFO, (host_info_t)&vm, &count) != KERN_SUCCESS) return 1000;
    uint64_t pages = (uint64_t)vm.free_count + vm.inactive_count + vm.purgeable_count;
    return (long)(pages * page / (1024 * 1024));
}

+ (BRMemoryLevel)levelFor:(long)available
{
    if (available < BRAvailEmergencyMB) return BRMemoryLevelEmergency;
    if (available < BRAvailCriticalMB) return BRMemoryLevelCritical;
    if (available < BRAvailTightMB) return BRMemoryLevelTight;
    return BRMemoryLevelNormal;
}

+ (BRMemoryLevel)level
{
    return [self levelFor:[self availableMB]];
}

+ (void)setPageLoading:(BOOL)loading
{
    if (!loading && g_pageLoading) g_loadEnded = CFAbsoluteTimeGetCurrent();
    g_pageLoading = loading;
}

// loading, or its scripts are still settling (lazy images, ads and players come in right after the load)
static BOOL BRPageBusy(void)
{
    return g_pageLoading || CFAbsoluteTimeGetCurrent() - g_loadEnded < 20;
}

+ (BOOL)waitForAvailableMB:(long)needMB timeout:(NSTimeInterval)timeout reason:(NSString *)reason engine:(BRJSEngine *)engine
{
    long available = [self availableMB];
    if (available >= needMB) return YES;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BRLog(@"Memory: %@ waits for %ld MB (%ld available)", reason, needMB, available);
    if (engine) [engine releaseContextNow];   // the calling engine's own heap (this is its thread)
    CFAbsoluteTime lastRelief = 0;
    while ([NSDate timeIntervalSinceReferenceDate] - t0 < timeout) {
        if (CFAbsoluteTimeGetCurrent() - lastRelief > 4) {
            lastRelief = CFAbsoluteTimeGetCurrent();
            [self relieve:@"waiting"];
        }
        usleep(250000);
        available = [self availableMB];
        if (available >= needMB) break;
    }
    BOOL ok = available >= needMB;
    BRLog(@"Memory: %@ %@ after %ld ms (%ld MB available)", reason, ok ? @"goes on" : @"stopped waiting",
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), available);
    return ok;
}

// its own thread: every 2 s, every 0.5 s while a page loads or memory is short
+ (void)start
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        t.name = @"com.samcejko.browser.memory";
        [t start];
    });
}

+ (void)run
{
    for (;;) {
        @autoreleasepool {
            BRMemoryLevel level = [self sample];
            usleep(BRPageBusy() || level >= BRMemoryLevelTight ? 500000 : 2000000);
        }
    }
}

typedef struct { long layers, drawn, tiled; double bytes; } BRLayerTally;

static void BRTallyLayers(CALayer *layer, BRLayerTally *t, NSMutableArray *big, int depth)
{
    if (depth > 200) return;
    t->layers++;
    CGSize size = layer.bounds.size;
    BOOL tiled = [layer isKindOfClass:[CATiledLayer class]];   // (draws only the tiles in view: not counted)
    if (layer.contents || tiled) {
        CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1;
        double bytes = (double)size.width * size.height * scale * scale * 4;
        if (tiled) t->tiled++;
        else { t->drawn++; t->bytes += bytes; }
        if (big && bytes >= 2 * 1024 * 1024)
            [big addObject:@[@(bytes), [NSString stringWithFormat:@"%@ %.0fx%.0f%@", NSStringFromClass([layer class]), size.width, size.height, tiled ? @" tiled" : @""]]];
    }
    for (CALayer *sub in layer.sublayers) BRTallyLayers(sub, t, big, depth + 1);   // (a copy: safe while WebKit changes the tree)
}

// the layers under the watched layer with their backing store estimated from the size (4 bytes a pixel)
+ (BRLayerTally)layerTally:(NSMutableArray *)big
{
    BRLayerTally t = { 0, 0, 0, 0 };
    CALayer *root = g_watchedLayer;
    if (root) BRTallyLayers(root, &t, big, 0);
    return t;
}

typedef struct { CFAbsoluteTime t; long available, resident; } BRMemorySample;
static BRMemorySample g_history[16];
static unsigned g_historyCount;

// the memory thread: how much the system lost in the last few seconds beyond what the app's resident memory grew (MB)
static long BRUnexplainedDrop(CFAbsoluteTime now, long available, long mb)
{
    long worst = 0;
    for (unsigned i = 0; i < MIN(g_historyCount, 16u); i++) {
        BRMemorySample s = g_history[i];
        if (now - s.t > 6) continue;
        long gone = s.available - available - MAX(mb - s.resident, 0);
        if (gone > worst) worst = gone;
    }
    g_history[g_historyCount++ % 16] = (BRMemorySample){ now, available, mb };
    return worst;
}

+ (BRMemoryLevel)sample
{
    long mb = (long)BRResidentMemoryMB();
    if (mb <= 0) return BRMemoryLevelNormal;
    long available = [self availableMB];
    BRMemoryLevel level = [self levelFor:available];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // the page's graphics: estimated from its layers (CALayer reads are safe from any thread)
    long layerMB = -1, drawn = 0;
    if (g_watchedLayer) {
        @autoreleasepool { BRLayerTally t = [self layerTally:nil]; layerMB = (long)(t.bytes / 1048576); drawn = t.drawn; }
    }
    long unexplained = BRUnexplainedDrop(now, available, mb);
    long last;
    BOOL jump, drop;
    @synchronized (self) {
        if (mb > g_peakMB) g_peakMB = mb;
        last = g_lastLoggedMB;
        // (the system can run short while the app itself hardly grows: the graphics memory of a page is not resident)
        if (available > g_lastLoggedAvailable) g_lastLoggedAvailable = available;   // a drop counts from the recent high
        drop = g_lastLoggedAvailable - available >= BRMemoryLogDropMB;
        jump = labs(mb - last) >= BRMemoryLogStepMB || drop || (layerMB >= 0 && labs(layerMB - g_lastLoggedLayerMB) >= BRMemoryLogStepMB / 2);
        if (jump) { g_lastLoggedMB = mb; g_lastLoggedAvailable = available; if (layerMB >= 0) g_lastLoggedLayerMB = layerMB; }
    }
    if (jump) {
        NSString *what = [self activity];
        NSString *graphics = layerMB >= 0 ? [NSString stringWithFormat:@", layers %ld MB (%ld drawn)", layerMB, drawn] : @"";
        if (unexplained >= 24) graphics = [graphics stringByAppendingFormat:@", %ld MB gone outside the app", unexplained];
        BRLog(@"Memory %ld MB (%@%ld), %ld MB available%@%@%@", mb, mb >= last ? @"+" : @"-", labs(mb - last), available, graphics,
              what.length ? @", busy: " : @"", what ?: @"");
        BRWebThreadRunFn run = BRWebThreadRun();
        if (run && (mb >= BRMemoryReportFromMB || drop) && CFAbsoluteTimeGetCurrent() - g_lastReport > 10) {
            g_lastReport = CFAbsoluteTimeGetCurrent();
            run(^{ BRLog(@"Memory report: %@", [BRMemory webKitNumbers]); });
        }
    }
    // graphics: the page is drawn without composited layers (slower animations, flat 3D) before it gets the app killed
    BOOL heavy = layerMB >= BRLayersMB || drawn >= BRLayersDrawnMax ||
                 (level >= BRMemoryLevelTight && (layerMB >= BRLayersTightMB || unexplained >= BRUnexplainedDropMB)) ||
                 (level >= BRMemoryLevelCritical && layerMB >= BRLayersCriticalMB);
    if (heavy && now - g_lastGraphics > 10) {
        g_lastGraphics = now;
        BRLog(@"Memory: the page's graphics are too big (%ld MB available, %ld layers drawn, %ld MB, %ld MB gone outside the app)", available, drawn, layerMB, unexplained);
        dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:BRMemoryGraphicsNotification object:nil]; });
    }
    // relief: when the app itself is big, or earlier when the system is short (then more often)
    long threshold = [self reliefThresholdMB];
    BOOL big = threshold > 0 && mb >= threshold;
    if ((big && now - g_lastRelief > 20) || (level >= BRMemoryLevelCritical && now - g_lastRelief > 6)) {
        g_lastRelief = now;
        NSString *why = level >= BRMemoryLevelCritical ? [NSString stringWithFormat:@"%ld MB available", available] : [NSString stringWithFormat:@"%ld MB", mb];
        dispatch_async(dispatch_get_main_queue(), ^{ [BRMemory relieve:why]; });
    }
    // the last resort while a page loads: stop loading it, so that iOS does not have to close the app
    if (level == BRMemoryLevelEmergency && g_pageLoading && now - g_lastEmergency > 15) {
        g_lastEmergency = now;
        BRLog(@"Memory emergency: %ld MB available, %ld MB used: the page load is stopped", available, mb);
        dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:BRMemoryEmergencyNotification object:nil]; });
    }
    return level;
}

// the WebThread, or a thread holding the web lock
+ (NSString *)webKitNumbers
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"resident %ld MB", (long)BRResidentMemoryMB()];
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
    NSString *layers = [self layerNumbers];
    if (layers.length) [s appendFormat:@", %@", layers];
    NSString *what = [self activity];
    if (what.length) [s appendFormat:@", busy: %@", what];
    return s;
}

+ (void)watchLayer:(CALayer *)layer
{
    g_watchedLayer = layer;
}

+ (NSString *)layerNumbers
{
    if (!g_watchedLayer) return nil;
    NSMutableArray *big = [NSMutableArray array];
    BRLayerTally t = [self layerTally:big];
    [big sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableString *s = [NSMutableString stringWithFormat:@"%ld layers (%ld drawn, %ld tiled) %.0f MB", t.layers, t.drawn, t.tiled, t.bytes / 1048576.0];
    if (big.count) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSUInteger i = 0; i < big.count && i < 4; i++) [names addObject:big[i][1]];
        [s appendFormat:@" (%lu over 2 MB: %@)", (unsigned long)big.count, [names componentsJoinedByString:@", "]];
    }
    return s;
}

+ (NSString *)webKitReport
{
    BRWebLock();
    return [self webKitNumbers];
}

+ (void)relieve:(NSString *)reason
{
    long before = (long)BRResidentMemoryMB();
    // our two script engines: whole heaps, recreated on the next use (0.3 to 0.5 s each)
    [[BRJSEngine transpiler] resetContext];
    [[BRJSEngine shared] resetContext];
    // the pages' garbage, the resources no page uses and the decoded copies of images (redecoded when painted; the
    // iOS variant keeps the application caches that +empty would delete), then WebKit's free lists back to the system
    void (^webkit)(void) = ^{
        NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
        BRCallClassVoid(@"WebCoreStatistics", @"garbageCollectJavaScriptObjects");
        BRCallClassVoid(@"WebCache", @"emptyInMemoryResources");
        BRCallClassVoid(@"WebCoreStatistics", @"returnFreeMemoryToSystem");
        BRLog(@"Memory relief (%@): %ld -> %ld MB, %ld MB available, WebKit part %ld ms; %@", reason, before, (long)BRResidentMemoryMB(),
              [BRMemory availableMB], (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000), [BRMemory webKitNumbers]);
    };
    BRWebThreadRunFn run = BRWebThreadRun();
    if (run) run(webkit);
    else if ([NSThread isMainThread]) { BRWebLock(); webkit(); }
    else dispatch_async(dispatch_get_main_queue(), ^{ BRWebLock(); webkit(); });
}

@end
