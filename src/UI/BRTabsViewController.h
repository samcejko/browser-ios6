#import <UIKit/UIKit.h>

@class BRTabsViewController;

@protocol BRTabsViewControllerDelegate <NSObject>
- (void)tabsViewController:(BRTabsViewController *)controller didSelectTabAtIndex:(NSUInteger)index;
- (void)tabsViewController:(BRTabsViewController *)controller didCloseTabAtIndex:(NSUInteger)index;
- (void)tabsViewControllerDidRequestNewTab:(BRTabsViewController *)controller;
- (void)tabsViewController:(BRTabsViewController *)controller didReopenClosedTabAtIndex:(NSUInteger)index;   // index into closedTabs
- (void)tabsViewControllerDidCloseAllTabs:(BRTabsViewController *)controller;
@end

// List of open tabs (dictionaries with "url", "title" and optionally "snapshot" UIImage), and below them the tabs closed
// lately (dictionaries with "url" and "title", oldest first), which can be opened again.
@interface BRTabsViewController : UITableViewController

@property (nonatomic, weak) id<BRTabsViewControllerDelegate> delegate;
@property (nonatomic, strong) NSMutableArray *tabs;
@property (nonatomic, strong) NSArray *closedTabs;
@property (nonatomic) NSUInteger currentIndex;

@end
