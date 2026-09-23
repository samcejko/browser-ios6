#import <UIKit/UIKit.h>

@class BRTabBar;

@protocol BRTabBarDelegate <NSObject>
- (void)tabBar:(BRTabBar *)bar didSelectTabAtIndex:(NSUInteger)index;
- (void)tabBar:(BRTabBar *)bar didCloseTabAtIndex:(NSUInteger)index;
- (void)tabBarDidRequestNewTab:(BRTabBar *)bar;
@end

// Safari (iPad, iOS 6) style tab strip under the address bar: drawn tabs, a close mark on the
// active tab and a plus button at the right end. Scrolls horizontally when tabs do not fit.
@interface BRTabBar : UIView

@property (nonatomic, weak) id<BRTabBarDelegate> delegate;

- (void)setTitles:(NSArray *)titles selectedIndex:(NSUInteger)index;
- (void)applyTheme;

@end
