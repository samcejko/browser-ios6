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
// Scripts ("js"): ES2015+ syntax lowered to ES5 by Resources/jsfix.js (on acorn) when the engine cannot parse the
// script as it is; results are kept in Caches/transpiled by content. `sourceURL` is the script's own URL.
- (void)rewriteData:(NSData *)data kind:(NSString *)kind charset:(NSString *)charset pageURL:(NSURL *)pageURL
          sourceURL:(NSURL *)sourceURL mainFrame:(BOOL)mainFrame completion:(BRRewriteCompletion)completion;
+ (void)pruneTranspiledCache;   // keeps Caches/transpiled under its size limit (call off the main thread)

// The bundle of polyfills injected into every document (assembled once from Resources/js and shims.js).
+ (NSString *)polyfillURLString;
+ (NSData *)polyfillBundle;
// What a worker scope gets (core-js, regenerator, fetch, worker-shims.js; nothing that needs a document), see the
// Worker shim.
+ (NSData *)workerPolyfills;

// The rewriter turns :has() selectors and @container queries into classes, and records deferred values, position-try
// rules and custom properties that differ per element; the entries go to the output as a trailing comment. Every
// rewritten (or cached) stylesheet/document served for a page registers them here (`sourceURL` is the stylesheet's
// own URL, for the order of the custom property rules), and the page shim fetches
// https://ios6-browser.invalid/manifest?doc=<page> to evaluate them. Thread safe.
- (void)registerManifestInData:(NSData *)data pageURL:(NSURL *)pageURL sourceURL:(NSURL *)sourceURL;
- (NSData *)manifestJSONForPageURLString:(NSString *)pageURLString;

@end
