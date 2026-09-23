#import <Foundation/Foundation.h>

// Babel (standalone) inside our JavaScriptCore context: turns modern JavaScript into ES5 so the
// iOS 6 engine can run it. Scripts that already parse as ES5 are left untouched (checked with the
// engine's own parser), results are cached on disk by content hash.
@interface BRJSTranspiler : NSObject

+ (instancetype)shared;
+ (void)warmUp;                                   // loads Babel in the background

@property (nonatomic, readonly) BOOL available;   // Babel loaded and working

// Returns the ES5 source for `source`, or nil when the script is already ES5 / cannot be transpiled.
// Must be called on the engine queue (BRJSEngine performSync/performAsync).
- (NSString *)transpileIfNeeded:(NSString *)source name:(NSString *)name changed:(BOOL *)changed;

// Self test used for logging on startup: transpiles a small ES2020 snippet and reports the time.
- (void)selfTest;

@end
