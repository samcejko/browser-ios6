#import "BRBrowserViewController.h"
#import "BRCommon.h"
#import "BRSettings.h"

static const CGFloat BRBarHeight = 44;

@interface BRBrowserViewController () <UIWebViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UINavigationBar *navBar;
@property (nonatomic, strong) UINavigationItem *navItem;
@property (nonatomic, strong) UIToolbar *toolbar;          // iPhone only
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *backItem;
@property (nonatomic, strong) UIBarButtonItem *forwardItem;
@property (nonatomic, strong) UIBarButtonItem *reloadItem;
@property (nonatomic, strong) UIBarButtonItem *stopItem;
@property (nonatomic, strong) UIBarButtonItem *homeItem;
@property (nonatomic, strong) NSURL *currentURL;           // last main frame URL that was navigated to
@property (nonatomic, strong) NSURL *httpFallbackURL;      // http:// variant of a typed host, tried when https fails
@property (nonatomic) BOOL editingAddress;
@property (nonatomic) NSInteger loadCount;
@end

@implementation BRBrowserViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];

    self.webView = [[UIWebView alloc] initWithFrame:self.view.bounds];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = YES;
    self.webView.dataDetectorTypes = UIDataDetectorTypeNone;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.webView];

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 600, 31)];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.font = [UIFont systemFontOfSize:15];
    self.urlField.placeholder = L(@"Search or enter address");
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.returnKeyType = UIReturnKeyGo;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.urlField.enablesReturnKeyAutomatically = YES;
    self.urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.urlField.delegate = self;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.urlField.rightView = self.spinner;
    self.urlField.rightViewMode = UITextFieldViewModeUnlessEditing;

    self.backItem = [[UIBarButtonItem alloc] initWithTitle:@"◀" style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    self.forwardItem = [[UIBarButtonItem alloc] initWithTitle:@"▶" style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
    self.reloadItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];
    self.stopItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(stop)];
    self.homeItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Home") style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];

    UIColor *barTint = [UIColor colorWithRed:0.56 green:0.59 blue:0.64 alpha:1];
    self.navBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, BRBarHeight)];
    self.navBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.navBar.tintColor = barTint;
    self.navItem = [[UINavigationItem alloc] initWithTitle:@""];
    self.navItem.titleView = self.urlField;
    if (BRIsPad()) {
        self.navItem.leftBarButtonItems = @[self.backItem, self.forwardItem];
        self.navItem.rightBarButtonItems = @[self.homeItem, self.reloadItem];
    } else {
        self.navItem.rightBarButtonItem = self.reloadItem;
    }
    [self.navBar pushNavigationItem:self.navItem animated:NO];
    [self.view addSubview:self.navBar];

    if (!BRIsPad()) {
        self.toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - BRBarHeight, self.view.bounds.size.width, BRBarHeight)];
        self.toolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        self.toolbar.tintColor = barTint;
        UIBarButtonItem *flex1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem *flex2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        self.toolbar.items = @[self.backItem, flex1, self.forwardItem, flex2, self.homeItem];
        [self.view addSubview:self.toolbar];
    }

    [self updateNavigationState];
    [self goHome];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat bottom = self.toolbar ? BRBarHeight : 0;
    self.navBar.frame = CGRectMake(0, 0, b.size.width, BRBarHeight);
    if (self.toolbar) self.toolbar.frame = CGRectMake(0, b.size.height - bottom, b.size.width, bottom);
    self.webView.frame = CGRectMake(0, BRBarHeight, b.size.width, b.size.height - BRBarHeight - bottom);
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

#pragma mark - Actions

- (void)goBack
{
    [self.webView goBack];
}

- (void)goForward
{
    [self.webView goForward];
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

#pragma mark - State

- (void)setLoading:(BOOL)loading
{
    [UIApplication sharedApplication].networkActivityIndicatorVisible = loading;
    if (loading) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
    UIBarButtonItem *item = loading ? self.stopItem : self.reloadItem;
    if (BRIsPad()) self.navItem.rightBarButtonItems = @[self.homeItem, item];
    else self.navItem.rightBarButtonItem = item;
}

- (void)updateNavigationState
{
    self.backItem.enabled = self.webView.canGoBack;
    self.forwardItem.enabled = self.webView.canGoForward;
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
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"];
    [html appendFormat:@"<title>%@</title>", BRHTMLEscape(L(@"Page could not be loaded"))];
    [html appendString:@"<style>body{font-family:Helvetica,Arial,sans-serif;background:#f2f2f5;color:#333;margin:0;padding:24px}"
                        "h1{font-size:22px;margin:0 0 12px}p{font-size:15px;line-height:1.4}.url{word-break:break-all;color:#777;font-size:13px}"
                        "a.btn{display:inline-block;margin:8px 8px 0 0;padding:10px 16px;background:#4a90e2;color:#fff;text-decoration:none;border-radius:6px;font-size:15px}"
                        "</style></head><body>"];
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
    if (self.loadCount == 0) self.httpFallbackURL = nil;
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
