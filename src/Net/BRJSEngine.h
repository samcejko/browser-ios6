#import <Foundation/Foundation.h>

// Posted on the engine thread after the context was thrown away (memory pressure); libraries must reload.
extern NSString * const BRJSEngineDidResetNotification;

// A JavaScriptCore context on a dedicated thread with a large stack (Babel recurses deeply), reached
// through the C API which is looked up with dlsym (JavaScriptCore is a private framework on iOS 6 but
// already loaded by UIKit/WebKit). Used for the CSS rewriter and the JavaScript transpiler.
@interface BRJSEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL available;

// Runs `block` on the engine thread (serially).
- (void)performSync:(dispatch_block_t)block;
- (void)performAsync:(dispatch_block_t)block;

// The following must be called on the engine thread (inside performSync/performAsync).
- (BOOL)evaluateScript:(NSString *)script sourceName:(NSString *)name;
// Calls a global function or dotted path (e.g. "CSSFix.run") with string arguments; returns the result as a string.
- (NSString *)callFunction:(NSString *)function arguments:(NSArray *)arguments;
- (void)collectGarbage;

// Throws the whole context away (frees Babel etc.); it is recreated on the next use.
- (void)resetContext;

@end
