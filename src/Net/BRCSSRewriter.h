#import <Foundation/Foundation.h>

typedef void (^BRRewriteCompletion)(NSData *output, NSString *charset);

// Runs Resources/cssfix.js over stylesheets and HTML documents so that modern CSS renders on the
// iOS 6 WebKit. Keeps the :root custom properties seen per page so that stylesheets can use variables
// defined in other files of the same page.
@interface BRCSSRewriter : NSObject

+ (instancetype)shared;
+ (void)warmUp;

@property (nonatomic, readonly) BOOL available;

// kind: "css", "html" or "js". `charset` is the declared charset (may be nil). The completion runs on the
// rewriter's queue; `output` is UTF-8 encoded and `charset` is "utf-8". On failure the original data is passed back
// with the original charset.
- (void)rewriteData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL
         completion:(BRRewriteCompletion)completion;

// The bundle of polyfills injected into every document (assembled once from Resources/js and shims.js).
+ (NSString *)polyfillURLString;
+ (NSData *)polyfillBundle;

@end
