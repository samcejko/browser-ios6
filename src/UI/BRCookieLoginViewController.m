#import "BRCookieLoginViewController.h"
#import "BRTheme.h"
#import "BRCommon.h"
#import <QuartzCore/QuartzCore.h>

@interface BRCookieLoginViewController ()
@property (nonatomic, copy) NSString *host;
@property (nonatomic) BOOL secure;
@property (nonatomic, strong) UILabel *instructionLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic) CGFloat keyboardHeight;
@end

@implementation BRCookieLoginViewController

- (instancetype)initWithHost:(NSString *)host secure:(BOOL)secure
{
    self = [super init];
    if (self) {
        _host = [[host lowercaseString] copy];
        _secure = secure;
        self.title = L(@"Log in with cookies");
    }
    return self;
}

// The registrable domain (last two labels) with a leading dot, so one paste covers the site and its subdomains
// (www.furaffinity.net and d.furaffinity.net both match ".furaffinity.net"). Naive like BRSameSite in BRURLProtocol;
// good enough for the usual two-label TLDs. An IP address or a single-label host is used as-is.
static NSString *BRCookieDomainForHost(NSString *host)
{
    host = [[host lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!host.length) return nil;
    NSArray *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2) return host;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([[labels lastObject] rangeOfCharacterFromSet:nonDigits].location == NSNotFound) return host;  // IPv4
    NSString *reg = [NSString stringWithFormat:@"%@.%@", labels[labels.count - 2], labels[labels.count - 1]];
    return [@"." stringByAppendingString:reg];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    BOOL dark = [BRTheme shared].isDark;
    self.view.backgroundColor = dark ? [UIColor colorWithWhite:0.11 alpha:1] : [UIColor colorWithWhite:0.94 alpha:1];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Cancel") style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Log in") style:UIBarButtonItemStyleDone target:self action:@selector(logIn)];

    self.instructionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.instructionLabel.numberOfLines = 0;
    self.instructionLabel.backgroundColor = [UIColor clearColor];
    self.instructionLabel.font = [UIFont systemFontOfSize:14];
    self.instructionLabel.textColor = dark ? [UIColor colorWithWhite:0.72 alpha:1] : [UIColor colorWithWhite:0.3 alpha:1];
    self.instructionLabel.text = [NSString stringWithFormat:L(@"If a site's login needs a CAPTCHA this engine can't show, log in to it in another browser, then paste that site's cookies below. Surfari keeps you signed in to %@.\n\nExample:  a=VALUE; b=VALUE"), self.host ?: @""];
    [self.view addSubview:self.instructionLabel];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.font = [UIFont fontWithName:@"Courier" size:14] ?: [UIFont systemFontOfSize:14];
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.spellCheckingType = UITextSpellCheckingTypeNo;
    self.textView.keyboardType = UIKeyboardTypeASCIICapable;
    self.textView.backgroundColor = dark ? [UIColor colorWithWhite:0.17 alpha:1] : [UIColor whiteColor];
    self.textView.textColor = [[BRTheme shared] fieldTextColor];
    self.textView.layer.cornerRadius = 8;
    self.textView.layer.borderWidth = 1;
    self.textView.layer.borderColor = (dark ? [UIColor colorWithWhite:0.3 alpha:1] : [UIColor colorWithWhite:0.8 alpha:1]).CGColor;
    [self.view addSubview:self.textView];

    // The user just copied the cookies in the other browser: if the clipboard holds something that looks like a cookie
    // string (has '=', is not a URL), fill it in so they only have to tap "Log in".
    NSString *clip = [[[UIPasteboard generalPasteboard] string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clip.length && clip.length < 8000 && [clip rangeOfString:@"="].location != NSNotFound) {
        NSString *low = [clip lowercaseString];
        if (![low hasPrefix:@"http://"] && ![low hasPrefix:@"https://"]) self.textView.text = clip;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.textView.text.length) [self.textView becomeFirstResponder];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat margin = 16;
    CGFloat width = self.view.bounds.size.width - 2 * margin;
    if (width <= 0) return;
    CGSize labelSize = [self.instructionLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.instructionLabel.frame = CGRectMake(margin, margin, width, labelSize.height);
    CGFloat top = CGRectGetMaxY(self.instructionLabel.frame) + 12;
    CGFloat bottom = self.view.bounds.size.height - margin - self.keyboardHeight;
    CGFloat height = MAX(80, bottom - top);
    self.textView.frame = CGRectMake(margin, top, width, height);
}

- (void)keyboardWillChange:(NSNotification *)note
{
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    end = [self.view convertRect:end fromView:nil];
    BOOL showing = [note.name isEqualToString:UIKeyboardWillShowNotification];
    self.keyboardHeight = showing ? MAX(0, CGRectGetMaxY(self.view.bounds) - end.origin.y) : 0;
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.25 animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)cancel
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)logIn
{
    NSArray *cookies = [self cookiesFromText:self.textView.text];
    if (cookies.count == 0) {
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"No cookies were found. Paste them as name=value, separated by semicolons.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    @synchronized (BRCookieLock()) {
        for (NSHTTPCookie *cookie in cookies) [jar setCookie:cookie];
    }
    BRLog(@"Stored %lu login cookie(s) for %@", (unsigned long)cookies.count, self.host);
    NSUInteger count = cookies.count;
    void (^callback)(NSUInteger) = self.onStored;
    [self dismissViewControllerAnimated:YES completion:^{ if (callback) callback(count); }];
}

// Parses a pasted cookie string ("a=1; b=2", a whole Cookie: header, or newline-separated name=value lines) into
// cookies for this site. Values may contain '=', so only the first one in each pair splits name from value.
- (NSArray *)cookiesFromText:(NSString *)text
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *domain = BRCookieDomainForHost(self.host);
    NSString *s = [text stringByTrimmingCharactersInSet:ws];
    if (!s.length || !domain.length) return @[];
    if ([[s lowercaseString] hasPrefix:@"cookie:"]) s = [[s substringFromIndex:7] stringByTrimmingCharactersInSet:ws];
    // newlines separate cookies just like semicolons do (some browsers copy one per line)
    s = [[s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\n" withString:@";"];

    NSMutableArray *cookies = [NSMutableArray array];
    NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:365 * 24 * 60 * 60];
    for (NSString *rawPart in [s componentsSeparatedByString:@";"]) {
        NSString *part = [rawPart stringByTrimmingCharactersInSet:ws];
        NSRange eq = [part rangeOfString:@"="];
        if (part.length == 0 || eq.location == NSNotFound || eq.location == 0) continue;
        NSString *name = [[part substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *value = [[part substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        // a cookie name is a single token: a pasted sentence with an '=' in it is not a cookie
        if (name.length == 0 || [name rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) continue;
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        props[NSHTTPCookieName] = name;
        props[NSHTTPCookieValue] = value;
        props[NSHTTPCookieDomain] = domain;
        props[NSHTTPCookiePath] = @"/";
        props[NSHTTPCookieExpires] = expires;
        if (self.secure) props[NSHTTPCookieSecure] = @"TRUE";
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

@end
