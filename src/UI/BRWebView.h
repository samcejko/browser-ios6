#import <UIKit/UIKit.h>

// UIWebView with extra entries in the text selection menu ("Search", "Share"). The menu items themselves
// are registered once with +registerMenuItems; the blocks receive the selected text.
@interface BRWebView : UIWebView

@property (nonatomic, copy) void (^onSearchSelection)(NSString *text);
@property (nonatomic, copy) void (^onShareSelection)(NSString *text);
@property (nonatomic, copy) void (^onOpenSelection)(NSString *text);     // the selection looks like an address

+ (void)registerMenuItems;
- (NSString *)selectedText;

@end
