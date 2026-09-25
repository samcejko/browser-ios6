#import <Foundation/Foundation.h>

@class BRJSEngine;

// How much memory the whole iPad has left (iOS kills the frontmost app when the system runs short, whatever the app
// itself uses: other processes and the graphics memory of big pages count too).
typedef NS_ENUM(NSInteger, BRMemoryLevel) {
    BRMemoryLevelNormal = 0,
    BRMemoryLevelTight,        // heavy work waits for relief first
    BRMemoryLevelCritical,     // everything that can be freed is freed
    BRMemoryLevelEmergency,    // the page load is stopped (BRMemoryEmergencyNotification) so that the app survives
};
extern NSString * const BRMemoryEmergencyNotification;   // posted on the main thread while a page loads

// Memory diagnostics and early relief. The 512 MB iPad 2 kills the app at about 330 MB resident, and iOS warns
// only a few megabytes before that, so heavy pages die before the warning handler can free anything.
@interface BRMemory : NSObject

// What a background engine is busy with, reported next to memory jumps (any thread; nil when done). One slot per
// key, since the rewriter and the transpiler work at the same time.
+ (void)setActivity:(NSString *)activity forKey:(NSString *)key;
+ (NSString *)activity;

// Starts the sampler thread (every 2 s, every 0.5 s while a page loads or memory is short): logs jumps, tracks the
// peak of the current page, asks the main thread for relief when the process crosses BRMemoryReliefMB (0 = off) or
// the system runs short, and posts BRMemoryEmergencyNotification as the last resort.
+ (void)start;
+ (void)resetPeak;
+ (long)peakMB;

// Main thread: WebKit's own numbers (JavaScript heap of the pages, FastMalloc, memory cache).
+ (NSString *)webKitReport;

// Frees what can be freed without losing the page (both script engines, page garbage, WebKit's memory cache and free
// lists) and logs what it gained. Any thread: the work happens on the engines' threads and the WebThread.
+ (void)relieve:(NSString *)reason;

// Free + inactive + purgeable memory of the whole system (any thread), and the level it means.
+ (long)availableMB;
+ (BRMemoryLevel)level;
// Background threads: heavy work asks for room first. Returns at once when `needMB` are available; otherwise frees
// what it can (the calling engine's heap at once, the rest through relief) and waits up to `timeout` seconds for the
// system to catch up (the page loads slower instead of the app being killed). YES when the room is there.
+ (BOOL)waitForAvailableMB:(long)needMB timeout:(NSTimeInterval)timeout reason:(NSString *)reason engine:(BRJSEngine *)engine;
// The watchdog tells whether a page is loading (the emergency stop only applies then).
+ (void)setPageLoading:(BOOL)loading;

@end
