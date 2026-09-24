#import <UIKit/UIKit.h>

// The whole browser UI: address bar, navigation buttons and the UIWebView.
@interface BRBrowserViewController : UIViewController

- (void)loadURL:(NSURL *)url;
@property (nonatomic) BOOL skipRestore;   // set before the view loads when the app was launched with a URL to open
- (void)goHome;
- (NSString *)evaluateJavaScript:(NSString *)code;   // in the current page (debugging over SSH)
- (void)showReader;                                  // article view of the current page
- (void)applyTheme;

@end
