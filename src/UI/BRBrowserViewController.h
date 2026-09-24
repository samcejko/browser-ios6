#import <UIKit/UIKit.h>

// The whole browser UI: address bar, navigation buttons and the UIWebView.
@interface BRBrowserViewController : UIViewController

- (void)loadURL:(NSURL *)url;
@property (nonatomic) BOOL skipRestore;   // set before the view loads when the app was launched with a URL to open
- (void)goHome;
- (void)navigateToTypedText:(NSString *)text;        // what the address bar does with typed text
- (NSString *)evaluateJavaScript:(NSString *)code;   // in the current page (debugging over SSH)
- (void)showReader;                                  // article view of the current page
- (void)savePageAsPDF;                               // into Documents/Downloads
- (void)showSource;                                  // the page's HTML in a monospaced view
- (void)translateCurrentPage;                        // through Google Translate's website proxy
- (void)applyTheme;
// debugging over SSH: the WebKit history behind the back/forward buttons, and the pending login dialog
- (NSString *)historyDescription;
- (void)goToHistoryItemAtIndex:(NSInteger)index;
- (void)answerAuthenticationWithUser:(NSString *)user password:(NSString *)password;

@end
