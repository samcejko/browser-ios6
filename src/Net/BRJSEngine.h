#import <Foundation/Foundation.h>

// A JavaScriptCore context on a private serial queue, reached through the C API which is looked up
// with dlsym (JavaScriptCore is a private framework on iOS 6 but already loaded by UIKit/WebKit).
// Used for the CSS rewriter now and for the JavaScript transpiler later.
@interface BRJSEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL available;

// Runs `block` on the engine queue (serially), synchronously.
- (void)performSync:(dispatch_block_t)block;
- (void)performAsync:(dispatch_block_t)block;

// The following must be called from the engine queue (inside performSync/performAsync).
- (BOOL)evaluateScript:(NSString *)script sourceName:(NSString *)name;
// Calls a global function or dotted path (e.g. "CSSFix.run") with string arguments; returns the result as a string.
- (NSString *)callFunction:(NSString *)function arguments:(NSArray *)arguments;
- (void)collectGarbage;

@end
