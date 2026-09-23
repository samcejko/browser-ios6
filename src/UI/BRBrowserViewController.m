#import "BRBrowserViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "BRSettingsViewController.h"
#import "BRLibraryViewController.h"
#import "BRTabsViewController.h"
#import "BRTabBar.h"
#import "BRTheme.h"
#import "BRLibrary.h"
#import "BRDownloader.h"
#import "BRURLProtocol.h"
#import "BRHTTPRequest.h"
#import "BRWatchdog.h"
#import "BRAdBlock.h"
#import "BRConnectionPool.h"
#import "BRCommon.h"
#import "BRSettings.h"

static const CGFloat BRBarHeight = 44;
static const CGFloat BRTabBarHeight = 30;
static const CGFloat BRControlHeight = 30;

@interface BRBrowserViewController () <UIWebViewDelegate, UITextFieldDelegate, BRLibraryViewControllerDelegate, BRTabsViewControllerDelegate, BRTabBarDelegate,
                                        UIGestureRecognizerDelegate, UIActionSheetDelegate, UITableViewDataSource, UITableViewDelegate,
                                        UIDocumentInteractionControllerDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UILongPressGestureRecognizer *linkPress;
@property (nonatomic, strong) UIPopoverController *sharePopover;      // iPad
@property (nonatomic, strong) NSDictionary *pressedLink;              // href, text, img of the long-pressed element
@property (nonatomic, strong) UITableView *suggestionsTable;           // history and bookmark matches while typing
@property (nonatomic, strong) NSArray *suggestions;                    // dictionaries: title, url, kind
@property (nonatomic, copy) NSString *pendingSuggestionText;           // last text scheduled for a search suggestion request
@property (nonatomic) NSUInteger pressedTabIndex;                      // tab under the long press menu
@property (nonatomic, strong) UIRefreshControl *refreshControl;         // pull to refresh on the page
@property (nonatomic, strong) UIView *findBar;
@property (nonatomic, strong) UIImageView *findBarBackground;
@property (nonatomic, strong) UITextField *findField;
@property (nonatomic, strong) UILabel *findLabel;
@property (nonatomic, strong) UIButton *findPrevButton;
@property (nonatomic, strong) UIButton *findNextButton;
@property (nonatomic, strong) UIButton *findDoneButton;
@property (nonatomic, strong) UIView *progressView;                    // blue fill in the address field
@property (nonatomic, strong) UIButton *lockButton;
@property (nonatomic, strong) UIDocumentInteractionController *documentController;
@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIImageView *topBarBackground;
@property (nonatomic, strong) BRTabBar *tabBar;              // iPad only: Safari style tab strip under the address bar
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

// "Add bookmark" entry in the share sheet
@interface BRBookmarkActivity : UIActivity
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *pageTitle;
@end

@implementation BRBookmarkActivity
- (NSString *)activityType { return @"com.samcejko.browser.bookmark"; }
- (NSString *)activityTitle { return [[BRLibrary shared] isBookmarked:self.url] ? L(@"Remove bookmark") : L(@"Add bookmark"); }
- (UIImage *)activityImage
{
    CGFloat side = BRIsPad() ? 76 : 60;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    UIBezierPath *star = [UIBezierPath bezierPath];
    CGFloat cx = side / 2, cy = side / 2 + 2, outer = side * 0.36, inner = outer * 0.45;
    for (int i = 0; i < 10; i++) {
        CGFloat r = (i % 2 == 0) ? outer : inner;
        CGFloat a = -M_PI_2 + i * M_PI / 5;
        CGPoint p = CGPointMake(cx + r * cos(a), cy + r * sin(a));
        if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
    }
    [star closePath];
    [[UIColor colorWithWhite:0.35 alpha:1] setFill];
    [star fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}
- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems
{
    for (id item in activityItems) if ([item isKindOfClass:[NSURL class]] && [[[item scheme] lowercaseString] hasPrefix:@"http"]) return YES;
    return NO;
}
- (void)prepareWithActivityItems:(NSArray *)activityItems
{
    for (id item in activityItems) {
        if ([item isKindOfClass:[NSURL class]]) self.url = item;
        else if ([item isKindOfClass:[NSString class]] && !self.pageTitle) self.pageTitle = item;
    }
}
- (void)performActivity
{
    if (self.url) {
        if ([[BRLibrary shared] isBookmarked:self.url]) [[BRLibrary shared] removeBookmark:self.url];
        else [[BRLibrary shared] addBookmark:self.url title:self.pageTitle ?: self.url.host];
    }
    [self activityDidFinish:YES];
}
@end

// "Reader" entry in the share sheet
@interface BRReaderActivity : UIActivity
@property (nonatomic, copy) void (^action)(void);
@end

@implementation BRReaderActivity
- (NSString *)activityType { return @"com.samcejko.browser.reader"; }
- (NSString *)activityTitle { return L(@"Reader"); }
- (UIImage *)activityImage
{
    CGFloat side = BRIsPad() ? 76 : 60;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    [[UIColor colorWithWhite:0.35 alpha:1] setFill];
    CGFloat x = side * 0.22, w = side * 0.56, y = side * 0.24;
    for (int i = 0; i < 5; i++) {
        CGFloat lineW = (i == 0) ? w * 0.7 : (i == 4 ? w * 0.5 : w);
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y + i * side * 0.11, lineW, side * 0.055) cornerRadius:2] fill];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}
- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems { return self.action != nil; }
- (void)performActivity { if (self.action) self.action(); [self activityDidFinish:YES]; }
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
    self.webView.allowsInlineMediaPlayback = YES;             // <video playsinline> stays in the page like in modern browsers
    self.webView.keyboardDisplayRequiresUserAction = NO;      // scripts may focus fields (search boxes, login forms)
    self.webView.mediaPlaybackAllowsAirPlay = YES;
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    [self.webView.scrollView addSubview:self.refreshControl];
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
    UILongPressGestureRecognizer *reloadPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(reloadMenu:)];
    reloadPress.minimumPressDuration = 0.5;
    [self.reloadButton addGestureRecognizer:reloadPress];
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
    self.bookmarksButton = [self iconButtonWithAction:@selector(showLibrary)];
    self.bookmarksButton.accessibilityLabel = L(@"Bookmarks");
    self.shareButton = [self iconButtonWithAction:@selector(shareCurrentPage)];
    self.shareButton.accessibilityLabel = L(@"Share");
    self.tabsButton = [self textButtonWithTitle:L(@"Tabs") action:@selector(showTabs)];
    self.settingsButton = [self textButtonWithTitle:L(@"Settings") action:@selector(showSettings)];

    // long press on a link or image: our own menu (the page's touch callout is switched off by shims-extra.js)
    self.linkPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.linkPress.minimumPressDuration = 0.6;
    self.linkPress.delegate = self;
    [self.webView addGestureRecognizer:self.linkPress];

    if (BRIsPad()) {
        for (UIView *v in @[self.backButton, self.forwardButton, self.bookmarksButton, self.shareButton, self.settingsButton]) [self.topBar addSubview:v];
        self.tabBar = [[BRTabBar alloc] initWithFrame:CGRectMake(0, BRBarHeight, self.view.bounds.size.width, BRTabBarHeight)];
        self.tabBar.delegate = self;
        [self.view addSubview:self.tabBar];
    } else {
        self.bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - BRBarHeight, self.view.bounds.size.width, BRBarHeight)];
        self.bottomBarBackground = [[UIImageView alloc] initWithFrame:self.bottomBar.bounds];
        self.bottomBarBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.bottomBar addSubview:self.bottomBarBackground];
        for (UIView *v in @[self.backButton, self.forwardButton, self.bookmarksButton, self.shareButton, self.tabsButton, self.settingsButton]) [self.bottomBar addSubview:v];
        [self.view addSubview:self.bottomBar];
    }

    // loading progress: a translucent fill that grows across the address field
    self.progressView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, BRControlHeight)];
    self.progressView.userInteractionEnabled = NO;
    self.progressView.layer.cornerRadius = 7;
    self.progressView.hidden = YES;
    [self.urlField addSubview:self.progressView];

    // padlock for https pages (tap for the connection details)
    self.lockButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.lockButton.frame = CGRectMake(0, 0, 26, BRControlHeight);
    [self.lockButton addTarget:self action:@selector(showConnectionInfo) forControlEvents:UIControlEventTouchUpInside];

    [self loadTabs];
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:BRThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pageProgress:) name:BRPageProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textSizeChanged:) name:@"BRTextSizeDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(privateModeChanged:) name:@"BRPrivateModeDidChangeNotification" object:nil];
    [self privateModeChanged:nil];
    [self updateNavigationState];

    NSURL *restored = [NSURL URLWithString:self.tabs[self.currentTab][@"url"] ?: @""];
    if (self.skipRestore) { /* the launch URL arrives right after this and takes the tab */ }
    else if (restored && [[restored.scheme lowercaseString] hasPrefix:@"http"]) [self loadURL:restored];
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
    for (UIButton *b in @[self.bookmarksButton, self.shareButton, self.tabsButton, self.settingsButton]) {
        [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
        [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [b setTitleColor:[theme barTextColor] forState:UIControlStateNormal];
        [b setTitleShadowColor:[theme barTextShadowColor] forState:UIControlStateNormal];
    }
    [self.bookmarksButton setImage:[theme bookmarksImage] forState:UIControlStateNormal];
    [self.shareButton setImage:[theme shareImage] forState:UIControlStateNormal];
    [self.lockButton setImage:[theme lockImage] forState:UIControlStateNormal];
    self.progressView.backgroundColor = [theme progressColor];
    [self.tabBar applyTheme];
    if (self.findBar) [self applyThemeToFindBar];
    if (self.suggestionsTable) {
        self.suggestionsTable.backgroundColor = theme.isDark ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor whiteColor];
        self.suggestionsTable.separatorColor = theme.isDark ? [UIColor colorWithWhite:0.25 alpha:1] : [UIColor colorWithWhite:0.85 alpha:1];
        [self.suggestionsTable reloadData];
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
    CGFloat tabsHeight = self.tabBar ? BRTabBarHeight : 0;
    if (self.tabBar) self.tabBar.frame = CGRectMake(0, BRBarHeight, width, BRTabBarHeight);
    CGFloat bottom = self.bottomBar ? BRBarHeight : 0;
    if (self.bottomBar) self.bottomBar.frame = CGRectMake(0, b.size.height - bottom, width, bottom);
    CGFloat findHeight = (self.findBar && !self.findBar.hidden) ? BRBarHeight : 0;
    if (findHeight) {
        self.findBar.frame = CGRectMake(0, BRBarHeight + tabsHeight, width, BRBarHeight);
        [self layoutFindBar];
    }
    CGFloat contentTop = BRBarHeight + tabsHeight + findHeight;
    self.webView.frame = CGRectMake(0, contentTop, width, b.size.height - contentTop - bottom);
    if (self.suggestionsTable) self.suggestionsTable.frame = CGRectMake(0, BRBarHeight + tabsHeight, width, b.size.height - BRBarHeight - tabsHeight - bottom);
    self.progressView.frame = CGRectMake(0, 0, floor(self.urlField.bounds.size.width * [self currentProgress]), self.urlField.bounds.size.height);

    // text buttons: on narrow screens use a smaller font so that everything fits
    CGFloat available = width - 2 * margin - 4 * 40 - 6 * gap;
    NSArray *textButtons = BRIsPad() ? @[self.settingsButton] : @[self.tabsButton, self.settingsButton];
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

    self.backButton.frame = CGRectMake(margin, y, 40, BRControlHeight);
    self.forwardButton.frame = CGRectMake(CGRectGetMaxX(self.backButton.frame) + gap, y, 40, BRControlHeight);
    self.bookmarksButton.frame = CGRectMake(CGRectGetMaxX(self.forwardButton.frame) + gap, y, 40, BRControlHeight);
    self.shareButton.frame = CGRectMake(CGRectGetMaxX(self.bookmarksButton.frame) + gap, y, 40, BRControlHeight);
    CGFloat x = width - margin;
    for (UIButton *tb in BRIsPad() ? @[self.settingsButton] : @[self.settingsButton, self.tabsButton]) {
        CGFloat w = [self widthForTextButton:tb];
        x -= w;
        tb.frame = CGRectMake(x, y, w, BRControlHeight);
        x -= gap;
    }
    if (BRIsPad()) {
        CGFloat fieldX = CGRectGetMaxX(self.shareButton.frame) + gap + 2;
        self.urlField.frame = CGRectMake(fieldX, y, x - fieldX, BRControlHeight);
    } else {
        self.urlField.frame = CGRectMake(margin, y, width - 2 * margin, BRControlHeight);
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

- (NSString *)displayTitleForTab:(NSDictionary *)tab
{
    NSString *title = tab[@"title"];
    if ([title isKindOfClass:[NSString class]] && title.length) return title;
    NSURL *url = [NSURL URLWithString:tab[@"url"] ?: @""];
    if (url.host.length) return url.host;
    return L(@"New tab");
}

- (void)updateTabsButton
{
    [self.tabsButton setTitle:[NSString stringWithFormat:@"%@ %lu", L(@"Tabs"), (unsigned long)self.tabs.count] forState:UIControlStateNormal];
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity:self.tabs.count];
    NSMutableArray *icons = [NSMutableArray arrayWithCapacity:self.tabs.count];
    for (NSDictionary *t in self.tabs) {
        [titles addObject:[self displayTitleForTab:t]];
        UIImage *icon = [self faviconForURLString:t[@"url"]];
        [icons addObject:icon ?: [NSNull null]];
    }
    [self.tabBar setTitles:titles icons:icons selectedIndex:self.currentTab];
    [self.view setNeedsLayout];
}

#pragma mark - Favicons

static NSCache *BRFaviconCache(void)
{
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 64; });
    return cache;
}

- (UIImage *)faviconForURLString:(NSString *)urlString
{
    NSString *host = [[NSURL URLWithString:[urlString isKindOfClass:[NSString class]] ? urlString : @""].host lowercaseString];
    if (!host.length) return nil;
    id cached = [BRFaviconCache() objectForKey:host];
    return [cached isKindOfClass:[UIImage class]] ? cached : nil;
}

// Asks the page for its icon link, fetches it through the app's stack and refreshes the tab strip.
- (void)fetchFaviconForCurrentPage
{
    NSURL *pageURL = self.webView.request.URL ?: self.currentURL;
    NSString *host = [pageURL.host lowercaseString];
    if (!host.length || ![[pageURL.scheme lowercaseString] hasPrefix:@"http"]) return;
    if ([BRFaviconCache() objectForKey:host]) return;   // known (an image or a failure marker)
    NSString *js = @"(function(){var links=document.querySelectorAll('link[rel~=\"icon\"],link[rel=\"shortcut icon\"],link[rel=\"apple-touch-icon\"]');"
                    "var best='',bestSize=0;for(var i=0;i<links.length;i++){var l=links[i];if(!l.href)continue;var s=parseInt((l.getAttribute('sizes')||'0x0').split('x')[0],10)||16;"
                    "if(/apple-touch/.test(l.rel))s=Math.min(s||180,64);if(!best||(s>=16&&s<=64&&s>bestSize)){best=l.href;bestSize=s;}}return best;})()";
    NSString *iconString = [self.webView stringByEvaluatingJavaScriptFromString:js];
    NSURL *iconURL = iconString.length ? [NSURL URLWithString:iconString] : nil;
    if (!iconURL) iconURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/favicon.ico", pageURL.scheme, pageURL.host]];
    if (!iconURL) return;
    [BRFaviconCache() setObject:[NSNull null] forKey:host];   // fetch in progress; replaced by the image or left as a marker
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:iconURL];
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        UIImage *small = nil;
        if (image && image.size.width > 0 && image.size.height > 0) {
            CGFloat side = 16;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
            [image drawInRect:CGRectMake(0, 0, side, side)];
            small = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (small) {
                [BRFaviconCache() setObject:small forKey:host];
                [self updateTabsButton];
            }
        });
    });
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

- (void)closeTabAtIndex:(NSUInteger)index
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
}

- (void)openNewTab
{
    if (self.tabs.count >= 12) return;
    [self storeCurrentTabState];
    [self.tabs addObject:[@{ @"url": @"", @"title": @"" } mutableCopy]];
    [self openTabAtIndex:self.tabs.count - 1];
}

- (void)tabsViewController:(BRTabsViewController *)controller didSelectTabAtIndex:(NSUInteger)index
{
    if (index == self.currentTab) return;
    [self openTabAtIndex:index];
}

- (void)tabsViewController:(BRTabsViewController *)controller didCloseTabAtIndex:(NSUInteger)index
{
    [self closeTabAtIndex:index];
    controller.currentIndex = self.currentTab;
}

- (void)tabsViewControllerDidRequestNewTab:(BRTabsViewController *)controller
{
    [self openNewTab];
}

#pragma mark - BRTabBarDelegate (tab strip)

- (void)tabBar:(BRTabBar *)bar didSelectTabAtIndex:(NSUInteger)index
{
    if (index == self.currentTab || index >= self.tabs.count) return;
    [self.urlField resignFirstResponder];
    [self storeCurrentTabState];
    [self openTabAtIndex:index];
}

- (void)tabBar:(BRTabBar *)bar didCloseTabAtIndex:(NSUInteger)index
{
    [self.urlField resignFirstResponder];
    [self closeTabAtIndex:index];
}

- (void)tabBarDidRequestNewTab:(BRTabBar *)bar
{
    [self.urlField resignFirstResponder];
    [self openNewTab];
    if (BRIsPad()) [self.urlField becomeFirstResponder];
}

- (void)tabBar:(BRTabBar *)bar didLongPressTabAtIndex:(NSUInteger)index fromRect:(CGRect)rect
{
    if (index >= self.tabs.count) return;
    self.pressedTabIndex = index;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[self displayTitleForTab:self.tabs[index]] delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Close tab")];
    if (self.tabs.count > 1) [sheet addButtonWithTitle:L(@"Close other tabs")];
    [sheet addButtonWithTitle:L(@"Duplicate tab")];
    if (index == self.currentTab) [sheet addButtonWithTitle:L(@"Reload")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = 102;
    [sheet showFromRect:[self.view convertRect:rect fromView:bar] inView:self.view animated:YES];
}

- (void)handleTabMenuChoice:(NSString *)choice
{
    NSUInteger index = self.pressedTabIndex;
    if (index >= self.tabs.count) return;
    if ([choice isEqualToString:L(@"Close tab")]) {
        [self closeTabAtIndex:index];
    } else if ([choice isEqualToString:L(@"Close other tabs")]) {
        BOOL keepingCurrent = (index == self.currentTab);
        if (!keepingCurrent) [self storeCurrentTabState];
        NSMutableDictionary *keep = self.tabs[index];
        [self.tabs removeAllObjects];
        [self.tabs addObject:keep];
        self.currentTab = 0;
        [self updateTabsButton];
        [self saveTabs];
        if (!keepingCurrent) [self openTabAtIndex:0];
    } else if ([choice isEqualToString:L(@"Duplicate tab")]) {
        if (self.tabs.count >= 12) return;
        [self storeCurrentTabState];
        NSDictionary *src = self.tabs[index];
        [self.tabs insertObject:[@{ @"url": src[@"url"] ?: @"", @"title": src[@"title"] ?: @"" } mutableCopy] atIndex:index + 1];
        [self openTabAtIndex:index + 1];
    } else if ([choice isEqualToString:L(@"Reload")]) {
        [self reload];
    }
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

// Long press on the reload button: desktop/mobile version of the page and a reload that skips the cache
- (void)reloadMenu:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Reload without cache")];
    [sheet addButtonWithTitle:[BRSettings userAgentMode] == 0 ? L(@"Request desktop version") : L(@"Request mobile version")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = 101;
    CGRect rect = [self.view convertRect:self.reloadButton.bounds fromView:self.reloadButton];
    if (BRIsPad()) [sheet showFromRect:rect inView:self.view animated:YES];
    else [sheet showInView:self.view];
}

- (void)reloadIgnoringCache
{
    NSURL *url = self.currentURL ?: self.webView.request.URL;
    if (!url) return;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60]];
}

- (void)reload
{
    if (self.currentURL) [self loadURL:self.currentURL];
    else [self.webView reload];
}

- (void)pullToRefresh
{
    [self reload];
    [self.refreshControl performSelector:@selector(endRefreshing) withObject:nil afterDelay:0.8];
}

- (void)stop
{
    [self.webView stopLoading];
    self.loadCount = 0;
    [self setLoading:NO];
}

- (NSString *)evaluateJavaScript:(NSString *)code
{
    if (!code.length) return @"";
    return [self.webView stringByEvaluatingJavaScriptFromString:code] ?: @"";
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
    if (self.loading) [self.webView stopLoading];   // a page still loading must not steal the tab with a late redirect
    self.currentURL = url;
    [self updateAddressFieldWithURL:url];
    if (self.currentTab < self.tabs.count) {
        // show the new host in the tab strip right away; the title follows when the page has loaded
        NSMutableDictionary *tab = self.tabs[self.currentTab];
        NSString *oldHost = [[NSURL URLWithString:tab[@"url"] ?: @""].host lowercaseString];
        if (![oldHost isEqualToString:[url.host lowercaseString]]) tab[@"title"] = @"";
        tab[@"url"] = [BRSettings isHomeURL:url] ? @"" : (url.absoluteString ?: @"");
        [self updateTabsButton];
    }
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
    [BRWatchdog setPageLoading:loading];
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
    if (textField == self.findField) {
        [self findNext];
        return YES;
    }
    NSString *text = textField.text;
    [textField resignFirstResponder];
    [self navigateToTypedText:text];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    if (textField != self.urlField) return;
    self.editingAddress = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (textField.isFirstResponder) [textField selectAll:nil];
    });
    [self showSuggestionsForText:@""];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    if (textField == self.urlField) {
        NSString *current = textField.text ?: @"";
        if (range.location <= current.length && range.location + range.length <= current.length) {
            [self showSuggestionsForText:[current stringByReplacingCharactersInRange:range withString:string ?: @""]];
        }
    }
    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField
{
    if (textField == self.urlField) [self showSuggestionsForText:@""];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField != self.urlField) return;
    self.editingAddress = NO;
    [self hideSuggestions];
    [self updateAddressFieldWithURL:self.webView.request.URL ?: self.currentURL];
}

#pragma mark - UIWebViewDelegate

#pragma mark - Loading progress, padlock, text size

- (CGFloat)currentProgress
{
    return self.progressView.hidden ? 0 : self.progressView.tag / 1000.0;
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated
{
    progress = MAX(0, MIN(1, progress));
    self.progressView.tag = (NSInteger)(progress * 1000);
    self.progressView.hidden = NO;
    CGRect frame = CGRectMake(0, 0, floor(self.urlField.bounds.size.width * progress), self.urlField.bounds.size.height);
    if (animated) [UIView animateWithDuration:0.25 animations:^{ self.progressView.frame = frame; }];
    else self.progressView.frame = frame;
    if (progress >= 1) {
        [UIView animateWithDuration:0.4 delay:0.2 options:0 animations:^{ self.progressView.alpha = 0; } completion:^(BOOL finished) {
            if (self.progressView.tag >= 1000) { self.progressView.hidden = YES; self.progressView.alpha = 1; self.progressView.frame = CGRectMake(0, 0, 0, self.urlField.bounds.size.height); }
        }];
    } else {
        self.progressView.alpha = 1;
    }
}

- (void)pageProgress:(NSNotification *)note
{
    if (!self.loading) return;
    NSUInteger started = [note.userInfo[@"started"] unsignedIntegerValue], finished = [note.userInfo[@"finished"] unsignedIntegerValue];
    CGFloat p = started ? 0.1 + 0.8 * (CGFloat)finished / (CGFloat)started : 0.1;
    if (p > [self currentProgress]) [self setProgress:p animated:YES];
}

- (void)updateLockIcon
{
    NSURL *url = self.webView.request.URL ?: self.currentURL;
    BOOL secure = [[url.scheme lowercaseString] isEqualToString:@"https"] && [[BRURLProtocol lastMainDocumentTLSInfo] length] > 0;
    if (secure) {
        if (self.urlField.leftView != self.lockButton) self.urlField.leftView = self.lockButton;
    } else if (self.urlField.leftView != self.fieldLeftView) {
        self.urlField.leftView = self.fieldLeftView;
    }
}

- (void)showConnectionInfo
{
    NSString *tls = [BRURLProtocol lastMainDocumentTLSInfo] ?: @"";
    NSString *host = ([BRURLProtocol lastMainDocumentURL] ?: self.currentURL).host ?: @"";
    NSString *verified = [BRSettings verifyTLS] ? L(@"Certificate verified.") : L(@"Certificate not verified (switched off in Settings).");
    NSString *message = [NSString stringWithFormat:@"%@\n%@\n%@", host, tls, verified];
    [[[UIAlertView alloc] initWithTitle:L(@"Secure connection") message:message delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
}

- (void)applyTextSize
{
    NSInteger percent = [BRSettings textSizePercent];
    NSString *js = [NSString stringWithFormat:
        @"(function(p){var s=document.getElementById('br-textsize');if(p===100){if(s)s.parentNode.removeChild(s);return;}"
         "if(!s){s=document.createElement('style');s.id='br-textsize';(document.head||document.documentElement).appendChild(s);}"
         "s.textContent='html,body,body *{-webkit-text-size-adjust:'+p+'%% !important}';})(%ld)", (long)percent];
    [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (void)textSizeChanged:(NSNotification *)note
{
    [self applyTextSize];
}

- (void)privateModeChanged:(NSNotification *)note
{
    BOOL priv = [BRSettings privateMode];
    self.urlField.placeholder = priv ? L(@"Private browsing: search or enter address") : L(@"Search or enter address");
    self.urlField.textColor = priv ? [UIColor colorWithRed:0.45 green:0.2 blue:0.6 alpha:1] : [[BRTheme shared] fieldTextColor];
}

#pragma mark - Search suggestions from the search engine

- (void)fetchSearchSuggestionsForText:(NSString *)text
{
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2 || [BRSettings privateMode]) return;
    NSString *q = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)t, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    NSURL *url = [NSURL URLWithString:[@"https://duckduckgo.com/ac/?type=list&q=" stringByAppendingString:q ?: @""]];
    BRHTTPRequest *r = [[BRHTTPRequest alloc] initWithMethod:@"GET" URL:url];
    r.verifyTLS = [BRSettings verifyTLS];
    r.highPriority = YES;
    r.connectTimeout = 5;
    r.readTimeout = 5;
    r.headers = @{ @"Accept": @"application/json" };
    __weak BRBrowserViewController *weakSelf = self;
    r.onComplete = ^(NSError *error) {
        if (error || r.statusCode != 200) return;
        id json = r.responseBody ? [NSJSONSerialization JSONObjectWithData:r.responseBody options:0 error:NULL] : nil;
        NSArray *list = [json isKindOfClass:[NSArray class]] && [json count] > 1 && [json[1] isKindOfClass:[NSArray class]] ? json[1] : nil;
        if (!list.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            BRBrowserViewController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.editingAddress || ![[strongSelf.urlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:t]) return;
            NSMutableArray *rows = [strongSelf.suggestions mutableCopy] ?: [NSMutableArray array];
            NSUInteger insertAt = rows.count && [rows[0][@"kind"] hasPrefix:@"search"] ? 1 : 0;
            NSInteger added = 0;
            for (id s in list) {
                if (![s isKindOfClass:[NSString class]] || [s isEqualToString:t] || added >= 4) continue;
                [rows insertObject:@{ @"title": s, @"url": [BRSettings searchURLForQuery:s].absoluteString ?: @"", @"kind": @"search" } atIndex:insertAt + (NSUInteger)added];
                added++;
            }
            if (!added) return;
            strongSelf.suggestions = rows;
            [strongSelf.suggestionsTable reloadData];
        });
    };
    [r start];
}

#pragma mark - Home page

// Hands the start page its data: search engine, bookmarks and the most visited hosts from the history.
- (void)populateHomePage
{
    BRLibrary *lib = [BRLibrary shared];
    NSMutableDictionary *byHost = [NSMutableDictionary dictionary];
    for (NSDictionary *e in lib.history) {
        NSURL *u = [NSURL URLWithString:[e[@"url"] isKindOfClass:[NSString class]] ? e[@"url"] : @""];
        NSString *host = [u.host lowercaseString];
        if (!host.length) continue;
        if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
        NSMutableDictionary *entry = byHost[host];
        if (!entry) {
            NSString *scheme = [u.scheme lowercaseString] ?: @"https";
            entry = [@{ @"url": [NSString stringWithFormat:@"%@://%@/", scheme, u.host], @"title": [e[@"title"] isKindOfClass:[NSString class]] && [e[@"title"] length] ? e[@"title"] : host,
                        @"count": @0 } mutableCopy];
            // the newest visit of the host's front page gives the nicest title
            if ([u.path length] <= 1 && [e[@"title"] length]) entry[@"title"] = e[@"title"];
            byHost[host] = entry;
        }
        entry[@"count"] = @([entry[@"count"] integerValue] + 1);
    }
    NSArray *top = [byHost.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"count"] compare:a[@"count"]]; }];
    if (top.count > 8) top = [top subarrayWithRange:NSMakeRange(0, 8)];
    NSMutableArray *bookmarks = [NSMutableArray array];
    for (NSDictionary *b in lib.bookmarks) {
        if (bookmarks.count >= 12) break;
        [bookmarks addObject:@{ @"url": b[@"url"] ?: @"", @"title": b[@"title"] ?: @"" }];
    }
    NSURL *searchURL = [BRSettings searchURLForQuery:@""];
    NSString *action = searchURL.absoluteString ?: @"";
    NSRange q = [action rangeOfString:@"?"];
    if (q.location != NSNotFound) action = [action substringToIndex:q.location];
    NSDictionary *data = @{ @"dark": @([BRTheme shared].isDark), @"searchAction": action, @"searchName": [BRSettings searchEngineTitle:[BRSettings searchEngine]],
                            @"top": top, @"bookmarks": bookmarks };
    NSData *json = [NSJSONSerialization dataWithJSONObject:data options:0 error:NULL];
    if (!json) return;
    NSString *js = [NSString stringWithFormat:@"window.brSetHome && window.brSetHome(%@)", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [self.webView stringByEvaluatingJavaScriptFromString:js];
}

#pragma mark - Address suggestions

- (NSArray *)suggestionsForText:(NSString *)text
{
    NSString *t = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSMutableArray *out = [NSMutableArray array];
    BRLibrary *lib = [BRLibrary shared];
    if (!t.length) {
        for (NSDictionary *b in lib.bookmarks) {
            if (out.count >= 8) break;
            [out addObject:@{ @"title": b[@"title"] ?: @"", @"url": b[@"url"] ?: @"", @"kind": @"bookmark" }];
        }
        return out;
    }
    BOOL looksLikeURL = [t rangeOfString:@" "].location == NSNotFound && ([t rangeOfString:@"."].location != NSNotFound || [t rangeOfString:@"://"].location != NSNotFound);
    [out addObject:@{ @"title": [NSString stringWithFormat:L(@"Search %@ for “%@”"), [BRSettings searchEngineTitle:[BRSettings searchEngine]], text],
                      @"url": [BRSettings searchURLForQuery:text].absoluteString ?: @"", @"kind": looksLikeURL ? @"search-secondary" : @"search" }];
    NSMutableArray *scored = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *sources = @[lib.bookmarks, lib.history];
    for (NSUInteger s = 0; s < sources.count; s++) {
        for (NSDictionary *e in sources[s]) {
            NSString *url = [e[@"url"] isKindOfClass:[NSString class]] ? e[@"url"] : @"";
            NSString *title = [e[@"title"] isKindOfClass:[NSString class]] ? e[@"title"] : @"";
            if (!url.length || [seen containsObject:url]) continue;
            NSString *lurl = [url lowercaseString];
            NSString *bare = lurl;
            NSRange scheme = [bare rangeOfString:@"://"];
            if (scheme.location != NSNotFound) bare = [bare substringFromIndex:scheme.location + 3];
            if ([bare hasPrefix:@"www."]) bare = [bare substringFromIndex:4];
            NSInteger score;
            if ([bare hasPrefix:t]) score = 0;
            else if ([lurl rangeOfString:t].location != NSNotFound) score = 1;
            else if ([[title lowercaseString] rangeOfString:t].location != NSNotFound) score = 2;
            else continue;
            [seen addObject:url];
            [scored addObject:@{ @"title": title, @"url": url, @"kind": s == 0 ? @"bookmark" : @"history", @"score": @(score + (NSInteger)s) }];
            if (scored.count >= 40) break;
        }
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"score"] compare:b[@"score"]]; }];
    for (NSDictionary *e in scored) {
        if (out.count >= 8) break;
        [out addObject:e];
    }
    [out addObject:@{ @"title": [NSString stringWithFormat:L(@"Find “%@” on this page"), text], @"url": @"", @"kind": @"find", @"query": text }];
    return out;
}

- (void)showSuggestionsForText:(NSString *)text
{
    self.suggestions = [self suggestionsForText:text];
    if (!self.suggestions.count) {
        [self hideSuggestions];
        return;
    }
    if (!self.suggestionsTable) {
        self.suggestionsTable = [[UITableView alloc] initWithFrame:self.webView.frame style:UITableViewStylePlain];
        self.suggestionsTable.dataSource = self;
        self.suggestionsTable.delegate = self;
        self.suggestionsTable.rowHeight = 50;
        [self.view insertSubview:self.suggestionsTable aboveSubview:self.webView];
        [self applyTheme];
    }
    self.suggestionsTable.hidden = NO;
    [self.view setNeedsLayout];
    [self.suggestionsTable reloadData];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchSearchSuggestionsForText:) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchSearchSuggestionsForText:) object:self.pendingSuggestionText];
    self.pendingSuggestionText = text;
    if (text.length >= 2) [self performSelector:@selector(fetchSearchSuggestionsForText:) withObject:text afterDelay:0.35];
}

- (void)hideSuggestions
{
    self.suggestionsTable.hidden = YES;
    self.suggestions = nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.suggestions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *cellId = @"suggestion";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    NSDictionary *s = self.suggestions[(NSUInteger)indexPath.row];
    NSString *kind = s[@"kind"];
    BRTheme *theme = [BRTheme shared];
    BOOL action = [kind hasPrefix:@"search"] || [kind isEqualToString:@"find"];
    cell.textLabel.text = [s[@"title"] length] ? s[@"title"] : s[@"url"];
    cell.textLabel.font = action ? [UIFont systemFontOfSize:16] : [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.text = action ? nil : s[@"url"];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.backgroundColor = theme.isDark ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor whiteColor];
    cell.textLabel.textColor = action ? (theme.isDark ? [UIColor colorWithRed:0.55 green:0.72 blue:1 alpha:1] : [UIColor colorWithRed:0.2 green:0.36 blue:0.7 alpha:1])
                                      : (theme.isDark ? [UIColor colorWithWhite:0.94 alpha:1] : [UIColor blackColor]);
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSDictionary *s = self.suggestions[(NSUInteger)indexPath.row];
    [self.urlField resignFirstResponder];
    if ([s[@"kind"] isEqualToString:@"find"]) {
        [self showFindBarWithText:s[@"query"]];
        return;
    }
    NSURL *url = [NSURL URLWithString:s[@"url"] ?: @""];
    if (url) [self loadURL:url];
}

#pragma mark - Find on page

- (void)applyThemeToFindBar
{
    BRTheme *theme = [BRTheme shared];
    self.findBarBackground.image = [theme barBackgroundImage];
    self.findField.background = [theme fieldBackgroundImage];
    self.findField.textColor = [theme fieldTextColor];
    self.findLabel.textColor = [theme barTextColor];
    self.findLabel.shadowColor = [theme barTextShadowColor];
    [self.findPrevButton setImage:[theme arrowImagePointingLeft:YES enabled:YES] forState:UIControlStateNormal];
    [self.findNextButton setImage:[theme arrowImagePointingLeft:NO enabled:YES] forState:UIControlStateNormal];
    [self.findDoneButton setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.findDoneButton setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [self.findDoneButton setTitleColor:[theme barTextColor] forState:UIControlStateNormal];
    [self.findDoneButton setTitleShadowColor:[theme barTextShadowColor] forState:UIControlStateNormal];
}

- (void)layoutFindBar
{
    CGFloat width = self.findBar.bounds.size.width, y = (BRBarHeight - BRControlHeight) / 2, gap = 6, margin = 8;
    CGFloat doneWidth = [self widthForTextButton:self.findDoneButton];
    self.findDoneButton.frame = CGRectMake(width - margin - doneWidth, y, doneWidth, BRControlHeight);
    self.findNextButton.frame = CGRectMake(CGRectGetMinX(self.findDoneButton.frame) - gap - 40, y, 40, BRControlHeight);
    self.findPrevButton.frame = CGRectMake(CGRectGetMinX(self.findNextButton.frame) - gap - 40, y, 40, BRControlHeight);
    CGFloat labelWidth = BRIsPad() ? 130 : 90;
    self.findLabel.frame = CGRectMake(CGRectGetMinX(self.findPrevButton.frame) - gap - labelWidth, y, labelWidth, BRControlHeight);
    CGFloat fieldWidth = CGRectGetMinX(self.findLabel.frame) - gap - margin;
    self.findField.frame = CGRectMake(margin, y, MAX(80, fieldWidth), BRControlHeight);
}

- (void)showFindBarWithText:(NSString *)text
{
    if (!self.findBar) {
        self.findBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, BRBarHeight)];
        self.findBarBackground = [[UIImageView alloc] initWithFrame:self.findBar.bounds];
        self.findBarBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.findBar addSubview:self.findBarBackground];
        self.findField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, BRControlHeight)];
        self.findField.borderStyle = UITextBorderStyleNone;
        self.findField.font = [UIFont systemFontOfSize:15];
        self.findField.placeholder = L(@"Find on page");
        self.findField.returnKeyType = UIReturnKeySearch;
        self.findField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.findField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.findField.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.findField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        self.findField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, BRControlHeight)];
        self.findField.leftViewMode = UITextFieldViewModeAlways;
        self.findField.delegate = self;
        [self.findField addTarget:self action:@selector(findTextChanged) forControlEvents:UIControlEventEditingChanged];
        [self.findBar addSubview:self.findField];
        self.findLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.findLabel.font = [UIFont boldSystemFontOfSize:13];
        self.findLabel.backgroundColor = [UIColor clearColor];
        self.findLabel.textAlignment = NSTextAlignmentRight;
        self.findLabel.shadowOffset = CGSizeMake(0, 1);
        [self.findBar addSubview:self.findLabel];
        self.findPrevButton = [self iconButtonWithAction:@selector(findPrevious)];
        self.findNextButton = [self iconButtonWithAction:@selector(findNext)];
        self.findDoneButton = [self textButtonWithTitle:L(@"Done") action:@selector(hideFindBar)];
        [self.findBar addSubview:self.findPrevButton];
        [self.findBar addSubview:self.findNextButton];
        [self.findBar addSubview:self.findDoneButton];
        [self.view addSubview:self.findBar];
        [self applyThemeToFindBar];
    }
    self.findBar.hidden = NO;
    self.findField.text = text ?: @"";
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self findTextChanged];
    if (!text.length) [self.findField becomeFirstResponder];
}

- (void)hideFindBar
{
    [self.findField resignFirstResponder];
    self.findBar.hidden = YES;
    [self.webView stringByEvaluatingJavaScriptFromString:@"window.getSelection().removeAllRanges()"];
    [self.view setNeedsLayout];
}

- (NSString *)jsStringLiteral:(NSString *)s
{
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:NULL];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"[\"\"]";
    return [json substringWithRange:NSMakeRange(1, json.length - 2)];   // strip the array brackets
}

- (void)findTextChanged
{
    NSString *q = self.findField.text ?: @"";
    if (!q.length) {
        self.findLabel.text = @"";
        [self.webView stringByEvaluatingJavaScriptFromString:@"window.getSelection().removeAllRanges()"];
        return;
    }
    NSString *js = [NSString stringWithFormat:
        @"(function(q){var t=(document.body?document.body.innerText:'').toLowerCase();var n=0,i=0;q=q.toLowerCase();"
         "while(q&&(i=t.indexOf(q,i))>=0){n++;i+=q.length;}window.getSelection().removeAllRanges();"
         "if(n)window.find(q,false,false,true,false,true,false);return n;})(%@)", [self jsStringLiteral:q]];
    NSInteger n = [[self.webView stringByEvaluatingJavaScriptFromString:js] integerValue];
    self.findLabel.text = n ? [NSString stringWithFormat:L(@"%ld matches"), (long)n] : L(@"No matches");
}

- (void)findStep:(BOOL)backwards
{
    NSString *q = self.findField.text ?: @"";
    if (!q.length) return;
    NSString *js = [NSString stringWithFormat:@"window.find(%@,false,%@,true,false,true,false)", [self jsStringLiteral:q], backwards ? @"true" : @"false"];
    [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (void)findNext { [self findStep:NO]; }
- (void)findPrevious { [self findStep:YES]; }

#pragma mark - Downloads

- (void)startDownload:(NSURL *)url
{
    if ([[BRDownloader shared] isDownloading:url]) return;
    [[[UIAlertView alloc] initWithTitle:nil message:[NSString stringWithFormat:L(@"Downloading %@"), [url.lastPathComponent length] > 1 ? url.lastPathComponent : url.host]
                               delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
    [[BRDownloader shared] downloadURL:url completion:^(NSString *path, NSError *error) {
        if (error) {
            [[[UIAlertView alloc] initWithTitle:nil message:[NSString stringWithFormat:L(@"Download failed: %@"), error.localizedDescription] delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
            return;
        }
        long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize];
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:nil message:[NSString stringWithFormat:L(@"Downloaded %@ (%@)"), path.lastPathComponent, [BRDownloader formattedSize:size]]
                                                       delegate:self cancelButtonTitle:L(@"OK") otherButtonTitles:L(@"Open"), nil];
        alert.tag = 200;
        self.documentController = [UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:path]];
        [alert show];
    }];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 200 && buttonIndex != alertView.cancelButtonIndex && self.documentController) {
        [self openDocumentController];
    }
}

- (void)openDocumentController
{
    self.documentController.delegate = self;
    CGRect rect = self.shareButton.superview ? [self.view convertRect:self.shareButton.frame fromView:self.shareButton.superview] : CGRectMake(20, 20, 1, 1);
    if (![self.documentController presentOpenInMenuFromRect:rect inView:self.view animated:YES]) {
        [self.documentController presentOptionsMenuFromRect:rect inView:self.view animated:YES];
    }
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller
{
    return self;
}

- (void)libraryViewController:(BRLibraryViewController *)controller didSelectDownloadAtPath:(NSString *)path
{
    self.documentController = [UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:path]];
    self.documentController.delegate = self;
    CGRect rect = self.shareButton.superview ? [self.view convertRect:self.shareButton.frame fromView:self.shareButton.superview] : CGRectMake(20, 20, 1, 1);
    if (![self.documentController presentPreviewAnimated:YES]) [self.documentController presentOptionsMenuFromRect:rect inView:self.view animated:YES];
}

#pragma mark - Sharing and link menu

#pragma mark - Reader

// Shows the current page's article in a clean, light layout (reader.js finds the main content).
- (void)showReader
{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"reader" ofType:@"js"];
    NSString *script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!script.length) return;
    NSString *json = [self.webView stringByEvaluatingJavaScriptFromString:script];
    NSDictionary *article = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (![article isKindOfClass:[NSDictionary class]] || ![article[@"html"] length]) {
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"No article was found on this page.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    BOOL dark = [BRTheme shared].isDark;
    NSURL *pageURL = [NSURL URLWithString:[article[@"url"] isKindOfClass:[NSString class]] ? article[@"url"] : @""] ?: self.currentURL;
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"];
    [html appendFormat:@"<title>%@</title>", BRHTMLEscape(article[@"title"] ?: @"")];
    [html appendFormat:@"<style>body{font-family:Georgia,'Times New Roman',serif;font-size:19px;line-height:1.55;margin:0;padding:24px 20px 60px;background:%@;color:%@;-webkit-text-size-adjust:100%%}"
                        ".wrap{max-width:680px;margin:0 auto}h1{font-family:'Helvetica Neue',Helvetica,sans-serif;font-size:30px;line-height:1.2;margin:0 0 8px}"
                        ".meta{font-family:'Helvetica Neue',Helvetica,sans-serif;font-size:13px;color:#888;margin-bottom:24px}.meta a{color:#888}"
                        "img{max-width:100%%;height:auto;display:block;margin:16px auto}figure{margin:16px 0}figcaption,small{font-size:14px;color:#888}"
                        "p{margin:0 0 1em}h2,h3,h4{font-family:'Helvetica Neue',Helvetica,sans-serif;line-height:1.25;margin:1.4em 0 0.5em}a{color:%@}"
                        "blockquote{margin:1em 0;padding-left:16px;border-left:3px solid #ccc;color:#666}pre,code{font-family:Menlo,Courier,monospace;font-size:14px;white-space:pre-wrap}"
                        "table{border-collapse:collapse;font-size:15px}td,th{border:1px solid #ccc;padding:4px 8px}ul,ol{padding-left:24px}</style></head><body><div class=\"wrap\">",
                        dark ? @"#1c1c1e" : @"#fbf8f2", dark ? @"#e6e6e6" : @"#222", dark ? @"#8ab4f8" : @"#1a5db0"];
    [html appendFormat:@"<h1>%@</h1>", BRHTMLEscape(article[@"title"] ?: @"")];
    [html appendFormat:@"<div class=\"meta\">%@%@<a href=\"%@\">%@</a></div>", BRHTMLEscape(article[@"byline"] ?: @""), [article[@"byline"] length] ? @" · " : @"",
                        BRHTMLEscape(pageURL.absoluteString ?: @""), BRHTMLEscape(pageURL.host ?: @"")];
    [html appendString:article[@"html"]];
    [html appendString:@"</div></body></html>"];
    [self.webView loadHTMLString:html baseURL:pageURL];
    BRLog(@"Reader: %@ (%lu chars)", article[@"title"], (unsigned long)[article[@"html"] length]);
}

- (void)shareItems:(NSArray *)items fromRect:(CGRect)rect inView:(UIView *)view
{
    if (!items.count) return;
    BRReaderActivity *reader = [[BRReaderActivity alloc] init];
    __weak BRBrowserViewController *weakSelf = self;
    BOOL onPage = NO;
    for (id item in items) if ([item isKindOfClass:[NSURL class]] && [[item absoluteString] isEqualToString:(self.webView.request.URL ?: self.currentURL).absoluteString]) onPage = YES;
    if (onPage) reader.action = ^{ [weakSelf showReader]; };
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:@[[[BRBookmarkActivity alloc] init], reader]];
    if (BRIsPad()) {
        [self.sharePopover dismissPopoverAnimated:NO];
        self.sharePopover = [[UIPopoverController alloc] initWithContentViewController:activity];
        [self.sharePopover presentPopoverFromRect:rect inView:view ?: self.view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [self presentViewController:activity animated:YES completion:nil];
    }
}

- (void)shareURL:(NSURL *)url title:(NSString *)title fromRect:(CGRect)rect inView:(UIView *)view
{
    if (!url) return;
    NSMutableArray *items = [NSMutableArray array];
    if (title.length) [items addObject:title];
    [items addObject:url];
    [self shareItems:items fromRect:rect inView:view];
}

- (void)shareCurrentPage
{
    NSURL *url = self.webView.request.URL ?: self.currentURL;
    if (!url || ![[url.scheme lowercaseString] hasPrefix:@"http"]) return;
    [self shareURL:url title:self.currentTitle fromRect:self.shareButton.frame inView:self.shareButton.superview];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
    return YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer
{
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [recognizer locationInView:self.webView];
    CGFloat scale = self.webView.scrollView.zoomScale;
    if (scale <= 0) scale = 1;
    NSString *js = [NSString stringWithFormat:
        @"(function(x,y){var el=document.elementFromPoint(x,y);var a=el,img=null;"
         "while(a&&a.nodeType===1){if(!img&&a.tagName==='IMG')img=a;if(a.tagName==='A'&&a.href)break;a=a.parentNode;}"
         "if(!(a&&a.nodeType===1&&a.tagName==='A'))a=null;"
         "return JSON.stringify({href:a?a.href:'',text:a?(a.textContent||'').replace(/\\s+/g,' ').replace(/^ | $/g,'').slice(0,80):'',img:img?(img.currentSrc||img.src||''):''});})(%ld,%ld)",
        (long)(p.x / scale), (long)(p.y / scale)];
    NSString *json = [self.webView stringByEvaluatingJavaScriptFromString:js];
    NSDictionary *info = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (![info isKindOfClass:[NSDictionary class]]) return;
    NSString *href = [info[@"href"] isKindOfClass:[NSString class]] ? info[@"href"] : @"";
    NSString *img = [info[@"img"] isKindOfClass:[NSString class]] ? info[@"img"] : @"";
    if (![href hasPrefix:@"http"]) href = @"";
    if (![img hasPrefix:@"http"] && ![img hasPrefix:@"data:"]) img = @"";
    if (!href.length && !img.length) return;
    self.pressedLink = @{ @"href": href, @"img": img, @"text": [info[@"text"] isKindOfClass:[NSString class]] ? info[@"text"] : @"" };
    NSString *title = href.length ? href : img;
    if (title.length > 120) title = [[title substringToIndex:117] stringByAppendingString:@"..."];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    if (href.length) {
        [sheet addButtonWithTitle:L(@"Open")];
        [sheet addButtonWithTitle:L(@"Open in new tab")];
        [sheet addButtonWithTitle:L(@"Copy link")];
        [sheet addButtonWithTitle:L(@"Share link")];
        [sheet addButtonWithTitle:L(@"Open in Safari")];
    }
    if (img.length) {
        [sheet addButtonWithTitle:L(@"Open image")];
        [sheet addButtonWithTitle:L(@"Copy image address")];
        [sheet addButtonWithTitle:L(@"Save image")];
    }
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = 100;
    if (BRIsPad()) [sheet showFromRect:CGRectMake(p.x, p.y, 1, 1) inView:self.webView animated:YES];
    else [sheet showInView:self.view];
}

- (void)saveImageAtURL:(NSURL *)url
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:url];   // goes through BRURLProtocol (WebP is converted there)
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image) UIImageWriteToSavedPhotosAlbum(image, nil, NULL, NULL);
            else BRLog(@"Save image failed: %@ (%lu bytes)", url.absoluteString, (unsigned long)data.length);
        });
    });
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index
{
    if (index < 0 || index == sheet.cancelButtonIndex) return;
    if (sheet.tag == 102) {
        [self handleTabMenuChoice:[sheet buttonTitleAtIndex:index]];
        return;
    }
    if (sheet.tag == 101) {
        NSString *pick = [sheet buttonTitleAtIndex:index];
        if ([pick isEqualToString:L(@"Reload without cache")]) {
            [self reloadIgnoringCache];
        } else {
            [BRSettings setUserAgentMode:[BRSettings userAgentMode] == 0 ? 1 : 0];
            [[NSURLCache sharedURLCache] removeAllCachedResponses];
            [self reloadIgnoringCache];
        }
        return;
    }
    if (sheet.tag != 100) return;
    NSString *choice = [sheet buttonTitleAtIndex:index];
    NSString *href = self.pressedLink[@"href"], *img = self.pressedLink[@"img"], *text = self.pressedLink[@"text"];
    NSURL *link = href.length ? [NSURL URLWithString:href] : nil;
    NSURL *image = img.length ? [NSURL URLWithString:img] : nil;
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    if ([choice isEqualToString:L(@"Open")] && link) [self loadURL:link];
    else if ([choice isEqualToString:L(@"Open in new tab")] && link) [self openURLInNewTab:link];
    else if ([choice isEqualToString:L(@"Copy link")] && link) { pasteboard.string = href; }
    else if ([choice isEqualToString:L(@"Share link")] && link) [self shareURL:link title:text fromRect:self.shareButton.frame inView:self.shareButton.superview];
    else if ([choice isEqualToString:L(@"Open in Safari")] && link) [[UIApplication sharedApplication] openURL:link];
    else if ([choice isEqualToString:L(@"Open image")] && image) [self loadURL:image];
    else if ([choice isEqualToString:L(@"Copy image address")] && image) { pasteboard.string = img; }
    else if ([choice isEqualToString:L(@"Save image")] && image) [self saveImageAtURL:image];
    self.pressedLink = nil;
}

// window.open() and target="_blank" links arrive from shims-extra.js as brtab:<percent-encoded URL>
- (void)openURLInNewTab:(NSURL *)url
{
    if (!url) return;
    if (self.tabs.count >= 12) {
        [self loadURL:url];
        return;
    }
    [self storeCurrentTabState];
    [self.tabs addObject:[@{ @"url": url.absoluteString ?: @"", @"title": @"" } mutableCopy]];
    [self openTabAtIndex:self.tabs.count - 1];
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL *url = request.URL;
    NSString *scheme = [url.scheme lowercaseString];
    if ([scheme isEqualToString:@"brtab"]) {
        NSString *spec = url.absoluteString.length > 6 ? [url.absoluteString substringFromIndex:6] : @"";
        NSURL *target = [NSURL URLWithString:[spec stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @""];
        if (target && [[target.scheme lowercaseString] hasPrefix:@"http"]) {
            BRLog(@"New tab requested by the page: %@", target.absoluteString);
            [self openURLInNewTab:target];
        }
        return NO;
    }
    if ([scheme isEqualToString:@"brlog"]) {
        NSString *spec = url.absoluteString.length > 6 ? [url.absoluteString substringFromIndex:6] : @"";
        BRLog(@"Page: %@", [spec stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: spec);
        return NO;
    }
    if ([scheme isEqualToString:@"brshare"]) {
        // navigator.share() from shims-extra.js: brshare:<percent-encoded JSON {title, text, url}>
        NSString *spec = url.absoluteString.length > 8 ? [url.absoluteString substringFromIndex:8] : @"";
        NSData *data = [[spec stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([info isKindOfClass:[NSDictionary class]]) {
            NSString *urlString = [info[@"url"] isKindOfClass:[NSString class]] ? info[@"url"] : @"";
            NSString *text = [info[@"text"] isKindOfClass:[NSString class]] && [info[@"text"] length] ? info[@"text"] : ([info[@"title"] isKindOfClass:[NSString class]] ? info[@"title"] : @"");
            NSURL *shared = urlString.length ? [NSURL URLWithString:urlString] : nil;
            CGRect rect = CGRectMake(self.webView.bounds.size.width / 2, 40, 1, 1);
            if (shared) [self shareURL:shared title:text fromRect:rect inView:self.webView];
            else if (text.length) [self shareItems:@[text] fromRect:rect inView:self.webView];
        }
        return NO;
    }
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
    if (!self.loading) [self setProgress:0.08 animated:NO];
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
        [self setProgress:1 animated:YES];
        [self updateLockIcon];
        [self applyTextSize];
        NSString *title = [webView stringByEvaluatingJavaScriptFromString:@"document.title"] ?: @"";
        self.currentTitle = title;
        if (url && [[url.scheme lowercaseString] hasPrefix:@"http"]) [[BRLibrary shared] recordVisit:url title:title];
        if (self.currentTab < self.tabs.count) {
            NSMutableDictionary *tab = self.tabs[self.currentTab];
            tab[@"url"] = ([BRSettings isHomeURL:url] || !url) ? @"" : (url.absoluteString ?: @"");
            tab[@"title"] = title;
            [self saveTabs];
            [self updateTabsButton];
            if (BRIsPad()) [self fetchFaviconForCurrentPage];
        }
        BRLog(@"Loaded %@ (%@), %lu requests blocked, %lu connections reused, %lu idle, %ld MB", url.absoluteString ?: @"?",
              title.length > 80 ? [title substringToIndex:80] : title, (unsigned long)[BRAdBlock blockedRequestCount],
              (unsigned long)[BRConnectionPool shared].reuseCount, (unsigned long)[BRConnectionPool shared].idleCount, (long)BRResidentMemoryMB());
        if ([BRSettings isHomeURL:url]) {
            [self populateHomePage];
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
    NSString *failingString = error.userInfo[NSURLErrorFailingURLStringErrorKey];
    NSURL *failingURL = failingString.length ? [NSURL URLWithString:failingString] : error.userInfo[NSURLErrorFailingURLErrorKey];
    if (!failingURL) failingURL = self.currentURL;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) {
        // "Frame load interrupted": WebKit refused to show the response, typically a file to download
        NSString *ctype = [[BRURLProtocol lastMainDocumentContentType] lowercaseString] ?: @"";
        NSURL *last = [BRURLProtocol lastMainDocumentURL];
        BOOL renderable = [ctype hasPrefix:@"text/"] || [ctype hasPrefix:@"image/"] || [ctype hasPrefix:@"video/"] || [ctype hasPrefix:@"audio/"] ||
                          [ctype hasPrefix:@"application/pdf"] || [ctype hasPrefix:@"application/xhtml"] || [ctype hasPrefix:@"application/xml"];
        if ([[failingURL.scheme lowercaseString] hasPrefix:@"http"] && last && [last.absoluteString isEqualToString:failingURL.absoluteString] && !renderable) {
            BRLog(@"Download detected: %@ (%@)", failingURL.absoluteString, ctype);
            [self setProgress:1 animated:NO];
            [self startDownload:failingURL];
        }
        return;
    }
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 204) return;   // plug-in
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
