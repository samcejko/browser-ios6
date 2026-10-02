#import "BRTabsViewController.h"
#import "BRSettings.h"
#import "BRTheme.h"
#import "BRCommon.h"

@implementation BRTabsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = L(@"Tabs");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 72;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    UIBarButtonItem *newTab = [[UIBarButtonItem alloc] initWithTitle:L(@"New tab") style:UIBarButtonItemStyleBordered target:self action:@selector(newTab)];
    UIBarButtonItem *closeAll = [[UIBarButtonItem alloc] initWithTitle:L(@"Close all") style:UIBarButtonItemStyleBordered target:self action:@selector(closeAll)];
    self.navigationItem.rightBarButtonItems = self.tabs.count > 1 ? @[newTab, closeAll] : @[newTab];
    [[BRTheme shared] applyToTableView:self.tableView];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)newTab
{
    [self dismissViewControllerAnimated:YES completion:nil];
    [self.delegate tabsViewControllerDidRequestNewTab:self];
}

- (void)closeAll
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:(id<UIActionSheetDelegate>)self cancelButtonTitle:L(@"Cancel")
                                         destructiveButtonTitle:[NSString stringWithFormat:L(@"Close all %lu tabs"), (unsigned long)self.tabs.count] otherButtonTitles:nil];
    [sheet showFromBarButtonItem:self.navigationItem.rightBarButtonItems.lastObject animated:YES];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex != actionSheet.destructiveButtonIndex) return;
    [self dismissViewControllerAnimated:YES completion:nil];
    [self.delegate tabsViewControllerDidCloseAllTabs:self];
}

// (the newest closed tab first)
- (NSDictionary *)closedTabAtRow:(NSInteger)row
{
    NSUInteger n = self.closedTabs.count;
    return (NSUInteger)row < n ? self.closedTabs[n - 1 - (NSUInteger)row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return self.closedTabs.count ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 1 ? L(@"Recently closed") : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 1 ? (NSInteger)self.closedTabs.count : (NSInteger)self.tabs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"tab";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    BOOL closed = indexPath.section == 1;
    NSDictionary *tab = closed ? [self closedTabAtRow:indexPath.row] : self.tabs[(NSUInteger)indexPath.row];
    NSString *url = tab[@"url"] ?: @"";
    BOOL home = [BRSettings isHomeURL:[NSURL URLWithString:url]] || !url.length;
    cell.textLabel.text = home ? L(@"Home") : ([tab[@"title"] length] ? tab[@"title"] : url);
    cell.textLabel.font = closed ? [UIFont systemFontOfSize:15] : [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.text = home ? @"" : url;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    UIImage *snapshot = closed ? nil : tab[@"snapshot"];
    cell.imageView.image = snapshot;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    cell.imageView.clipsToBounds = YES;
    cell.accessoryType = !closed && (NSUInteger)indexPath.row == self.currentIndex ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    [[BRTheme shared] styleCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self dismissViewControllerAnimated:YES completion:nil];
    if (indexPath.section == 1) {
        NSUInteger n = self.closedTabs.count;
        if ((NSUInteger)indexPath.row < n) [self.delegate tabsViewController:self didReopenClosedTabAtIndex:n - 1 - (NSUInteger)indexPath.row];
        return;
    }
    [self.delegate tabsViewController:self didSelectTabAtIndex:(NSUInteger)indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return L(@"Close");
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 0) return;
    NSUInteger index = (NSUInteger)indexPath.row;
    [self.delegate tabsViewController:self didCloseTabAtIndex:index];
    if (!self.tabs.count) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [tableView reloadData];
}

@end
