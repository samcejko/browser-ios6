#import <UIKit/UIKit.h>

extern NSString * const BRThemeDidChangeNotification;

// Colors and code-drawn glossy iOS 6 style artwork for the browser bars (same visual language as the
// AI chat app: light and dark variants, gradient bars, rounded glossy buttons, drawn icons).
@interface BRTheme : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isDark;
- (void)setDark:(BOOL)dark;         // persists and posts BRThemeDidChangeNotification

// Colors
- (UIColor *)barTextColor;
- (UIColor *)barTextShadowColor;
- (UIColor *)fieldTextColor;
- (UIColor *)placeholderColor;
- (UIColor *)pageBackgroundColor;
- (UIStatusBarStyle)statusBarStyle;
- (UIBarStyle)barStyle;

// Artwork (stretchable where it makes sense)
- (UIImage *)barBackgroundImage;
- (UIImage *)fieldBackgroundImage;
- (UIImage *)buttonImageHighlighted:(BOOL)highlighted;
- (UIImage *)arrowImagePointingLeft:(BOOL)left enabled:(BOOL)enabled;
- (UIImage *)reloadImage;
- (UIImage *)stopImage;
- (UIImage *)bookmarksImage;                  // open book, like Safari
- (UIImage *)plusImage;
- (UIImage *)closeTabImage;
- (UIImage *)tabBarBackgroundImage;
- (UIImage *)tabImageSelected:(BOOL)selected; // stretchable tab shape
- (UIColor *)tabTextColorSelected:(BOOL)selected;

// Applying to UIKit
- (void)applyToNavigationBar:(UINavigationBar *)bar;
- (void)applyToTableView:(UITableView *)tableView;
- (void)styleCell:(UITableViewCell *)cell;

@end
