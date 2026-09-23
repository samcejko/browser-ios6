#import <Foundation/Foundation.h>

// Logs a backtrace of the main thread whenever it stops servicing its run loop for several
// seconds (pages that freeze the engine are otherwise impossible to diagnose without a debugger).
@interface BRWatchdog : NSObject

+ (void)start;

@end
