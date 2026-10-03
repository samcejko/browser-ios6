#import "BRSettingsViewController.h"
#import "BRSettings.h"
#import "BRTheme.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRJSEngine.h"
#import "BRCSSRewriter.h"
#import "BRURLProtocol.h"
#import "BRPasswords.h"
#import "BRCommon.h"

typedef NS_ENUM(NSInteger, BRSettingsSection) {
    BRSettingsSectionAppearance = 0,
    BRSettingsSectionFeatures,
    BRSettingsSectionPrivacy,
    BRSettingsSectionData,
    BRSettingsSectionInfo,
    BRSettingsSectionAdvanced,
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
    BRFeatureRowCount
};

typedef NS_ENUM(NSInteger, BRPrivacyRow) {
    BRPrivacyRowPrivate = 0,
    BRPrivacyRowAdBlock,
    BRPrivacyRowThirdPartyCookies,
    BRPrivacyRowDoNotTrack,
    BRPrivacyRowCookieBanners,
    BRPrivacyRowSearchSuggestions,
    BRPrivacyRowCount
};

typedef NS_ENUM(NSInteger, BRDataRow) {
    BRDataRowClearCache = 0,
    BRDataRowClearCookies,
    BRDataRowForgetPasswords,
    BRDataRowResetSettings,
    BRDataRowCount
};

typedef NS_ENUM(NSInteger, BRInfoRow) {
    BRInfoRowVersion = 0,
    BRInfoRowBlockedRequests,
    BRInfoRowHelp,
    BRInfoRowLicenses,
    BRInfoRowCount
};

// Troubleshooting switches: a user who plays with them can break every site or browse without verified TLS, so they
// sit at the bottom under a warning. The counters after them are only for a device set up for debugging.
typedef NS_ENUM(NSInteger, BRAdvancedRow) {
    BRAdvancedRowVerifyTLS = 0,
    BRAdvancedRowCSSFix,
    BRAdvancedRowJSFix,
    BRAdvancedRowTranspile,
    BRAdvancedRowMemory,
    BRAdvancedRowConnectionsReused,
    BRAdvancedRowCount
};

// switch tags: section * 100 + row
static NSInteger BRTag(NSInteger section, NSInteger row) { return section * 100 + row; }

static const NSInteger BRAlertCustomSearch = 500;
static const NSInteger BRAlertVerifyTLSOff = 501;

@interface BRSettingsViewController () <UIActionSheetDelegate, UIAlertViewDelegate>
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
        case BRSettingsSectionData: return BRDataRowCount;
        case BRSettingsSectionInfo: return BRInfoRowCount;
        case BRSettingsSectionAdvanced: return BRDebugEnabled() ? BRAdvancedRowCount : BRAdvancedRowMemory;
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
        case BRSettingsSectionAdvanced: return L(@"Advanced");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == BRSettingsSectionFeatures) {
        return L(@"The page version tells servers which browser to serve. iPad with iOS 6 gets pages this engine understands best; the modern identity gets current pages that may not work.");
    }
    if (section == BRSettingsSectionPrivacy) {
        return [NSString stringWithFormat:@"%@\n\n%@", L(@"Cookie banners of the common consent services are hidden; the page then behaves as if nothing was agreed to."),
                L(@"Search suggestions send what you type in the address bar to the search engine (never in private browsing).")];
    }
    if (section == BRSettingsSectionAdvanced) {
        return L(@"For troubleshooting only. Without certificate verification anyone on the network can read and change secure pages, passwords included. Without the rewriting and polyfills most modern sites stop working, and every change of them empties the cache.");
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

// a row that does something when tapped (blue text)
- (void)configureActionCell:(UITableViewCell *)cell title:(NSString *)title
{
    cell.textLabel.text = title;
    cell.textLabel.textColor = [BRTheme shared].isDark ? [UIColor colorWithRed:0.5 green:0.7 blue:1 alpha:1] : [UIColor colorWithRed:0.2 green:0.36 blue:0.7 alpha:1];
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
            case BRPrivacyRowSearchSuggestions:
                cell.textLabel.text = L(@"Search suggestions");
                cell.accessoryView = [self switchWithValue:[BRSettings searchSuggestions] tag:tag];
                break;
        }
    } else if (section == BRSettingsSectionData) {
        switch (row) {
            case BRDataRowClearCache: [self configureActionCell:cell title:L(@"Clear cache")]; break;
            case BRDataRowClearCookies: [self configureActionCell:cell title:L(@"Clear cookies")]; break;
            case BRDataRowForgetPasswords: [self configureActionCell:cell title:L(@"Forget site passwords")]; break;
            case BRDataRowResetSettings: [self configureActionCell:cell title:L(@"Reset settings")]; break;
        }
    } else if (section == BRSettingsSectionInfo) {
        switch (row) {
            case BRInfoRowVersion: {
                // the app's name, its version and the build (CI's run number)
                NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
                NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
                NSString *build = info[@"CFBundleVersion"];
                cell.textLabel.text = @"Surfari";
                cell.detailTextLabel.text = (build.length && ![build isEqualToString:version]) ? [NSString stringWithFormat:@"%@ (%@)", version, build] : version;
                break;
            }
            case BRInfoRowBlockedRequests:
                cell.textLabel.text = L(@"Blocked requests");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[BRAdBlock blockedRequestCount]];
                break;
            case BRInfoRowHelp:
                [self configureActionCell:cell title:L(@"Help and gestures")];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case BRInfoRowLicenses:
                [self configureActionCell:cell title:L(@"Licenses")];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
        }
    } else {
        switch (row) {
            case BRAdvancedRowVerifyTLS:
                cell.textLabel.text = L(@"Verify certificates");
                cell.accessoryView = [self switchWithValue:[BRSettings verifyTLS] tag:tag];
                break;
            case BRAdvancedRowCSSFix:
                cell.textLabel.text = L(@"Rewrite modern CSS");
                cell.accessoryView = [self switchWithValue:[BRSettings cssFixEnabled] tag:tag];
                break;
            case BRAdvancedRowJSFix:
                cell.textLabel.text = L(@"JavaScript polyfills");
                cell.accessoryView = [self switchWithValue:[BRSettings jsFixEnabled] tag:tag];
                break;
            case BRAdvancedRowTranspile:
                cell.textLabel.text = L(@"Translate modern JavaScript");
                cell.accessoryView = [self switchWithValue:[BRSettings transpileEnabled] tag:tag];
                break;
            case BRAdvancedRowMemory:
                cell.textLabel.text = L(@"Memory");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)BRResidentMemoryMB()];
                break;
            case BRAdvancedRowConnectionsReused:
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
        if (row == BRFeatureRowLoadImages) [BRSettings setLoadImages:sw.on];
    } else if (section == BRSettingsSectionPrivacy) {
        switch (row) {
            case BRPrivacyRowPrivate:
                if (![BRSettings setPrivateMode:sw.on]) {
                    // (the normal session's cookies could not be put aside: emptying the jar would risk them)
                    [sw setOn:[BRSettings privateMode] animated:YES];
                    [[[UIAlertView alloc] initWithTitle:nil message:L(@"Private browsing could not be turned on: there is no room to put the cookies of normal browsing aside. Free up some space and try again.")
                                               delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
                }
                break;
            case BRPrivacyRowAdBlock: [BRSettings setAdBlockEnabled:sw.on]; break;
            case BRPrivacyRowThirdPartyCookies: [BRSettings setBlockThirdPartyCookies:sw.on]; break;
            case BRPrivacyRowDoNotTrack: [BRSettings setDoNotTrack:sw.on]; break;
            case BRPrivacyRowCookieBanners: [BRSettings setHideCookieBanners:sw.on]; clearCache = YES; break;
            case BRPrivacyRowSearchSuggestions: [BRSettings setSearchSuggestions:sw.on]; break;
        }
    } else if (section == BRSettingsSectionAdvanced) {
        switch (row) {
            case BRAdvancedRowVerifyTLS:
                if (sw.on) {
                    [BRSettings setVerifyTLS:YES];
                } else {
                    // switching it off is one tap away from browsing without TLS that means anything: it needs a yes
                    [sw setOn:YES animated:YES];
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Turn off certificate verification?")
                                                                    message:L(@"Secure pages could then come from anyone between you and the site (for example on a public Wi-Fi), who can read and change them, passwords included. Turn it back on as soon as you can.")
                                                                   delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Turn Off"), nil];
                    alert.tag = BRAlertVerifyTLSOff;
                    [alert show];
                }
                break;
            case BRAdvancedRowCSSFix: [BRSettings setCSSFixEnabled:sw.on]; clearCache = YES; break;
            case BRAdvancedRowJSFix: [BRSettings setJSFixEnabled:sw.on]; clearCache = YES; break;
            case BRAdvancedRowTranspile: [BRSettings setTranspileEnabled:sw.on]; clearCache = YES; break;
        }
    }
    // cached bodies were rewritten with the old settings
    if (clearCache) [[NSURLCache sharedURLCache] removeAllCachedResponses];
}

- (void)openBundledPage:(NSString *)name
{
    NSURL *page = [[NSBundle mainBundle] URLForResource:name withExtension:@"html"];
    if (!page) return;
    if ([BRTheme shared].isDark) page = [NSURL URLWithString:[page.absoluteString stringByAppendingString:@"?dark"]];
    [self dismissViewControllerAnimated:YES completion:^{
        if (page) [[NSNotificationCenter defaultCenter] postNotificationName:@"BROpenURLNotification" object:nil userInfo:@{ @"url": page }];
    }];
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
            for (NSInteger e = 0; e < [BRSettings searchEngineCount] - 1; e++) [sheet addButtonWithTitle:[BRSettings searchEngineTitle:e]];
            [sheet addButtonWithTitle:[BRSettings customSearchTemplate] ? [NSString stringWithFormat:@"%@ (%@)", [BRSettings searchEngineTitle:4], L(@"Custom")] : L(@"Custom...")];
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
    if (indexPath.section == BRSettingsSectionInfo) {
        if (indexPath.row == BRInfoRowHelp) [self openBundledPage:@"help"];
        else if (indexPath.row == BRInfoRowLicenses) [self openBundledPage:@"licenses"];
        return;
    }
    if (indexPath.section != BRSettingsSectionData) return;
    if (indexPath.row == BRDataRowResetSettings) {
        // back to the defaults (tabs, bookmarks, history and passwords stay; see BRSettings resetAll)
        [BRSettings resetAll];
        [[BRTheme shared] setDark:NO];
        [[BRTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
        [[BRTheme shared] applyToTableView:self.tableView];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BRTextSizeDidChangeNotification" object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BRPageStyleDidChangeNotification" object:nil];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Settings reset.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        [self.tableView reloadData];
        return;
    }
    if (indexPath.row == BRDataRowClearCache) {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        // lowered scripts, and the page inputs a debugging switch may have copied (they hold page data)
        for (NSString *dir in @[@"transpiled", @"rewrite-inputs"]) {
            [[NSFileManager defaultManager] removeItemAtPath:[caches stringByAppendingPathComponent:dir] error:NULL];
        }
        [BRCSSRewriter forgetCachedResults];   // (their copies in memory too)
        [[BRJSEngine shared] resetContext];
        [[BRJSEngine transpiler] resetContext];
        [[BRJSEngine transpiler2] resetContext];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Cache cleared.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    } else if (indexPath.row == BRDataRowClearCookies) {
        // (with those waiting for the end of private browsing; and the cache is keyed by address only, so it would
        // still serve the pages fetched while logged in)
        [BRSettings clearAllCookies];
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Cookies cleared.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    } else {
        [BRURLProtocol forgetCredentials];
        [BRPasswords deleteAll];
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"Site passwords forgotten.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    }
    [self.tableView reloadData];
}

- (NSArray *)textSizes
{
    return @[@80, @90, @100, @110, @125, @150, @175];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    if (alertView.tag == BRAlertVerifyTLSOff) {
        [BRSettings setVerifyTLS:NO];
        [self.tableView reloadData];
        return;
    }
    if (alertView.tag != BRAlertCustomSearch) return;
    NSString *t = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t rangeOfString:@"%s"].location == NSNotFound) {
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"The address must contain %s.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    [BRSettings setCustomSearchTemplate:t];
    if ([BRSettings customSearchTemplate]) [BRSettings setSearchEngine:4];
    [self.tableView reloadData];
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
        if (buttonIndex == 4) {
            // the custom engine: a URL template with %s for the query
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Custom search engine") message:L(@"Address with %s in place of the search text")
                                                           delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Save"), nil];
            alert.alertViewStyle = UIAlertViewStylePlainTextInput;
            UITextField *field = [alert textFieldAtIndex:0];
            field.text = [BRSettings customSearchTemplate] ?: @"https://";
            field.keyboardType = UIKeyboardTypeURL;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            alert.tag = BRAlertCustomSearch;
            [alert show];
            return;
        }
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
