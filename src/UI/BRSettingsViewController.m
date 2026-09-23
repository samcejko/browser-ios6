#import "BRSettingsViewController.h"
#import "BRSettings.h"
#import "BRTheme.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRJSEngine.h"
#import "BRCommon.h"

typedef NS_ENUM(NSInteger, BRSettingsSection) {
    BRSettingsSectionAppearance = 0,
    BRSettingsSectionFeatures,
    BRSettingsSectionData,
    BRSettingsSectionInfo,
    BRSettingsSectionCount
};

typedef NS_ENUM(NSInteger, BRFeatureRow) {
    BRFeatureRowUserAgent = 0,
    BRFeatureRowSearchEngine,
    BRFeatureRowTextSize,
    BRFeatureRowAdBlock,
    BRFeatureRowCSSFix,
    BRFeatureRowJSFix,
    BRFeatureRowVerifyTLS,
    BRFeatureRowCount
};

static const NSInteger BRTagDarkTheme = 100;

@interface BRSettingsViewController () <UIActionSheetDelegate>
@end

@implementation BRSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.title = L(@"Settings");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [[BRTheme shared] applyToTableView:self.tableView];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return BRSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case BRSettingsSectionAppearance: return 1;
        case BRSettingsSectionFeatures: return BRFeatureRowCount;
        case BRSettingsSectionData: return 2;
        case BRSettingsSectionInfo: return 4;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case BRSettingsSectionAppearance: return L(@"Appearance");
        case BRSettingsSectionFeatures: return L(@"Pages");
        case BRSettingsSectionData: return L(@"Data");
        case BRSettingsSectionInfo: return L(@"About");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == BRSettingsSectionFeatures) {
        return L(@"The page version tells servers which browser to serve. iPad with iOS 6 gets pages this engine understands best; the modern identity gets current pages that may not work.");
    }
    return nil;
}

- (UISwitch *)switchWithValue:(BOOL)on tag:(NSInteger)tag
{
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [[BRTheme shared] styleCell:cell];
    if (![BRTheme shared].isDark) cell.textLabel.textColor = [UIColor blackColor];

    if (indexPath.section == BRSettingsSectionAppearance) {
        cell.textLabel.text = L(@"Dark theme");
        cell.accessoryView = [self switchWithValue:[BRSettings darkTheme] tag:BRTagDarkTheme];
    } else if (indexPath.section == BRSettingsSectionFeatures) {
        switch (indexPath.row) {
            case BRFeatureRowUserAgent:
                cell.textLabel.text = L(@"Page version");
                cell.detailTextLabel.text = [BRSettings userAgentModeTitle:[BRSettings userAgentMode]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                break;
            case BRFeatureRowSearchEngine:
                cell.textLabel.text = L(@"Search engine");
                cell.detailTextLabel.text = [BRSettings searchEngineTitle:[BRSettings searchEngine]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                break;
            case BRFeatureRowTextSize:
                cell.textLabel.text = L(@"Text size");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld %%", (long)[BRSettings textSizePercent]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
                break;
            case BRFeatureRowAdBlock:
                cell.textLabel.text = L(@"Block ads and trackers");
                cell.accessoryView = [self switchWithValue:[BRSettings adBlockEnabled] tag:BRFeatureRowAdBlock];
                break;
            case BRFeatureRowCSSFix:
                cell.textLabel.text = L(@"Rewrite modern CSS");
                cell.accessoryView = [self switchWithValue:[BRSettings cssFixEnabled] tag:BRFeatureRowCSSFix];
                break;
            case BRFeatureRowJSFix:
                cell.textLabel.text = L(@"JavaScript polyfills");
                cell.accessoryView = [self switchWithValue:[BRSettings jsFixEnabled] tag:BRFeatureRowJSFix];
                break;
            case BRFeatureRowVerifyTLS:
                cell.textLabel.text = L(@"Verify certificates");
                cell.accessoryView = [self switchWithValue:[BRSettings verifyTLS] tag:BRFeatureRowVerifyTLS];
                break;
        }
    } else if (indexPath.section == BRSettingsSectionData) {
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        cell.textLabel.textColor = [BRTheme shared].isDark ? [UIColor colorWithRed:0.5 green:0.7 blue:1 alpha:1] : [UIColor colorWithRed:0.2 green:0.36 blue:0.7 alpha:1];
        cell.textLabel.text = indexPath.row == 0 ? L(@"Clear cache") : L(@"Clear cookies");
    } else {
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = L(@"Version");
                cell.detailTextLabel.text = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?";
                break;
            case 1:
                cell.textLabel.text = L(@"Memory");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)BRResidentMemoryMB()];
                break;
            case 2:
                cell.textLabel.text = L(@"Blocked requests");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[BRAdBlock blockedRequestCount]];
                break;
            case 3:
                cell.textLabel.text = L(@"Connections reused");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[BRConnectionPool shared].reuseCount];
                break;
        }
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sw
{
    switch (sw.tag) {
        case BRTagDarkTheme:
            [[BRTheme shared] setDark:sw.on];
            [[BRTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
            [[BRTheme shared] applyToTableView:self.tableView];
            [self.tableView reloadData];
            return;
        case BRFeatureRowAdBlock: [BRSettings setAdBlockEnabled:sw.on]; break;
        case BRFeatureRowCSSFix: [BRSettings setCSSFixEnabled:sw.on]; break;
        case BRFeatureRowJSFix: [BRSettings setJSFixEnabled:sw.on]; break;
        case BRFeatureRowVerifyTLS: [BRSettings setVerifyTLS:sw.on]; break;
    }
    if (sw.tag == BRFeatureRowCSSFix || sw.tag == BRFeatureRowJSFix) {
        // cached bodies were rewritten with the old settings
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == BRSettingsSectionFeatures &&
        (indexPath.row == BRFeatureRowUserAgent || indexPath.row == BRFeatureRowSearchEngine || indexPath.row == BRFeatureRowTextSize)) {
        NSString *title = indexPath.row == BRFeatureRowUserAgent ? L(@"Page version") : indexPath.row == BRFeatureRowSearchEngine ? L(@"Search engine") : L(@"Text size");
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        if (indexPath.row == BRFeatureRowUserAgent) {
            for (NSInteger m = 0; m <= 2; m++) [sheet addButtonWithTitle:[BRSettings userAgentModeTitle:m]];
        } else if (indexPath.row == BRFeatureRowSearchEngine) {
            for (NSInteger e = 0; e < [BRSettings searchEngineCount]; e++) [sheet addButtonWithTitle:[BRSettings searchEngineTitle:e]];
        } else {
            for (NSNumber *p in [self textSizes]) [sheet addButtonWithTitle:[NSString stringWithFormat:@"%@ %%", p]];
        }
        sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
        sheet.tag = indexPath.row;
        CGRect rect = [tableView rectForRowAtIndexPath:indexPath];
        if (BRIsPad()) [sheet showFromRect:rect inView:tableView animated:YES];
        else [sheet showInView:self.view];
        return;
    }
    if (indexPath.section != BRSettingsSectionData) return;
    if (indexPath.row == 0) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        NSString *transpiled = [caches stringByAppendingPathComponent:@"transpiled"];
        [[NSFileManager defaultManager] removeItemAtPath:transpiled error:NULL];
        [[BRJSEngine shared] resetContext];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Cache cleared.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    } else {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSHTTPCookie *c in [jar.cookies copy]) [jar deleteCookie:c];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Cookies cleared.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    }
    [self.tableView reloadData];
}

- (NSArray *)textSizes
{
    return @[@80, @90, @100, @110, @125, @150, @175];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == BRFeatureRowUserAgent) {
        if (buttonIndex > 2) return;
        [BRSettings setUserAgentMode:buttonIndex];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];   // servers answer differently per identity
    } else if (actionSheet.tag == BRFeatureRowSearchEngine) {
        if (buttonIndex >= [BRSettings searchEngineCount]) return;
        [BRSettings setSearchEngine:buttonIndex];
    } else if (actionSheet.tag == BRFeatureRowTextSize) {
        NSArray *sizes = [self textSizes];
        if ((NSUInteger)buttonIndex >= sizes.count) return;
        [BRSettings setTextSizePercent:[sizes[(NSUInteger)buttonIndex] integerValue]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BRTextSizeDidChangeNotification" object:nil];
    }
    [self.tableView reloadData];
}

@end
