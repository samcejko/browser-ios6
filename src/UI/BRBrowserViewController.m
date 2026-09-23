#import "BRBrowserViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "BRSettingsViewController.h"
#import "BRLibraryViewController.h"
#import "BRTabsViewController.h"
#import "BRTheme.h"
#import "BRLibrary.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRCommon.h"
#import "BRSettings.h"

static const CGFloat BRBarHeight = 44;
static const CGFloat BRControlHeight = 30;

@interface BRBrowserViewController () <UIWebViewDelegate, UITextFieldDelegate, BRLibraryViewControllerDelegate, BRTabsViewControllerDelegate>
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIImageView *topBarBackground;
@property (nonatomic, strong) UIView *bottomBar;             // iPhone only
@property (nonatomic, strong) UIImageView *bottomBarBackground;
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIView *fieldLeftView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *reloadButton;          // inside the address field
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *bookmarksButton;
@property (nonatomic, strong) UIButton *tabsButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) NSMutableArray *tabs;            // dictionaries: url, title, snapshot
@property (nonatomic) NSUInteger currentTab;
@property (nonatomic, copy) NSString *currentTitle;
@property (nonatomic, strong) NSURL *currentURL;               // last main frame URL that was navigated to
@property (nonatomic, strong) NSURL *httpFallbackURL;          // http:// variant of a typed host, tried when https fails
@property (nonatomic) BOOL editingAddress;
@property (nonatomic) BOOL loading;
@property (nonatomic) NSInteger loadCount;
@end

@implementation BRBrowserViewController

#pragma mark - Building the UI

- (UIButton *)textButtonWithTitle:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.titleLabel.shadowOffset = CGSizeMake(0, 1);
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)iconButtonWithAction:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 40, BRControlHeight);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    BRTheme *theme = [BRTheme shared];
    self.view.backgroundColor = [theme pageBackgroundColor];

    self.webView = [[UIWebView alloc] initWithFrame:self.view.bounds];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = YES;
    self.webView.dataDetectorTypes = UIDataDetectorTypeNone;
    [self.view addSubview:self.webView];

    // top bar
    self.topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, BRBarHeight)];
    self.topBarBackground = [[UIImageView alloc] initWithFrame:self.topBar.bounds];
    self.topBarBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.topBar addSubview:self.topBarBackground];
    [self.view addSubview:self.topBar];

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 300, BRControlHeight)];
    self.urlField.borderStyle = UITextBorderStyleNone;
    self.urlField.font = [UIFont systemFontOfSize:15];
    self.urlField.placeholder = L(@"Search or enter address");
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.returnKeyType = UIReturnKeyGo;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.urlField.enablesReturnKeyAutomatically = YES;
    self.urlField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.urlField.delegate = self;
    self.fieldLeftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, BRControlHeight)];
    self.urlField.leftView = self.fieldLeftView;
    self.urlField.leftViewMode = UITextFieldViewModeAlways;
    self.reloadButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.reloadButton.frame = CGRectMake(0, 0, 32, BRControlHeight);
    [self.reloadButton addTarget:self action:@selector(reloadOrStop) forControlEvents:UIControlEventTouchUpInside];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    UIView *rightContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, BRControlHeight)];
    self.spinner.center = CGPointMake(12, BRControlHeight / 2);
    self.reloadButton.frame = CGRectMake(24, 0, 32, BRControlHeight);
    [rightContainer addSubview:self.spinner];
    [rightContainer addSubview:self.reloadButton];
    self.urlField.rightView = rightContainer;
    self.urlField.rightViewMode = UITextFieldViewModeUnlessEditing;
    [self.topBar addSubview:self.urlField];

    self.backButton = [self iconButtonWithAction:@selector(goBack)];
    self.forwardButton = [self iconButtonWithAction:@selector(goForward)];
    self.bookmarksButton = [self textButtonWithTitle:L(@"Bookmarks") action:@selector(showLibrary)];
    self.tabsButton = [self textButtonWithTitle:L(@"Tabs") action:@selector(showTabs)];
    self.settingsButton = [self textButtonWithTitle:L(@"Settings") action:@selector(showSettings)];

    if (BRIsPad()) {
        for (UIView *v in @[self.backButton, self.forwardButton, self.bookmarksButton, self.tabsButton, self.settingsButton]) [self.topBar addSubview:v];
    } else {
        self.bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - BRBarHeight, self.view.bounds.size.width, BRBarHeight)];
        self.bottomBarBackground = [[UIImageView alloc] initWithFrame:self.bottomBar.bounds];
        self.bottomBarBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.bottomBar addSubview:self.bottomBarBackground];
        for (UIView *v in @[self.backButton, self.forwardButton, self.bookmarksButton, self.tabsButton, self.settingsButton]) [self.bottomBar addSubview:v];
        [self.view addSubview:self.bottomBar];
    }

    [self loadTabs];
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:BRThemeDidChangeNotification object:nil];
    [self updateNavigationState];

    NSURL *restored = [NSURL URLWithString:self.tabs[self.currentTab][@"url"] ?: @""];
    if (restored && [[restored.scheme lowercaseString] hasPrefix:@"http"]) [self loadURL:restored];
    else [self goHome];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)themeChanged:(NSNotification *)note
{
    [self applyTheme];
    [self.view setNeedsLayout];
}

- (void)applyTheme
{
    BRTheme *theme = [BRTheme shared];
    self.view.backgroundColor = [theme pageBackgroundColor];
    self.topBarBackground.image = [theme barBackgroundImage];
    self.bottomBarBackground.image = [theme barBackgroundImage];
    self.urlField.background = [theme fieldBackgroundImage];
    self.urlField.textColor = [theme fieldTextColor];
    self.urlField.keyboardAppearance = theme.isDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    self.spinner.activityIndicatorViewStyle = theme.isDark ? UIActivityIndicatorViewStyleWhite : UIActivityIndicatorViewStyleGray;
    for (UIButton *b in @[self.bookmarksButton, self.tabsButton, self.settingsButton]) {
        [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
        [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [b setTitleColor:[theme barTextColor] forState:UIControlStateNormal];
        [b setTitleShadowColor:[theme barTextShadowColor] forState:UIControlStateNormal];
    }
    [self updateNavigationState];
    [self updateLoadingControls];
    [[UIApplication sharedApplication] setStatusBarStyle:[theme statusBarStyle] animated:NO];
}

- (CGFloat)widthForTextButton:(UIButton *)button
{
    NSString *title = [button titleForState:UIControlStateNormal] ?: @"";
    CGSize size = [title sizeWithFont:button.titleLabel.font];
    return ceil(size.width) + button.contentEdgeInsets.left + button.contentEdgeInsets.right;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat width = b.size.width;
    CGFloat y = (BRBarHeight - BRControlHeight) / 2;
    CGFloat gap = 6, margin = 8;
    self.topBar.frame = CGRectMake(0, 0, width, BRBarHeight);
    CGFloat bottom = self.bottomBar ? BRBarHeight : 0;
    if (self.bottomBar) self.bottomBar.frame = CGRectMake(0, b.size.height - bottom, width, bottom);
    self.webView.frame = CGRectMake(0, BRBarHeight, width, b.size.height - BRBarHeight - bottom);

    // text buttons: on narrow screens use a smaller font so that everything fits
    CGFloat available = width - 2 * margin - 2 * 40 - 4 * gap;
    NSArray *textButtons = @[self.bookmarksButton, self.tabsButton, self.settingsButton];
    if (BRIsPad()) available = width * 0.5;
    CGFloat fontSize = 13;
    for (;;) {
        CGFloat total = 0;
        for (UIButton *tb in textButtons) {
            tb.titleLabel.font = [UIFont boldSystemFontOfSize:fontSize];
            tb.contentEdgeInsets = UIEdgeInsetsMake(0, fontSize < 13 ? 7 : 10, 0, fontSize < 13 ? 7 : 10);
            total += [self widthForTextButton:tb];
        }
        if (total <= available || fontSize <= 11) break;
        fontSize -= 1;
    }

    if (BRIsPad()) {
        self.backButton.frame = CGRectMake(margin, y, 40, BRControlHeight);
        self.forwardButton.frame = CGRectMake(CGRectGetMaxX(self.backButton.frame) + gap, y, 40, BRControlHeight);
        CGFloat x = width - margin;
        for (UIButton *tb in @[self.settingsButton, self.tabsButton, self.bookmarksButton]) {
            CGFloat w = [self widthForTextButton:tb];
            x -= w;
            tb.frame = CGRectMake(x, y, w, BRControlHeight);
            x -= gap;
        }
        CGFloat fieldX = CGRectGetMaxX(self.forwardButton.frame) + gap + 2;
        self.urlField.frame = CGRectMake(fieldX, y, x - fieldX, BRControlHeight);
    } else {
        self.urlField.frame = CGRectMake(margin, y, width - 2 * margin, BRControlHeight);
        self.backButton.frame = CGRectMake(margin, y, 40, BRControlHeight);
        self.forwardButton.frame = CGRectMake(CGRectGetMaxX(self.backButton.frame) + gap, y, 40, BRControlHeight);
        CGFloat x = width - margin;
        for (UIButton *tb in @[self.settingsButton, self.tabsButton, self.bookmarksButton]) {
            CGFloat w = [self widthForTextButton:tb];
            x -= w;
            tb.frame = CGRectMake(x, y, w, BRControlHeight);
            x -= gap;
        }
    }
}

#pragma mark - Rotation

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation
{
    return BRIsPad() || orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return BRIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

#pragma mark - Tabs

- (void)loadTabs
{
    self.tabs = [NSMutableArray array];
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"BRTabs"];
    for (id t in saved) {
        if ([t isKindOfClass:[NSDictionary class]] && [t[@"url"] isKindOfClass:[NSString class]]) {
            [self.tabs addObject:[@{ @"url": t[@"url"], @"title": [t[@"title"] isKindOfClass:[NSString class]] ? t[@"title"] : @"" } mutableCopy]];
        }
        if (self.tabs.count >= 12) break;
    }
    if (!self.tabs.count) [self.tabs addObject:[@{ @"url": @"", @"title": @"" } mutableCopy]];
    NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:@"BRCurrentTab"];
    self.currentTab = (current >= 0 && (NSUInteger)current < self.tabs.count) ? (NSUInteger)current : 0;
    [self updateTabsButton];
}

- (void)saveTabs
{
    NSMutableArray *plain = [NSMutableArray array];
    for (NSDictionary *t in self.tabs) [plain addObject:@{ @"url": t[@"url"] ?: @"", @"title": t[@"title"] ?: @"" }];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:plain forKey:@"BRTabs"];
    [d setInteger:(NSInteger)self.currentTab forKey:@"BRCurrentTab"];
    [d synchronize];
}

- (void)updateTabsButton
{
    [self.tabsButton setTitle:[NSString stringWithFormat:@"%@ %lu", L(@"Tabs"), (unsigned long)self.tabs.count] forState:UIControlStateNormal];
    [self.view setNeedsLayout];
}

- (UIImage *)snapshotOfWebView
{
    CGSize size = self.webView.bounds.size;
    if (size.width < 1 || size.height < 1) return nil;
    CGFloat scale = 120.0 / size.width;
    CGSize target = CGSizeMake(120, floor(size.height * scale));
    UIGraphicsBeginImageContextWithOptions(target, YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(ctx, scale, scale);
    [self.webView.layer renderInContext:ctx];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// Records the page shown right now into the current tab entry.
- (void)storeCurrentTabState
{
    if (self.currentTab >= self.tabs.count) return;
    NSMutableDictionary *tab = self.tabs[self.currentTab];
    NSURL *url = self.webView.request.URL ?: self.currentURL;
    tab[@"url"] = ([BRSettings isHomeURL:url] || !url) ? @"" : (url.absoluteString ?: @"");
    tab[@"title"] = self.currentTitle ?: @"";
    UIImage *snapshot = [self snapshotOfWebView];
    if (snapshot) tab[@"snapshot"] = snapshot;
    else [tab removeObjectForKey:@"snapshot"];
}

- (void)openTabAtIndex:(NSUInteger)index
{
    if (index >= self.tabs.count) return;
    self.currentTab = index;
    NSDictionary *tab = self.tabs[index];
    NSURL *url = [NSURL URLWithString:tab[@"url"] ?: @""];
    self.currentTitle = tab[@"title"];
    [self updateTabsButton];
    [self saveTabs];
    if (url && [[url.scheme lowercaseString] hasPrefix:@"http"]) [self loadURL:url];
    else [self goHome];
}

- (void)presentModal:(UIViewController *)controller
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [[BRTheme shared] applyToNavigationBar:nav.navigationBar];
    nav.modalPresentationStyle = BRIsPad() ? UIModalPresentationFormSheet : UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showTabs
{
    [self storeCurrentTabState];
    BRTabsViewController *tabsController = [[BRTabsViewController alloc] init];
    tabsController.delegate = self;
    tabsController.tabs = self.tabs;
    tabsController.currentIndex = self.currentTab;
    [self presentModal:tabsController];
}

- (void)tabsViewController:(BRTabsViewController *)controller didSelectTabAtIndex:(NSUInteger)index
{
    if (index == self.currentTab) return;
    [self openTabAtIndex:index];
}

- (void)tabsViewController:(BRTabsViewController *)controller didCloseTabAtIndex:(NSUInteger)index
{
    if (index >= self.tabs.count) return;
    [self.tabs removeObjectAtIndex:index];
    if (!self.tabs.count) {
        [self.tabs addObject:[@{ @"url": @"", @"title": @"" } mutableCopy]];
        [self openTabAtIndex:0];
        return;
    }
    if (index == self.currentTab) {
        [self openTabAtIndex:MIN(index, self.tabs.count - 1)];
    } else {
        if (index < self.currentTab) self.currentTab--;
        [self updateTabsButton];
        [self saveTabs];
    }
    controller.currentIndex = self.currentTab;
}

- (void)tabsViewControllerDidRequestNewTab:(BRTabsViewController *)controller
{
    [self storeCurrentTabState];
    [self.tabs addObject:[@{ @"url": @"", @"title": @"" } mutableCopy]];
    [self openTabAtIndex:self.tabs.count - 1];
}

#pragma mark - Actions

- (void)goBack
{
    [self.webView goBack];
}

- (void)goForward
{
    [self.webView goForward];
}

- (void)reloadOrStop
{
    if (self.loading) [self stop];
    else [self reload];
}

- (void)reload
{
    if (self.currentURL) [self loadURL:self.currentURL];
    else [self.webView reload];
}

- (void)stop
{
    [self.webView stopLoading];
    self.loadCount = 0;
    [self setLoading:NO];
}

- (void)goHome
{
    NSURL *home = [BRSettings homeURL];
    if (home) [self loadURL:home];
    else [self loadURL:[NSURL URLWithString:@"https://lite.duckduckgo.com/lite/"]];
}

- (void)loadURL:(NSURL *)url
{
    if (!url) return;
    self.currentURL = url;
    [self updateAddressFieldWithURL:url];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60]];
}

- (void)navigateToTypedText:(NSString *)text
{
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;
    self.httpFallbackURL = nil;
    NSURL *url = nil;
    BOOL hasSpace = [t rangeOfString:@" "].location != NSNotFound;
    BOOL hasScheme = [t rangeOfString:@"://"].location != NSNotFound;
    BOOL looksLikeHost = [t rangeOfString:@"."].location != NSNotFound || [t hasPrefix:@"localhost"];
    if (!hasSpace && hasScheme) {
        url = [NSURL URLWithString:[t stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    } else if (!hasSpace && looksLikeHost) {
        url = [NSURL URLWithString:[[@"https://" stringByAppendingString:t] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
        self.httpFallbackURL = [NSURL URLWithString:[[@"http://" stringByAppendingString:t] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    }
    if (!url || !url.host.length) {
        url = [BRSettings searchURLForQuery:t];
        self.httpFallbackURL = nil;
    }
    [self loadURL:url];
}

- (void)showSettings
{
    [self presentModal:[[BRSettingsViewController alloc] init]];
}

- (void)showLibrary
{
    BRLibraryViewController *library = [[BRLibraryViewController alloc] init];
    library.delegate = self;
    NSURL *url = self.webView.request.URL ?: self.currentURL;
    if (url && [[url.scheme lowercaseString] hasPrefix:@"http"]) {
        library.currentURL = url;
        library.currentTitle = self.currentTitle;
    }
    [self presentModal:library];
}

- (void)libraryViewController:(BRLibraryViewController *)controller didSelectURL:(NSURL *)url
{
    [self loadURL:url];
}

#pragma mark - State

- (void)setLoading:(BOOL)loading
{
    _loading = loading;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = loading;
    [self updateLoadingControls];
}

- (void)updateLoadingControls
{
    BRTheme *theme = [BRTheme shared];
    if (self.loading) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
    [self.reloadButton setImage:self.loading ? [theme stopImage] : [theme reloadImage] forState:UIControlStateNormal];
}

- (void)updateNavigationState
{
    BRTheme *theme = [BRTheme shared];
    BOOL canBack = self.webView.canGoBack, canForward = self.webView.canGoForward;
    self.backButton.enabled = canBack;
    self.forwardButton.enabled = canForward;
    [self.backButton setImage:[theme arrowImagePointingLeft:YES enabled:canBack] forState:UIControlStateNormal];
    [self.forwardButton setImage:[theme arrowImagePointingLeft:NO enabled:canForward] forState:UIControlStateNormal];
}

- (void)updateAddressFieldWithURL:(NSURL *)url
{
    if (self.editingAddress) return;
    if (!url || [BRSettings isHomeURL:url] || [url.scheme isEqualToString:@"about"] || [url.scheme isEqualToString:@"applewebdata"]) {
        self.urlField.text = @"";
        return;
    }
    self.urlField.text = url.absoluteString;
}

- (void)showErrorPageForURL:(NSURL *)url error:(NSError *)error
{
    NSString *urlString = url.absoluteString ?: @"";
    NSString *message = error.localizedDescription ?: @"";
    BOOL dark = [BRTheme shared].isDark;
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"];
    [html appendFormat:@"<title>%@</title>", BRHTMLEscape(L(@"Page could not be loaded"))];
    [html appendFormat:@"<style>body{font-family:Helvetica,Arial,sans-serif;background:%@;color:%@;margin:0;padding:24px}"
                        "h1{font-size:22px;margin:0 0 12px}p{font-size:15px;line-height:1.4}.url{word-break:break-all;color:#888;font-size:13px}"
                        "a.btn{display:inline-block;margin:8px 8px 0 0;padding:10px 16px;background:#4a90e2;color:#fff;text-decoration:none;border-radius:6px;font-size:15px}"
                        "</style></head><body>", dark ? @"#1c1c1e" : @"#f2f2f5", dark ? @"#eee" : @"#333"];
    [html appendFormat:@"<h1>%@</h1>", BRHTMLEscape(L(@"Page could not be loaded"))];
    [html appendFormat:@"<p>%@</p>", BRHTMLEscape(message)];
    [html appendFormat:@"<p class=\"url\">%@</p>", BRHTMLEscape(urlString)];
    [html appendFormat:@"<p><a class=\"btn\" href=\"%@\">%@</a>", BRHTMLEscape(urlString), BRHTMLEscape(L(@"Try again"))];
    if ([[url.scheme lowercaseString] isEqualToString:@"https"] && urlString.length > 5) {
        NSString *httpURL = [@"http" stringByAppendingString:[urlString substringFromIndex:5]];
        [html appendFormat:@"<a class=\"btn\" href=\"%@\">%@</a>", BRHTMLEscape(httpURL), BRHTMLEscape(L(@"Open via http://"))];
    }
    [html appendString:@"</p></body></html>"];
    [self.webView loadHTMLString:html baseURL:url];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    NSString *text = textField.text;
    [textField resignFirstResponder];
    [self navigateToTypedText:text];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    self.editingAddress = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (textField.isFirstResponder) [textField selectAll:nil];
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    self.editingAddress = NO;
    [self updateAddressFieldWithURL:self.webView.request.URL ?: self.currentURL];
}

#pragma mark - UIWebViewDelegate

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL *url = request.URL;
    NSString *scheme = [url.scheme lowercaseString];
    BOOL handled = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"file"] ||
                   [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"] || [scheme isEqualToString:@"applewebdata"];
    if (handled) {
        BOOL mainFrame = [url isEqual:request.mainDocumentURL] || navigationType != UIWebViewNavigationTypeOther;
        if (mainFrame && ![scheme isEqualToString:@"about"] && ![scheme isEqualToString:@"applewebdata"]) {
            self.currentURL = url;
            [self updateAddressFieldWithURL:url];
        }
        return YES;
    }
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) [[UIApplication sharedApplication] openURL:url];   // mailto:, tel:, cydia:
    return NO;
}

- (void)webViewDidStartLoad:(UIWebView *)webView
{
    self.loadCount++;
    [self setLoading:YES];
    [self updateNavigationState];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
    self.loadCount = MAX(0, self.loadCount - 1);
    if (self.loadCount == 0) [self setLoading:NO];
    [self updateNavigationState];
    NSURL *url = webView.request.URL;
    if (url.absoluteString.length) {
        [self updateAddressFieldWithURL:url];
        if ([[url.scheme lowercaseString] hasPrefix:@"http"]) self.currentURL = url;
    }
    if (self.loadCount == 0) {
        self.httpFallbackURL = nil;
        NSString *title = [webView stringByEvaluatingJavaScriptFromString:@"document.title"] ?: @"";
        self.currentTitle = title;
        if (url && [[url.scheme lowercaseString] hasPrefix:@"http"]) [[BRLibrary shared] recordVisit:url title:title];
        if (self.currentTab < self.tabs.count) {
            NSMutableDictionary *tab = self.tabs[self.currentTab];
            tab[@"url"] = ([BRSettings isHomeURL:url] || !url) ? @"" : (url.absoluteString ?: @"");
            tab[@"title"] = title;
            [self saveTabs];
        }
        BRLog(@"Loaded %@ (%@), %lu requests blocked, %lu connections reused, %lu idle, %ld MB", url.absoluteString ?: @"?",
              title.length > 80 ? [title substringToIndex:80] : title, (unsigned long)[BRAdBlock blockedRequestCount],
              (unsigned long)[BRConnectionPool shared].reuseCount, (unsigned long)[BRConnectionPool shared].idleCount, (long)BRResidentMemoryMB());
        if ([BRSettings isHomeURL:url]) {
            NSString *info = [webView stringByEvaluatingJavaScriptFromString:@"document.getElementById('info').innerText"];
            BRLog(@"Home page: %@", info ?: @"");
        }
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    self.loadCount = MAX(0, self.loadCount - 1);
    if (self.loadCount == 0) [self setLoading:NO];
    [self updateNavigationState];

    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && (error.code == 102 || error.code == 204)) return;   // frame load interrupted, plug-in

    NSString *failingString = error.userInfo[NSURLErrorFailingURLStringErrorKey];
    NSURL *failingURL = failingString.length ? [NSURL URLWithString:failingString] : error.userInfo[NSURLErrorFailingURLErrorKey];
    if (!failingURL) failingURL = self.currentURL;
    NSString *mainString = webView.request.URL.absoluteString ?: @"";
    BOOL mainFrame = [failingURL.absoluteString isEqualToString:self.currentURL.absoluteString] || [failingURL.absoluteString isEqualToString:mainString];
    if (!mainFrame) {
        BRLog(@"Subframe error ignored (%ld): %@", (long)error.code, failingURL.absoluteString);
        return;
    }
    BRLog(@"Main frame failed (%@ %ld): %@", error.domain, (long)error.code, error.localizedDescription);

    if (self.httpFallbackURL && [[failingURL.scheme lowercaseString] isEqualToString:@"https"] &&
        [[failingURL.host lowercaseString] isEqualToString:[self.httpFallbackURL.host lowercaseString]] &&
        (error.code == NSURLErrorSecureConnectionFailed || error.code == NSURLErrorCannotConnectToHost ||
         error.code == NSURLErrorTimedOut || error.code == NSURLErrorNetworkConnectionLost)) {
        NSURL *fallback = self.httpFallbackURL;
        self.httpFallbackURL = nil;
        BRLog(@"Retrying over http: %@", fallback.absoluteString);
        [self loadURL:fallback];
        return;
    }
    self.httpFallbackURL = nil;
    [self showErrorPageForURL:failingURL error:error];
}

@end
