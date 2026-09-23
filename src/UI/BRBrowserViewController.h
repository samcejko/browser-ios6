#import <UIKit/UIKit.h>

// The whole browser UI: address bar, navigation buttons and the UIWebView.
@interface BRBrowserViewController : UIViewController

- (void)loadURL:(NSURL *)url;

@end
