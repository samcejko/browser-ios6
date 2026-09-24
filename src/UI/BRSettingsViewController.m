#import "BRSettingsViewController.h"
#import "BRSettings.h"
#import "BRTheme.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRJSEngine.h"
#import "BRURLProtocol.h"
#import "BRCommon.h"

typedef NS_ENUM(NSInteger, BRSettingsSection) {
    BRSettingsSectionAppearance = 0,
    BRSettingsSectionFeatures,
    BRSettingsSectionPrivacy,
    BRSettingsSectionData,
    BRSettingsSectionInfo,
    BRSettingsSectionCount
};

typedef NS_ENUM(NSInteger, BRAppearanceRow) {
    BRAppearanceRowDarkTheme = 0,
    BRAppearanceRowDarkPages,
    BRAppearanceRowCount
};

typedef NS_ENUM(NSInteger, BRFeatureRow) {
    BRFeatureRowUserAgent = 0,
    BRFeatureRowSearchEngine,
    BRFeatureRowTextSize,
    BRFeatureRowHomePage,
    BRFeatureRowLoadImages,
    BRFeatureRowCSSFix,
    BRFeatureRowJSFix,
    BRFeatureRowVerifyTLS,
    BRFeatureRowCount
};

typedef NS_ENUM(NSInteger, BRPrivacyRow) {
    BRPrivacyRowPrivate = 0,
    BRPrivacyRowAdBlock,
    BRPrivacyRowThirdPartyCookies,
    BRPrivacyRowDoNotTrack,
    BRPrivacyRowCookieBanners,
    BRPrivacyRowCount
};

// switch tags: section * 100 + row
static NSInteger BRTag(NSInteger section, NSInteger row) { return section * 100 + row; }

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
        case BRSettingsSectionAppearance: return BRAppearanceRowCount;
        case BRSettingsSectionFeatures: return BRFeatureRowCount;
        case BRSettingsSectionPrivacy: return BRPrivacyRowCount;
        case BRSettingsSectionData: return 3;
        case BRSettingsSectionInfo: return 4;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case BRSettingsSectionAppearance: return L(@"Appearance");
        case BRSettingsSectionFeatures: return L(@"Pages");
        case BRSettingsSectionPrivacy: return L(@"Privacy");
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
    if (section == BRSettingsSectionPrivacy) {
        return L(@"Cookie banners of the common consent services are hidden; the page then behaves as if nothing was agreed to.");
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

- (void)configureChoiceCell:(UITableViewCell *)cell title:(NSString *)title value:(NSString *)value
{
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
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
    NSInteger section = indexPath.section, row = indexPath.row;
    NSInteger tag = BRTag(section, row);

    if (section == BRSettingsSectionAppearance) {
        if (row == BRAppearanceRowDarkTheme) {
            cell.textLabel.text = L(@"Dark theme");
            cell.accessoryView = [self switchWithValue:[BRSettings darkTheme] tag:tag];
        } else {
            cell.textLabel.text = L(@"Dark pages");
            cell.accessoryView = [self switchWithValue:[BRSettings pagesDark] tag:tag];
        }
    } else if (section == BRSettingsSectionFeatures) {
        switch (row) {
            case BRFeatureRowUserAgent:
                [self configureChoiceCell:cell title:L(@"Page version") value:[BRSettings userAgentModeTitle:[BRSettings userAgentMode]]];
                break;
            case BRFeatureRowSearchEngine:
                [self configureChoiceCell:cell title:L(@"Search engine") value:[BRSettings searchEngineTitle:[BRSettings searchEngine]]];
                break;
            case BRFeatureRowTextSize:
                [self configureChoiceCell:cell title:L(@"Text size") value:[NSString stringWithFormat:@"%ld %%", (long)[BRSettings textSizePercent]]];
                break;
            case BRFeatureRowHomePage: {
                NSString *home = [BRSettings homePageURLString];
                [self configureChoiceCell:cell title:L(@"Home page") value:home ? ([NSURL URLWithString:home].host ?: home) : L(@"Start page")];
                break;
            }
            case BRFeatureRowLoadImages:
                cell.textLabel.text = L(@"Load images");
                cell.accessoryView = [self switchWithValue:[BRSettings loadImages] tag:tag];
                break;
            case BRFeatureRowCSSFix:
                cell.textLabel.text = L(@"Rewrite modern CSS");
                cell.accessoryView = [self switchWithValue:[BRSettings cssFixEnabled] tag:tag];
                break;
            case BRFeatureRowJSFix:
                cell.textLabel.text = L(@"JavaScript polyfills");
                cell.accessoryView = [self switchWithValue:[BRSettings jsFixEnabled] tag:tag];
                break;
            case BRFeatureRowVerifyTLS:
                cell.textLabel.text = L(@"Verify certificates");
                cell.accessoryView = [self switchWithValue:[BRSettings verifyTLS] tag:tag];
                break;
        }
    } else if (section == BRSettingsSectionPrivacy) {
        switch (row) {
            case BRPrivacyRowPrivate:
                cell.textLabel.text = L(@"Private browsing");
                cell.accessoryView = [self switchWithValue:[BRSettings privateMode] tag:tag];
                break;
            case BRPrivacyRowAdBlock:
                cell.textLabel.text = L(@"Block ads and trackers");
                cell.accessoryView = [self switchWithValue:[BRSettings adBlockEnabled] tag:tag];
                break;
            case BRPrivacyRowThirdPartyCookies:
                cell.textLabel.text = L(@"Block third-party cookies");
                cell.accessoryView = [self switchWithValue:[BRSettings blockThirdPartyCookies] tag:tag];
                break;
            case BRPrivacyRowDoNotTrack:
                cell.textLabel.text = L(@"Do Not Track");
                cell.accessoryView = [self switchWithValue:[BRSettings doNotTrack] tag:tag];
                break;
            case BRPrivacyRowCookieBanners:
                cell.textLabel.text = L(@"Hide cookie banners");
                cell.accessoryView = [self switchWithValue:[BRSettings hideCookieBanners] tag:tag];
                break;
        }
    } else if (section == BRSettingsSectionData) {
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        cell.textLabel.textColor = [BRTheme shared].isDark ? [UIColor colorWithRed:0.5 green:0.7 blue:1 alpha:1] : [UIColor colorWithRed:0.2 green:0.36 blue:0.7 alpha:1];
        cell.textLabel.text = row == 0 ? L(@"Clear cache") : row == 1 ? L(@"Clear cookies") : L(@"Forget site passwords");
    } else {
        switch (row) {
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
    NSInteger section = sw.tag / 100, row = sw.tag % 100;
    BOOL clearCache = NO;
    if (section == BRSettingsSectionAppearance) {
        if (row == BRAppearanceRowDarkTheme) {
            [[BRTheme shared] setDark:sw.on];
            [[BRTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
            [[BRTheme shared] applyToTableView:self.tableView];
            [self.tableView reloadData];
        } else {
            [BRSettings setPagesDark:sw.on];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BRPageStyleDidChangeNotification" object:nil];
        }
        return;
    }
    if (section == BRSettingsSectionFeatures) {
        switch (row) {
            case BRFeatureRowLoadImages: [BRSettings setLoadImages:sw.on]; break;
            case BRFeatureRowCSSFix: [BRSettings setCSSFixEnabled:sw.on]; clearCache = YES; break;
            case BRFeatureRowJSFix: [BRSettings setJSFixEnabled:sw.on]; clearCache = YES; break;
            case BRFeatureRowVerifyTLS: [BRSettings setVerifyTLS:sw.on]; break;
        }
    } else if (section == BRSettingsSectionPrivacy) {
        switch (row) {
            case BRPrivacyRowPrivate: [BRSettings setPrivateMode:sw.on]; break;
            case BRPrivacyRowAdBlock: [BRSettings setAdBlockEnabled:sw.on]; break;
            case BRPrivacyRowThirdPartyCookies: [BRSettings setBlockThirdPartyCookies:sw.on]; break;
            case BRPrivacyRowDoNotTrack: [BRSettings setDoNotTrack:sw.on]; break;
            case BRPrivacyRowCookieBanners: [BRSettings setHideCookieBanners:sw.on]; clearCache = YES; break;
        }
    }
    // cached bodies were rewritten with the old settings
    if (clearCache) [[NSURLCache sharedURLCache] removeAllCachedResponses];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == BRSettingsSectionFeatures &&
        (indexPath.row == BRFeatureRowUserAgent || indexPath.row == BRFeatureRowSearchEngine || indexPath.row == BRFeatureRowTextSize || indexPath.row == BRFeatureRowHomePage)) {
        NSString *title = indexPath.row == BRFeatureRowUserAgent ? L(@"Page version") : indexPath.row == BRFeatureRowSearchEngine ? L(@"Search engine") :
                          indexPath.row == BRFeatureRowHomePage ? L(@"Home page") : L(@"Text size");
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        if (indexPath.row == BRFeatureRowUserAgent) {
            for (NSInteger m = 0; m <= 2; m++) [sheet addButtonWithTitle:[BRSettings userAgentModeTitle:m]];
        } else if (indexPath.row == BRFeatureRowSearchEngine) {
            for (NSInteger e = 0; e < [BRSettings searchEngineCount]; e++) [sheet addButtonWithTitle:[BRSettings searchEngineTitle:e]];
        } else if (indexPath.row == BRFeatureRowHomePage) {
            [sheet addButtonWithTitle:L(@"Built-in start page")];
            NSURL *current = [BRURLProtocol lastMainDocumentURL];
            if (current.host.length) [sheet addButtonWithTitle:[NSString stringWithFormat:@"%@ (%@)", L(@"Current page"), current.host]];
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
    } else if (indexPath.row == 1) {
        NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSHTTPCookie *c in [jar.cookies copy]) [jar deleteCookie:c];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Cookies cleared.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    } else {
        [BRURLProtocol forgetCredentials];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Site passwords forgotten.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
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
    } else if (actionSheet.tag == BRFeatureRowHomePage) {
        if (buttonIndex == 0) [BRSettings setHomePageURLString:nil];
        else [BRSettings setHomePageURLString:[BRURLProtocol lastMainDocumentURL].absoluteString];
    } else if (actionSheet.tag == BRFeatureRowTextSize) {
        NSArray *sizes = [self textSizes];
        if ((NSUInteger)buttonIndex >= sizes.count) return;
        [BRSettings setTextSizePercent:[sizes[(NSUInteger)buttonIndex] integerValue]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BRTextSizeDidChangeNotification" object:nil];
    }
    [self.tableView reloadData];
}

@end
