#import <Foundation/Foundation.h>

// Memory diagnostics and early relief. The 512 MB iPad 2 kills the app at about 330 MB resident, and iOS warns
// only a few megabytes before that, so heavy pages die before the warning handler can free anything.
@interface BRMemory : NSObject

// What a background engine is busy with, reported next to memory jumps (any thread; nil when done). One slot per
// key, since the rewriter and the transpiler work at the same time.
+ (void)setActivity:(NSString *)activity forKey:(NSString *)key;
+ (NSString *)activity;

// Called by the watchdog thread every few seconds: logs jumps, tracks the peak of the current page and asks the
// main thread for relief when the process crosses the early threshold (setting BRMemoryReliefMB, 0 = off).
+ (void)sample;
+ (void)resetPeak;
+ (long)peakMB;

// Main thread: WebKit's own numbers (JavaScript heap of the pages, FastMalloc, memory cache).
+ (NSString *)webKitReport;

// Main thread: frees what can be freed without losing the page (both script engines, page garbage, WebKit's
// memory cache and free lists) and logs what it gained.
+ (void)relieve:(NSString *)reason;

@end
