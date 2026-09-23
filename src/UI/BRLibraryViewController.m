#import "BRLibraryViewController.h"
#import "BRLibrary.h"
#import "BRCommon.h"

@interface BRLibraryViewController ()
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UIBarButtonItem *addItem;
@property (nonatomic, strong) UIBarButtonItem *clearItem;
@property (nonatomic, strong) NSArray *items;
@end

@implementation BRLibraryViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStylePlain];
}

- (BOOL)showingHistory
{
    return self.segment.selectedSegmentIndex == 1;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.segment = [[UISegmentedControl alloc] initWithItems:@[L(@"Bookmarks"), L(@"History")]];
    self.segment.segmentedControlStyle = UISegmentedControlStyleBar;
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.segment;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addCurrent)];
    self.clearItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Clear") style:UIBarButtonItemStylePlain target:self action:@selector(clearHistory)];
    [self reload];
}

- (void)reload
{
    BRLibrary *lib = [BRLibrary shared];
    self.items = [self showingHistory] ? lib.history : lib.bookmarks;
    self.navigationItem.rightBarButtonItem = [self showingHistory] ? self.clearItem : self.addItem;
    self.addItem.enabled = self.currentURL != nil && ![lib isBookmarked:self.currentURL];
    [self.tableView reloadData];
}

- (void)segmentChanged
{
    [self reload];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addCurrent
{
    if (!self.currentURL) return;
    [[BRLibrary shared] addBookmark:self.currentURL title:self.currentTitle];
    [self reload];
}

- (void)clearHistory
{
    [[BRLibrary shared] clearHistory];
    [self reload];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"entry";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    NSDictionary *e = self.items[(NSUInteger)indexPath.row];
    cell.textLabel.text = e[@"title"] ?: e[@"url"];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    NSString *detail = e[@"url"];
    if ([self showingHistory] && e[@"time"]) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[e[@"time"] doubleValue]];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateStyle = NSDateFormatterShortStyle;
        f.timeStyle = NSDateFormatterShortStyle;
        detail = [NSString stringWithFormat:@"%@  %@", [f stringFromDate:d], e[@"url"]];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *e = self.items[(NSUInteger)indexPath.row];
    NSURL *url = [NSURL URLWithString:e[@"url"] ?: @""];
    [self dismissViewControllerAnimated:YES completion:nil];
    if (url) [self.delegate libraryViewController:self didSelectURL:url];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if ([self showingHistory]) [[BRLibrary shared] removeHistoryAtIndex:(NSUInteger)indexPath.row];
    else [[BRLibrary shared] removeBookmarkAtIndex:(NSUInteger)indexPath.row];
    self.items = [self showingHistory] ? [BRLibrary shared].history : [BRLibrary shared].bookmarks;
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    self.addItem.enabled = self.currentURL != nil && ![[BRLibrary shared] isBookmarked:self.currentURL];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return ![self showingHistory];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    [[BRLibrary shared] moveBookmarkFromIndex:(NSUInteger)from.row toIndex:(NSUInteger)to.row];
    self.items = [BRLibrary shared].bookmarks;
}

@end
