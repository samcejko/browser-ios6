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
          mainFrame:(BOOL)mainFrame completion:(BRRewriteCompletion)completion;   // polyfills are injected into main documents only

// The bundle of polyfills injected into every document (assembled once from Resources/js and shims.js).
+ (NSString *)polyfillURLString;
+ (NSData *)polyfillBundle;

// The rewriter turns :has() selectors and @container queries into classes and appends the entries to the output as a
// trailing comment; every rewritten (or cached) stylesheet/document served for a page registers them here, and the
// page shim fetches https://ios6-browser.invalid/manifest?doc=<page> to evaluate them. Thread safe.
- (void)registerManifestInData:(NSData *)data pageURL:(NSURL *)pageURL;
- (NSData *)manifestJSONForPageURLString:(NSString *)pageURLString;

@end
