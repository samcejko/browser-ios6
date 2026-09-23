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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"New tab") style:UIBarButtonItemStyleBordered target:self action:@selector(newTab)];
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.tabs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"tab";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    NSDictionary *tab = self.tabs[(NSUInteger)indexPath.row];
    NSString *url = tab[@"url"] ?: @"";
    BOOL home = [BRSettings isHomeURL:[NSURL URLWithString:url]] || !url.length;
    cell.textLabel.text = home ? L(@"Home") : ([tab[@"title"] length] ? tab[@"title"] : url);
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.text = home ? @"" : url;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    UIImage *snapshot = tab[@"snapshot"];
    cell.imageView.image = snapshot;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    cell.imageView.clipsToBounds = YES;
    cell.accessoryType = (NSUInteger)indexPath.row == self.currentIndex ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    [[BRTheme shared] styleCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self dismissViewControllerAnimated:YES completion:nil];
    [self.delegate tabsViewController:self didSelectTabAtIndex:(NSUInteger)indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return L(@"Close");
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSUInteger index = (NSUInteger)indexPath.row;
    [self.delegate tabsViewController:self didCloseTabAtIndex:index];
    if (!self.tabs.count) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    [tableView reloadData];
}

@end
