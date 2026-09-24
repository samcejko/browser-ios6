#import "BRLibraryViewController.h"
#import "BRLibrary.h"
#import "BRDownloader.h"
#import "BRTheme.h"
#import "BRCommon.h"

@interface BRLibraryViewController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UIBarButtonItem *addItem;
@property (nonatomic, strong) UIBarButtonItem *clearItem;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic) NSInteger editedRow;              // bookmark behind the rename / edit address dialog
@end

@implementation BRLibraryViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged) name:BRDownloadsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)showingHistory
{
    return self.segment.selectedSegmentIndex == 1;
}

- (BOOL)showingDownloads
{
    return self.segment.selectedSegmentIndex == 2;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.segment = [[UISegmentedControl alloc] initWithItems:@[L(@"Bookmarks"), L(@"History"), L(@"Downloads")]];
    self.segment.segmentedControlStyle = UISegmentedControlStyleBar;
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.segment;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addCurrent)];
    self.clearItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Clear") style:UIBarButtonItemStylePlain target:self action:@selector(clearHistory)];
    [[BRTheme shared] applyToTableView:self.tableView];
    self.tableView.allowsSelectionDuringEditing = YES;   // tapping a bookmark while editing renames it
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rowPressed:)];
    press.minimumPressDuration = 0.5;
    [self.tableView addGestureRecognizer:press];
    self.editedRow = -1;
    [self reload];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    [self reload];
}

- (void)downloadsChanged
{
    if ([self showingDownloads]) [self reload];
}

- (void)reload
{
    BRLibrary *lib = [BRLibrary shared];
    if ([self showingDownloads]) {
        self.items = [BRDownloader downloadedFiles];
        self.navigationItem.rightBarButtonItem = nil;
    } else {
        self.items = [self showingHistory] ? lib.history : lib.bookmarks;
        if ([self showingHistory]) self.navigationItem.rightBarButtonItems = @[self.clearItem];
        else self.navigationItem.rightBarButtonItems = @[self.addItem, self.editButtonItem];   // edit: reorder, delete, rename
    }
    self.addItem.enabled = self.currentURL != nil && ![lib isBookmarked:self.currentURL];
    [self.tableView reloadData];
}

#pragma mark - Editing bookmarks

- (void)rowPressed:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan || [self showingHistory] || [self showingDownloads]) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[recognizer locationInView:self.tableView]];
    if (!path) return;
    [self showEditMenuForRow:path.row];
}

- (void)showEditMenuForRow:(NSInteger)row
{
    if (row < 0 || (NSUInteger)row >= self.items.count) return;
    self.editedRow = row;
    NSDictionary *e = self.items[(NSUInteger)row];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:e[@"title"] ?: e[@"url"] delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Rename")];
    [sheet addButtonWithTitle:L(@"Edit address")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    CGRect rect = [self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    if (BRIsPad()) [sheet showFromRect:rect inView:self.tableView animated:YES];
    else [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex || self.editedRow < 0 || (NSUInteger)self.editedRow >= self.items.count) return;
    NSDictionary *e = self.items[(NSUInteger)self.editedRow];
    BOOL address = [[actionSheet buttonTitleAtIndex:buttonIndex] isEqualToString:L(@"Edit address")];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:address ? L(@"Edit address") : L(@"Rename") message:nil delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Save"), nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [alert textFieldAtIndex:0];
    field.text = address ? e[@"url"] : e[@"title"];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = address ? UITextAutocapitalizationTypeNone : UITextAutocapitalizationTypeSentences;
    field.keyboardType = address ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
    alert.tag = address ? 2 : 1;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex || self.editedRow < 0) return;
    NSString *text = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;
    if (alertView.tag == 2) {
        if ([text rangeOfString:@"://"].location == NSNotFound && ![[text lowercaseString] hasPrefix:@"javascript:"]) text = [@"https://" stringByAppendingString:text];
        [[BRLibrary shared] updateBookmarkAtIndex:(NSUInteger)self.editedRow title:nil url:text];
    } else {
        [[BRLibrary shared] updateBookmarkAtIndex:(NSUInteger)self.editedRow title:text url:nil];
    }
    self.editedRow = -1;
    [self reload];
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
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    if ([self showingDownloads]) {
        cell.textLabel.text = e[@"name"];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateStyle = NSDateFormatterShortStyle;
        df.timeStyle = NSDateFormatterShortStyle;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", [BRDownloader formattedSize:[e[@"size"] longLongValue]], [df stringFromDate:e[@"date"]]];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        [[BRTheme shared] styleCell:cell];
        return cell;
    }
    cell.textLabel.text = e[@"title"] ?: e[@"url"];
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
    [[BRTheme shared] styleCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *e = self.items[(NSUInteger)indexPath.row];
    if ([self showingDownloads]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        NSString *path = e[@"path"];
        [self dismissViewControllerAnimated:YES completion:^{
            if (path && [self.delegate respondsToSelector:@selector(libraryViewController:didSelectDownloadAtPath:)]) [self.delegate libraryViewController:self didSelectDownloadAtPath:path];
        }];
        return;
    }
    if (self.editing && ![self showingHistory]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self showEditMenuForRow:indexPath.row];
        return;
    }
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
    if ([self showingDownloads]) {
        NSDictionary *e = self.items[(NSUInteger)indexPath.row];
        [[NSFileManager defaultManager] removeItemAtPath:e[@"path"] error:NULL];
        self.items = [BRDownloader downloadedFiles];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        return;
    }
    if ([self showingHistory]) [[BRLibrary shared] removeHistoryAtIndex:(NSUInteger)indexPath.row];
    else [[BRLibrary shared] removeBookmarkAtIndex:(NSUInteger)indexPath.row];
    self.items = [self showingHistory] ? [BRLibrary shared].history : [BRLibrary shared].bookmarks;
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    self.addItem.enabled = self.currentURL != nil && ![[BRLibrary shared] isBookmarked:self.currentURL];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return ![self showingHistory] && ![self showingDownloads];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    [[BRLibrary shared] moveBookmarkFromIndex:(NSUInteger)from.row toIndex:(NSUInteger)to.row];
    self.items = [BRLibrary shared].bookmarks;
}

@end
