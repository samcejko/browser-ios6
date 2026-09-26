#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// keep: NO when the output is only a stand-in for this time (the original of a script left unlowered for lack of
// memory, or of a text the rewriter could not take): it must not be cached, a later visit rewrites it
typedef void (^BRRewriteCompletion)(NSData *output, NSString *charset, BOOL keep);

// Runs Resources/cssfix.js over stylesheets and HTML documents so that modern CSS renders on the
// iOS 6 WebKit. Keeps the :root custom properties seen per page so that stylesheets can use variables
// defined in other files of the same page.
@interface BRCSSRewriter : NSObject

+ (instancetype)shared;
+ (void)warmUp;
// The web view's size and orientation (main thread, on every layout): viewport units in pages become pixels of it.
+ (void)noteWebViewSize:(CGSize)size landscape:(BOOL)landscape;

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
// Checksum of the rewriters (cssfix.js, jsfix.js): stored rewritten bodies of another version are not used. Any thread.
+ (NSString *)rewriteTag;
// Work queued so far is dropped (the originals go back): the page load was stopped for lack of memory. Any thread.
+ (void)cancelPendingWork;
// Debugging (browser:jsfixtest): lowers the file params[@"input"] on a fresh transpiler context (jsfix.js from
// params[@"jsfix"] when given, options params[@"opts"]), sampling the resident size every 50 ms; logs time, sizes,
// the peak and what stays after GC and after the context is gone, and writes the report to tmp/eval.txt.
+ (void)runTranspileTest:(NSDictionary *)params;

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
// Only what the page lacks: since = "has:<n>,cq:<n>,dv:<n>,pt:<n>,cv:<n>,sc:<n>,vars:<n>,sheets:<n>" (counts it has).
- (NSData *)manifestJSONForPageURLString:(NSString *)pageURLString since:(NSString *)since;
// A factory of a webpack chunk the transpiler kept for later (jsfix.js LAZY_*), asked for by the page's stub: lowered
// now as a program that leaves it in __br_lazyValue (nil when its text is gone). Blocks; any thread but the
// transpiler engine's.
- (NSData *)lazyModuleForBase:(NSString *)base index:(NSInteger)index;
// NO when a lowered chunk keeps factories for later whose texts are gone (it must be lowered again); any thread
+ (BOOL)lazyPartsPresentIn:(NSData *)lowered;
// The same data without the trailing manifest comment: what WebKit gets (the cache keeps it; GitHub's manifests are
// 2.3 MB that the engine would otherwise keep and parse as stylesheet text).
+ (NSData *)dataWithoutManifest:(NSData *)data;

@end
