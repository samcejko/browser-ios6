#import "BRCookieLoginViewController.h"
#import "BRTheme.h"
#import "BRSettings.h"
#import "BRURLProtocol.h"
#import "BRCommon.h"
#import <QuartzCore/QuartzCore.h>

@interface BRCookieLoginViewController ()
@property (nonatomic, strong) NSURL *pageURL;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) BOOL secure;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *instructionLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic) CGFloat keyboardHeight;
@end

@implementation BRCookieLoginViewController

- (instancetype)initWithPageURL:(NSURL *)page
{
    self = [super init];
    if (self) {
        _pageURL = page;
        _host = [[page.host lowercaseString] copy];
        _secure = [[page.scheme lowercaseString] isEqualToString:@"https"];
        self.title = L(@"Log in with cookies");
    }
    return self;
}

// A two-label name that is a public suffix rather than a site: a country's second level (co.uk, com.au, ne.jp...) or a
// hosting service whose subdomains belong to different people (github.io...). Only asked for www.<that name>.
static BOOL BRLooksLikePublicSuffix(NSString *name)
{
    static NSSet *hosting, *secondLevel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosting = [NSSet setWithObjects:@"github.io", @"gitlab.io", @"herokuapp.com", @"netlify.app", @"vercel.app",
                   @"pages.dev", @"workers.dev", @"web.app", @"firebaseapp.com", @"appspot.com", @"blogspot.com",
                   @"wordpress.com", @"tumblr.com", @"azurewebsites.net", @"cloudfront.net", @"onrender.com", @"glitch.me",
                   @"fly.dev", @"neocities.org", @"surge.sh", nil];
        secondLevel = [NSSet setWithObjects:@"co", @"com", @"net", @"org", @"gov", @"edu", @"ac", @"ne", @"or", @"go",
                       @"gob", @"mil", @"nic", @"ltd", @"plc", @"sch", @"nhs", @"police", nil];
    });
    if ([hosting containsObject:name]) return YES;
    NSArray *labels = [name componentsSeparatedByString:@"."];
    return labels.count == 2 && [labels[1] length] == 2 && [secondLevel containsObject:labels[0]];
}

// Where the imported cookies are stored: the page's host and its subdomains (".host"), a leading "www." dropped so that
// www.example.com and example.com share them, the way a site's own login cookies usually are (".furaffinity.net" covers
// www. and d.furaffinity.net). Never wider: the last two labels would be the public suffix itself for example.co.uk or
// user.github.io, and the session would go to every site under it. An IP address or a one-label host keeps the
// cookies to itself.
static NSString *BRCookieDomainForHost(NSString *host)
{
    host = [[host lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (!host.length) return nil;
    if ([host rangeOfString:@":"].location != NSNotFound) return host;   // IPv6
    NSArray *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2) return host;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([[labels lastObject] rangeOfCharacterFromSet:nonDigits].location == NSNotFound) return host;   // IPv4
    NSString *site = host;
    if (labels.count >= 3 && [labels[0] isEqualToString:@"www"]) {
        NSString *rest = [host substringFromIndex:4];
        if (!(labels.count == 3 && BRLooksLikePublicSuffix(rest))) site = rest;
    }
    return [@"." stringByAppendingString:site];
}

// A cookie name is an HTTP token (RFC 6265): a pasted URL ("example.com/watch?v") or a sentence is not one
static BOOL BRIsCookieName(NSString *name)
{
    static NSCharacterSet *notToken;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notToken = [[NSCharacterSet characterSetWithCharactersInString:
                     @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"] invertedSet];
    });
    return name.length && [name rangeOfCharacterFromSet:notToken].location == NSNotFound;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    BOOL dark = [BRTheme shared].isDark;
    self.view.backgroundColor = dark ? [UIColor colorWithWhite:0.11 alpha:1] : [UIColor colorWithWhite:0.94 alpha:1];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Cancel") style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Log in") style:UIBarButtonItemStyleDone target:self action:@selector(logIn)];

    // (in a scroll view: on a phone with the keyboard up the text box keeps its room and the explanation scrolls away)
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.instructionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.instructionLabel.numberOfLines = 0;
    self.instructionLabel.backgroundColor = [UIColor clearColor];
    self.instructionLabel.font = [UIFont systemFontOfSize:14];
    self.instructionLabel.textColor = dark ? [UIColor colorWithWhite:0.72 alpha:1] : [UIColor colorWithWhite:0.3 alpha:1];
    NSString *text = [NSString stringWithFormat:L(@"If a site's login needs a CAPTCHA this engine can't show, log in to it in another browser, then paste that site's cookies below. Surfari keeps you signed in to %@.\n\nExample:  a=VALUE; b=VALUE"), self.host ?: @""];
    // (the private jar is emptied when private browsing ends: so is this login)
    if ([BRSettings privateMode]) text = [text stringByAppendingFormat:@"\n\n%@", L(@"Private browsing is on: this login lasts until you turn it off.")];
    self.instructionLabel.text = text;
    [self.scrollView addSubview:self.instructionLabel];

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
    // The clipboard is read only when the user asks for it: a page can put text there after a tap (navigator.clipboard),
    // and a box that opened already filled would invite planting someone else's session with one tap on Log in.
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.barStyle = [[BRTheme shared] barStyle];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.items = @[[[UIBarButtonItem alloc] initWithTitle:L(@"Paste") style:UIBarButtonItemStyleBordered target:self action:@selector(pasteClipboard)],
                  [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL]];
    self.textView.inputAccessoryView = bar;
    [self.scrollView addSubview:self.textView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.textView becomeFirstResponder];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.scrollView.frame = bounds;
    CGFloat margin = 16;
    CGFloat width = bounds.size.width - 2 * margin;
    if (width <= 0) return;
    CGSize labelSize = [self.instructionLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.instructionLabel.frame = CGRectMake(margin, margin, width, ceilf(labelSize.height));
    CGFloat top = CGRectGetMaxY(self.instructionLabel.frame) + 12;
    // the text box gets what is left above the keyboard, and never less than a few lines (the label scrolls away then)
    CGFloat visible = bounds.size.height - self.keyboardHeight;
    CGFloat height = MAX(100, visible - top - margin);
    self.textView.frame = CGRectMake(margin, top, width, height);
    self.scrollView.contentSize = CGSizeMake(bounds.size.width, top + height + margin);
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, self.keyboardHeight, 0);
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillChange:(NSNotification *)note
{
    CGRect end = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    BOOL showing = [note.name isEqualToString:UIKeyboardWillShowNotification];
    CGFloat height = CGRectGetHeight(self.view.bounds);
    // (a form sheet on the iPad is mostly above the keyboard: only the part it covers counts)
    self.keyboardHeight = showing ? MIN(height, MAX(0, height - end.origin.y)) : 0;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [self.view setNeedsLayout];
    [UIView animateWithDuration:duration > 0 ? duration : 0.25 animations:^{
        [self.view layoutIfNeeded];
        // the whole text box above the keyboard, the explanation scrolled up as far as that needs
        CGFloat need = CGRectGetMaxY(self.textView.frame) + 16 - (height - self.keyboardHeight);
        self.scrollView.contentOffset = CGPointMake(0, MAX(0, need));
    }];
}

- (void)pasteClipboard
{
    NSString *clip = [[UIPasteboard generalPasteboard] string];
    if (!clip.length) return;
    UITextRange *range = self.textView.selectedTextRange;
    if (range) [self.textView replaceRange:range withText:clip];
    else self.textView.text = [self.textView.text stringByAppendingString:clip];
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
    NSString *domain = BRCookieDomainForHost(self.host);
    NSCharacterSet *dot = [NSCharacterSet characterSetWithCharactersInString:@"."];
    NSString *site = [domain stringByTrimmingCharactersInSet:dot];
    NSMutableSet *names = [NSMutableSet set];
    for (NSHTTPCookie *cookie in cookies) [names addObject:cookie.name];
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    BOOL stored = NO;
    @synchronized (BRCookieLock()) {
        // The site's own cookies of these names (the logged-out session it gave, usually for the exact host) would go out
        // next to the imported ones, and many servers read only the first value: they go. Those the page gets, and
        // those within the imported cookies' domain, whatever their path.
        for (NSHTTPCookie *old in [[jar cookies] copy]) {
            if (![names containsObject:old.name]) continue;
            NSString *d = [[old.domain lowercaseString] stringByTrimmingCharactersInSet:dot];
            BOOL pageGetsIt = [self.host isEqualToString:d] || [self.host hasSuffix:[@"." stringByAppendingString:d]];
            BOOL withinImport = [d isEqualToString:site] || [d hasSuffix:[@"." stringByAppendingString:site]];
            if (pageGetsIt || withinImport) [jar deleteCookie:old];
        }
        for (NSHTTPCookie *cookie in cookies) [jar setCookie:cookie];
        // (what the jar now gives the page: a refused cookie would leave the user logged out without a word)
        for (NSHTTPCookie *cookie in [jar cookiesForURL:self.pageURL]) {
            if ([names containsObject:cookie.name]) {
                stored = YES;
                break;
            }
        }
    }
    if (!stored) {
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"The cookies could not be stored.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    // pages of the site kept in the cache before are the logged-out ones
    [BRURLProtocol noteCookiesImportedForDomain:site];
    BRLog(@"Stored %lu login cookie(s) for %@", (unsigned long)cookies.count, domain);
    NSUInteger count = cookies.count;
    void (^callback)(NSUInteger) = self.onStored;
    [self dismissViewControllerAnimated:YES completion:^{ if (callback) callback(count); }];
}

// Parses what the user pasted into cookies for this site: "a=1; b=2", a Cookie: header (also within a block of
// request headers, whose other lines are skipped), a Set-Cookie: line (its attributes are not cookies), or one
// name=value per line. Values may contain '=', so only the first one in each pair splits name from value.
- (NSArray *)cookiesFromText:(NSString *)text
{
    NSString *domain = BRCookieDomainForHost(self.host);
    if (!domain.length || !text.length) return @[];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSSet *attributes = [NSSet setWithObjects:@"path", @"domain", @"expires", @"max-age", @"samesite", @"secure", @"httponly",
                         @"priority", @"partitioned", @"version", @"comment", nil];
    NSMutableArray *pairs = [NSMutableArray array];
    NSString *lines = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *rawLine in [lines componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
        if (!line.length) continue;
        NSString *lower = [line lowercaseString];
        if ([lower hasPrefix:@"cookie:"]) {
            [pairs addObjectsFromArray:[[line substringFromIndex:7] componentsSeparatedByString:@";"]];
        } else if ([lower hasPrefix:@"set-cookie:"]) {
            [pairs addObject:[[[line substringFromIndex:11] componentsSeparatedByString:@";"] firstObject] ?: @""];
        } else {
            // another header of a pasted request ("Accept-Language: en;q=0.9"): its ':' comes before any '='
            NSRange colon = [line rangeOfString:@":"], eq = [line rangeOfString:@"="];
            if (colon.location != NSNotFound && (eq.location == NSNotFound || colon.location < eq.location) &&
                BRIsCookieName([line substringToIndex:colon.location])) continue;
            [pairs addObjectsFromArray:[line componentsSeparatedByString:@";"]];
        }
    }

    NSMutableArray *cookies = [NSMutableArray array];
    NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:365 * 24 * 60 * 60];
    for (NSString *rawPart in pairs) {
        NSString *part = [rawPart stringByTrimmingCharactersInSet:ws];
        NSRange eq = [part rangeOfString:@"="];
        if (part.length == 0 || eq.location == NSNotFound || eq.location == 0) continue;
        NSString *name = [[part substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *value = [[part substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        if (!BRIsCookieName(name) || [attributes containsObject:[name lowercaseString]]) continue;
        // (a cookie value has no spaces or control characters: "x=5 is the answer" or an Expires date is not one)
        if ([value rangeOfCharacterFromSet:ws].location != NSNotFound ||
            [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) continue;
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        props[NSHTTPCookieName] = name;
        props[NSHTTPCookieValue] = value;
        props[NSHTTPCookieDomain] = domain;
        props[NSHTTPCookiePath] = @"/";
        props[NSHTTPCookieExpires] = expires;
        if (self.secure) props[NSHTTPCookieSecure] = @"TRUE";
        // Out of reach of the pages' scripts (document.cookie) on an engine that gets no security fixes: login cookies
        // usually are HttpOnly in the browser they come from. Not the CSRF tokens a site's own script reads.
        NSString *lowerName = [name lowercaseString];
        if ([lowerName rangeOfString:@"csrf"].location == NSNotFound && [lowerName rangeOfString:@"xsrf"].location == NSNotFound) {
            props[@"HttpOnly"] = @"TRUE";
        }
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

@end
