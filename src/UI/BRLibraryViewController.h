#import <UIKit/UIKit.h>

@class BRLibraryViewController;

@protocol BRLibraryViewControllerDelegate <NSObject>
- (void)libraryViewController:(BRLibraryViewController *)controller didSelectURL:(NSURL *)url;
@optional
- (void)libraryViewController:(BRLibraryViewController *)controller didSelectDownloadAtPath:(NSString *)path;
@end

// Bookmarks and history in one table with a segmented control on top.
@interface BRLibraryViewController : UITableViewController

@property (nonatomic, weak) id<BRLibraryViewControllerDelegate> delegate;
@property (nonatomic, strong) NSURL *currentURL;          // offered by the "+" button
@property (nonatomic, copy) NSString *currentTitle;

@end
