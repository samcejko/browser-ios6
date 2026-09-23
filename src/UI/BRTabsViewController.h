#import <UIKit/UIKit.h>

@class BRTabsViewController;

@protocol BRTabsViewControllerDelegate <NSObject>
- (void)tabsViewController:(BRTabsViewController *)controller didSelectTabAtIndex:(NSUInteger)index;
- (void)tabsViewController:(BRTabsViewController *)controller didCloseTabAtIndex:(NSUInteger)index;
- (void)tabsViewControllerDidRequestNewTab:(BRTabsViewController *)controller;
@end

// List of open tabs (dictionaries with "url", "title" and optionally "snapshot" UIImage).
@interface BRTabsViewController : UITableViewController

@property (nonatomic, weak) id<BRTabsViewControllerDelegate> delegate;
@property (nonatomic, strong) NSMutableArray *tabs;
@property (nonatomic) NSUInteger currentIndex;

@end
