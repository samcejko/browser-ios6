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
@property (nonatomic) NSUInteger otherSitesCookies;   // pasted cookies of other sites, left out (see pastedCookiesFromText:)
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

// A name that is a public suffix rather than one site: a country's second level (co.uk, com.au, ne.jp...) or a hosting
// service whose subdomains belong to different people (github.io, neocities.org...). Cookies are never given to it.
static BOOL BRLooksLikePublicSuffix(NSString *name)
{
    static NSSet *hosting, *secondLevel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosting = [NSSet setWithObjects:@"github.io", @"gitlab.io", @"bitbucket.io", @"herokuapp.com", @"netlify.app",
                   @"vercel.app", @"pages.dev", @"workers.dev", @"web.app", @"firebaseapp.com", @"appspot.com",
                   @"blogspot.com", @"wordpress.com", @"tumblr.com", @"azurewebsites.net", @"cloudfront.net",
                   @"onrender.com", @"railway.app", @"deno.dev", @"fly.dev", @"glitch.me", @"neocities.org", @"surge.sh",
                   @"myshopify.com", @"itch.io", @"wixsite.com", @"weebly.com", @"square.site", @"webflow.io", @"carrd.co",
                   @"gitbook.io", @"notion.site", @"readthedocs.io", @"pythonanywhere.com", @"repl.co", @"replit.app",
                   @"ngrok.io", @"ngrok.app", @"ngrok-free.app", nil];
        secondLevel = [NSSet setWithObjects:@"co", @"com", @"net", @"org", @"gov", @"edu", @"ac", @"ne", @"or", @"go",
                       @"gob", @"mil", @"nic", @"ltd", @"plc", @"sch", @"nhs", @"police", nil];
    });
    if ([hosting containsObject:name]) return YES;
    NSArray *labels = [name componentsSeparatedByString:@"."];
    return labels.count == 2 && [labels[1] length] == 2 && [secondLevel containsObject:labels[0]];
}

// Before a login moves up to a parent domain because the jar holds a cookie of its name there (see logIn), more caution
// than that list: a cookie that some page planted on a suffix the list misses would pull the session up to every site
// under it. So also nothing like uk.com (a country code under com, net or org), no blogspot.<country> and nothing of a
// cloud's own hosts.
static BOOL BRMayBeSharedSuffix(NSString *name)
{
    if (BRLooksLikePublicSuffix(name)) return YES;
    NSArray *labels = [name componentsSeparatedByString:@"."];
    if (labels.count < 2 || [labels[0] isEqualToString:@"blogspot"]) return YES;
    for (NSString *cloud in @[@"amazonaws.com", @"cloudapp.net", @"cloudapp.azure.com", @"azurestaticapps.net", @"googleusercontent.com",
                              @"cloudfunctions.net", @"run.app", @"firebaseio.com", @"fastly.net", @"r2.dev", @"amplifyapp.com"]) {
        if ([name isEqualToString:cloud] || [name hasSuffix:[@"." stringByAppendingString:cloud]]) return YES;
    }
    NSString *tld = [labels lastObject];
    return labels.count == 2 && [labels[0] length] <= 2 && ([tld isEqualToString:@"com"] || [tld isEqualToString:@"net"] || [tld isEqualToString:@"org"]);
}

// Where the imported cookies go by default: the page's host and its subdomains (".host"), a leading "www." dropped so that
// www.example.com and example.com share them, the way a site's own login cookies usually are (".furaffinity.net" covers
// www. and d.furaffinity.net). Never wider: the last two labels would be the public suffix itself for example.co.uk or
// user.github.io, and the session would go to every site under it. A public-suffix host (neocities.org, whose
// subdomains are other people's pages), an IP address, a one-label host or one written with the root's trailing dot
// keeps the cookies to itself.
static NSString *BRCookieDomainForHost(NSString *host)
{
    host = [[host lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!host.length) return nil;
    if ([host hasSuffix:@"."] || [host rangeOfString:@":"].location != NSNotFound) return host;   // (trailing dot, IPv6)
    NSArray *labels = [host componentsSeparatedByString:@"."];
    if (labels.count < 2) return host;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([[labels lastObject] rangeOfCharacterFromSet:nonDigits].location == NSNotFound) return host;   // IPv4
    NSString *site = (labels.count >= 3 && [labels[0] isEqualToString:@"www"]) ? [host substringFromIndex:4] : host;
    if (BRLooksLikePublicSuffix(site)) return [site isEqualToString:host] ? host : [@"." stringByAppendingString:host];
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

static BOOL BRIsDigits(NSString *s)
{
    return s.length && [s rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
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
    // The text box gets what is left above the keyboard. Its minimum (a few lines) gives way while the keyboard is up, so
    // that its top - and the caret - stays in view on a phone in landscape; the explanation scrolls away then.
    CGFloat visible = bounds.size.height - self.keyboardHeight;
    CGFloat minHeight = self.keyboardHeight > 0 ? MIN(100, MAX(40, visible - 2 * margin)) : 100;
    CGFloat height = MAX(minHeight, visible - top - margin);
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
        // the text box above the keyboard, the explanation scrolled up as far as that needs - never past the box's top
        CGFloat need = CGRectGetMaxY(self.textView.frame) + 16 - (height - self.keyboardHeight);
        need = MIN(need, CGRectGetMinY(self.textView.frame) - 8);
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

- (NSHTTPCookie *)cookieNamed:(NSString *)name value:(NSString *)value domain:(NSString *)domain httpOnly:(BOOL)httpOnly
{
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    props[NSHTTPCookieName] = name;
    props[NSHTTPCookieValue] = value;
    props[NSHTTPCookieDomain] = domain;
    props[NSHTTPCookiePath] = @"/";
    props[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSinceNow:365 * 24 * 60 * 60];
    if (self.secure) props[NSHTTPCookieSecure] = @"TRUE";
    // (only when the pasted Set-Cookie line said so: a site's own scripts read some of their login cookies - X's ct0,
    // Twitch's auth-token - and a flag the user did not give would break the site)
    if (httpOnly) props[@"HttpOnly"] = @"TRUE";
    return [NSHTTPCookie cookieWithProperties:props];
}

- (void)logIn
{
    NSArray *pasted = [self pastedCookiesFromText:self.textView.text];
    if (pasted.count == 0) {
        NSString *message = self.otherSitesCookies ? [NSString stringWithFormat:L(@"The pasted cookies are all for other sites, none for %@."), self.host ?: @""]
                                                   : L(@"No cookies were found. Paste them as name=value, separated by semicolons.");
        [[[UIAlertView alloc] initWithTitle:nil message:message delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    NSString *defaultDomain = BRCookieDomainForHost(self.host);
    NSCharacterSet *dot = [NSCharacterSet characterSetWithCharactersInString:@"."];
    NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *p in pasted) [names addObject:p[@"name"]];
    NSMutableDictionary *domainFor = [NSMutableDictionary dictionary];
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    BOOL stored = NO;
    @synchronized (BRCookieLock()) {
        NSArray *existing = [[jar cookies] copy];
        // 1. Each name's domain: the default one, or a parent domain the site itself keeps that name for (reddit_session on
        //    .reddit.com while the page is old.reddit.com): the login is the site's, not the subdomain's. (Not for a host
        //    that keeps them to itself: an IP address's "parent" is no site, nor a public suffix's.)
        for (NSString *name in names) domainFor[name] = defaultDomain;
        for (NSHTTPCookie *old in [defaultDomain hasPrefix:@"."] ? existing : @[]) {
            NSString *current = domainFor[old.name];
            if (!current || ![old.domain hasPrefix:@"."]) continue;   // (a host-only cookie of another host is not the page's)
            NSString *d = [[old.domain lowercaseString] stringByTrimmingCharactersInSet:dot];
            NSString *root = [current stringByTrimmingCharactersInSet:dot];
            BOOL parent = [root hasSuffix:[@"." stringByAppendingString:d]];
            BOOL pageGetsIt = [self.host isEqualToString:d] || [self.host hasSuffix:[@"." stringByAppendingString:d]];
            if (parent && pageGetsIt && [d rangeOfString:@"."].location != NSNotFound && !BRMayBeSharedSuffix(d)) {
                domainFor[old.name] = [@"." stringByAppendingString:d];
            }
        }
        // 2. The cookies of these names that the page gets, or within the domain the import gives them, go: the site's
        //    logged-out session would go out next to the imported one, and many servers read only the first value. Kept
        //    aside, to be put back if the import does not take.
        NSMutableArray *removed = [NSMutableArray array];
        for (NSHTTPCookie *old in existing) {
            NSString *domain = domainFor[old.name];
            if (!domain) continue;
            NSString *d = [[old.domain lowercaseString] stringByTrimmingCharactersInSet:dot];
            NSString *root = [domain stringByTrimmingCharactersInSet:dot];
            BOOL hostOnly = ![old.domain hasPrefix:@"."];
            BOOL pageGetsIt = [self.host isEqualToString:d] || (!hostOnly && [self.host hasSuffix:[@"." stringByAppendingString:d]]);
            // (an import kept to the host itself - a public-suffix host - leaves the cookies of the sites under it alone)
            BOOL within = [domain hasPrefix:@"."] ? ([d isEqualToString:root] || [d hasSuffix:[@"." stringByAppendingString:root]])
                                                  : (hostOnly && [d isEqualToString:root]);
            if (pageGetsIt || within) {
                [jar deleteCookie:old];
                [removed addObject:old];
            }
        }
        // 3. The imported ones
        NSMutableArray *added = [NSMutableArray array];
        for (NSDictionary *p in pasted) {
            NSHTTPCookie *cookie = [self cookieNamed:p[@"name"] value:p[@"value"] domain:domainFor[p[@"name"]] httpOnly:[p[@"httpOnly"] boolValue]];
            if (!cookie) continue;
            [jar setCookie:cookie];
            [added addObject:cookie];
        }
        // 4. What the jar now gives the page. A refused cookie would leave the user logged out without a word, and with
        //    the site's own cookies gone: then everything goes back as it was.
        for (NSHTTPCookie *cookie in [jar cookiesForURL:self.pageURL]) {
            if ([names containsObject:cookie.name]) {
                stored = YES;
                break;
            }
        }
        if (!stored) {
            for (NSHTTPCookie *cookie in added) [jar deleteCookie:cookie];
            for (NSHTTPCookie *cookie in removed) [jar setCookie:cookie];
        }
    }
    if (!stored) {
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"The cookies could not be stored.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
        return;
    }
    // pages of the site kept in the cache before are the logged-out ones
    for (NSString *domain in [NSSet setWithArray:[domainFor allValues]]) [BRURLProtocol noteCookiesImportedForDomain:domain];
    BRLog(@"Stored %lu login cookie(s) for %@", (unsigned long)pasted.count, self.host);
    NSUInteger count = pasted.count;
    void (^callback)(NSUInteger) = self.onStored;
    [self dismissViewControllerAnimated:YES completion:^{ if (callback) callback(count); }];
}

// The attributes of a Set-Cookie line, never the names of cookies ("Path=/" on a line of its own is not one)
static BOOL BRIsCookieAttribute(NSString *name)
{
    static NSSet *attributes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        attributes = [NSSet setWithObjects:@"path", @"domain", @"expires", @"max-age", @"samesite", @"secure", @"httponly",
                      @"priority", @"partitioned", @"version", @"comment", nil];
    });
    return [attributes containsObject:[[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString]];
}

// One pasted cookie into the result (the last of a name wins, in the order the names first came)
static void BRAddPasted(NSString *name, NSString *value, BOOL httpOnly, NSMutableArray *order, NSMutableDictionary *byName)
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    name = [name stringByTrimmingCharactersInSet:ws];
    value = [value stringByTrimmingCharactersInSet:ws];
    if (!BRIsCookieName(name)) return;
    // (a cookie value has no spaces or control characters: "x=5 is the answer" or an Expires date is not one)
    if ([value rangeOfCharacterFromSet:ws].location != NSNotFound ||
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return;
    if (!byName[name]) [order addObject:name];
    byName[name] = @{ @"name": name, @"value": value, @"httpOnly": @(httpOnly) };
}

// One "name=value" segment
static void BRAddPastedPair(NSString *pair, BOOL httpOnly, NSMutableArray *order, NSMutableDictionary *byName)
{
    pair = [pair stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location == 0) return;
    BRAddPasted([pair substringToIndex:eq.location], [pair substringFromIndex:eq.location + 1], httpOnly, order, byName);
}

// The pairs of a Cookie header's value ("a=1; b=2"). Of two of one name in it the first counts, as on the server: a
// browser puts the more specific cookie (the subdomain's, the longer path's) first.
static void BRAddPastedPairs(NSString *pairs, NSMutableArray *order, NSMutableDictionary *byName)
{
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *pair in [pairs componentsSeparatedByString:@";"]) {
        NSRange eq = [pair rangeOfString:@"="];
        NSString *name = eq.location == NSNotFound ? nil : [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length || [seen containsObject:name]) continue;
        [seen addObject:name];
        BRAddPastedPair(pair, NO, order, byName);
    }
}

// The year an HTTP date names ("Thu, 01 Jan 1970 00:00:00 GMT"), 0 when it names none
static NSInteger BRYearInDate(NSString *date)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\b(1[6-9]|2[0-9])[0-9]{2}\\b" options:0 error:NULL];
    NSTextCheckingResult *m = date.length ? [re firstMatchInString:date options:0 range:NSMakeRange(0, date.length)] : nil;
    return m ? [[date substringWithRange:m.range] integerValue] : 0;
}

// A Set-Cookie value split at ';': the cookie, then its attributes. Its HttpOnly is kept. One that deletes the cookie
// (Max-Age 0 or less, an Expires date of a past year) is no cookie to log in with: with two lines of one name in a pasted
// response it would otherwise replace the real one.
static void BRAddPastedSetCookie(NSArray *segments, NSMutableArray *order, NSMutableDictionary *byName)
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSInteger thisYear = 1970 + (NSInteger)([[NSDate date] timeIntervalSince1970] / (365.2425 * 24 * 3600));
    BOOL httpOnly = NO;
    for (NSUInteger i = 1; i < segments.count; i++) {
        NSString *attr = [[segments[i] stringByTrimmingCharactersInSet:ws] lowercaseString];
        if ([attr isEqualToString:@"httponly"]) httpOnly = YES;
        if ([attr hasPrefix:@"max-age="]) {
            NSString *v = [[attr substringFromIndex:8] stringByTrimmingCharactersInSet:ws];
            if (BRIsDigits([v hasPrefix:@"-"] ? [v substringFromIndex:1] : v) && [v integerValue] <= 0) return;
        }
        if ([attr hasPrefix:@"expires="]) {
            NSInteger year = BRYearInDate(attr);
            if (year && year < thisYear) return;
        }
    }
    if (segments.count) BRAddPastedPair(segments[0], httpOnly, order, byName);
}

// A header line of a pasted request or response ("Accept-Language: en;q=0.9", HTTP/2's ":path: /?a=1;b=2", Chrome's
// "Request URL: https://..."): its ':' comes before any '=', after a label of letters, digits, spaces, '-' and '_'.
// (Also an address, "https://example.com/?a=1": not cookies either.)
static BOOL BRIsHeaderLine(NSString *line)
{
    static NSCharacterSet *notLabel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notLabel = [[NSCharacterSet characterSetWithCharactersInString:
                     @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_"] invertedSet];
    });
    NSUInteger start = (line.length && [line characterAtIndex:0] == ':') ? 1 : 0;   // (an HTTP/2 pseudo-header)
    if (start >= line.length) return NO;
    NSRange colon = [line rangeOfString:@":" options:0 range:NSMakeRange(start, line.length - start)];
    if (colon.location == NSNotFound || colon.location == start) return NO;
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location != NSNotFound && eq.location < colon.location) return NO;
    NSString *label = [line substringWithRange:NSMakeRange(start, colon.location - start)];
    return [label rangeOfCharacterFromSet:notLabel].location == NSNotFound;
}

// A row of a cookie table, a cookies.txt or a JSON export goes to this page only if the page would get it: its domain is
// the page's host or one above it (not a public suffix). Such a file holds every site's cookies, and another site's
// session must neither go to this one nor replace its own.
static BOOL BRRowDomainBelongs(NSString *rowDomain, NSString *host)
{
    NSString *d = [[rowDomain lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([d hasPrefix:@"#httponly_"]) d = [d substringFromIndex:10];
    d = [d stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    NSString *h = [host stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    if (!d.length || !h.length) return NO;
    if ([h isEqualToString:d]) return YES;
    return [h hasSuffix:[@"." stringByAppendingString:d]] && [d rangeOfString:@"."].location != NSNotFound && !BRLooksLikePublicSuffix(d);
}

// Windows' "Copy as cURL (cmd)" escapes with ^ (^"https://...^" ^): the characters as they were, its line ends as they are
static NSString *BRUnescapeCmd(NSString *s)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '^' && i + 1 < s.length) c = [s characterAtIndex:++i];
        [out appendFormat:@"%C", c];
    }
    return out;
}

// The words of a shell command as the shell hands them on: '...' as it is, "..." and bare words with their \ escapes,
// bash's $'...' with its own, a \ at the end of a line joining the next one
static NSArray *BRShellWords(NSString *command)
{
    if ([command rangeOfString:@"^\""].location != NSNotFound) command = BRUnescapeCmd(command);
    NSMutableArray *words = [NSMutableArray array];
    NSMutableString *word = nil;
    unichar quote = 0;   // ', " or $ (inside $'...')
    NSUInteger n = command.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [command characterAtIndex:i];
        if (quote == '\'') {
            if (c == '\'') quote = 0;
            else [word appendFormat:@"%C", c];
            continue;
        }
        if (c == '\\' && i + 1 < n) {
            unichar next = [command characterAtIndex:i + 1];
            if (next == '\n') { i++; continue; }
            if (quote == '$' || quote == 0 || next == '"' || next == '\\' || next == '$' || next == '`') {
                i++;
                if (quote == '$') next = next == 'n' ? '\n' : next == 't' ? '\t' : next == 'r' ? '\r' : next;
                if (!word) word = [NSMutableString string];
                [word appendFormat:@"%C", next];
                continue;
            }
        }
        if (quote == '"' || quote == '$') {
            if ((quote == '"' && c == '"') || (quote == '$' && c == '\'')) quote = 0;
            else [word appendFormat:@"%C", c];
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n') {
            if (word) [words addObject:word];
            word = nil;
            continue;
        }
        if (!word) word = [NSMutableString string];
        if (c == '\'' || c == '"') quote = c;
        else if (c == '$' && i + 1 < n && [command characterAtIndex:i + 1] == '\'') { quote = '$'; i++; }
        else [word appendFormat:@"%C", c];
    }
    if (word) [words addObject:word];
    return words;
}

// "Copy as cURL" (bash or cmd, on one line or many): the cookies of its -b/--cookie and of a -H 'cookie: ...'. Its other
// headers (Accept's "q=0.9") and its data are not cookies.
static void BRAddPastedCurl(NSString *command, NSMutableArray *order, NSMutableDictionary *byName)
{
    NSArray *words = BRShellWords(command);
    for (NSUInteger i = 0; i + 1 < words.count; i++) {
        NSString *option = words[i], *arg = words[i + 1];
        if ([option isEqualToString:@"-H"] || [option isEqualToString:@"--header"]) {
            if ([[arg lowercaseString] hasPrefix:@"cookie:"]) BRAddPastedPairs([arg substringFromIndex:7], order, byName);
            i++;
        } else if ([option isEqualToString:@"-b"] || [option isEqualToString:@"--cookie"]) {
            if ([arg rangeOfString:@"="].location != NSNotFound) BRAddPastedPairs(arg, order, byName);   // (else a file's name)
            i++;
        }
    }
}

// A JSON export (Cookie-Editor, EditThisCookie: a list of {name, value, domain, httpOnly...}; Playwright's storage state:
// {"cookies": [...]}): its cookies for this page. NO if the text is no such JSON.
static BOOL BRAddPastedJSON(NSString *text, NSString *host, NSUInteger *otherSites, NSMutableArray *order, NSMutableDictionary *byName)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([json isKindOfClass:[NSDictionary class]]) json = [(NSDictionary *)json objectForKey:@"cookies"];
    if (![json isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *c in (NSArray *)json) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = c[@"name"], *value = c[@"value"], *domain = c[@"domain"];
        if (![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
        if ([domain isKindOfClass:[NSString class]] && !BRRowDomainBelongs(domain, host)) {
            (*otherSites)++;
            continue;
        }
        id httpOnly = c[@"httpOnly"];
        BRAddPasted(name, value, [httpOnly respondsToSelector:@selector(boolValue)] && [httpOnly boolValue], order, byName);
    }
    return YES;
}

// One pair of quotes around the whole text (as a console prints document.cookie) goes
static NSString *BRWithoutQuotes(NSString *s)
{
    if (s.length < 2) return s;
    unichar first = [s characterAtIndex:0], last = [s characterAtIndex:s.length - 1];
    if ((first == '"' || first == '\'') && first == last) {
        return [[s substringWithRange:NSMakeRange(1, s.length - 2)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return s;
}

// What the user pasted, as cookies (name, value, httpOnly), the last of a name winning: "a=1; b=2"; document.cookie as a
// console prints it, in quotes; a Cookie: header, also within a block of request headers, whose other lines are skipped;
// a Set-Cookie: line, or its value alone, whose attributes are not cookies; one name=value per line; "Copy as cURL"; a
// JSON export; rows of a header table, of a browser's cookie table (name, value, domain...) or of a Netscape
// cookies.txt - of these only the cookies this page gets (otherSitesCookies counts the others). Values may contain '=':
// only the first one in each pair splits name from value.
- (NSArray *)pastedCookiesFromText:(NSString *)text
{
    self.otherSitesCookies = 0;
    if (!text.length) return @[];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableCharacterSet *spaces = [ws mutableCopy];
    [spaces removeCharactersInString:@"\t"];   // (a row's last column may be empty)
    NSMutableArray *order = [NSMutableArray array];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    NSUInteger otherSites = 0;

    NSString *lines = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    lines = [lines stringByReplacingOccurrencesOfString:@"﻿" withString:@""];   // (a byte order mark a file may start with)
    NSString *trimmed = [lines stringByTrimmingCharactersInSet:ws];
    NSString *lowerText = [trimmed lowercaseString];
    if ([lowerText hasPrefix:@"curl "] || [lowerText hasPrefix:@"curl.exe "]) {
        BRAddPastedCurl(trimmed, order, byName);
        lines = @"";
    } else if (([trimmed hasPrefix:@"["] || [trimmed hasPrefix:@"{"]) && BRAddPastedJSON(trimmed, self.host, &otherSites, order, byName)) {
        lines = @"";
    }
    for (NSString *rawLine in [lines componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
        if (!line.length) continue;
        if ([line rangeOfString:@"\t"].location != NSNotFound) {
            NSArray *fields = [[rawLine stringByTrimmingCharactersInSet:spaces] componentsSeparatedByString:@"\t"];
            NSString *head = [[[fields[0] stringByTrimmingCharactersInSet:ws] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
            // a table of request or response headers: its Cookie or Set-Cookie row
            if ([head isEqualToString:@"cookie"]) {
                BRAddPastedPairs(fields[1], order, byName);
                continue;
            }
            if ([head isEqualToString:@"set-cookie"]) {
                BRAddPastedSetCookie([fields[1] componentsSeparatedByString:@";"], order, byName);
                continue;
            }
            // a Netscape cookies.txt: domain, include subdomains, path, secure, expiry (may be empty), name, value;
            // "#HttpOnly_" before an HttpOnly cookie's domain, other "#" lines comments
            if ([line hasPrefix:@"#"] && ![line hasPrefix:@"#HttpOnly_"]) continue;
            if (fields.count == 7) {
                NSString *subdomains = [[fields[1] stringByTrimmingCharactersInSet:ws] uppercaseString];
                NSString *secure = [[fields[3] stringByTrimmingCharactersInSet:ws] uppercaseString];
                if (([subdomains isEqualToString:@"TRUE"] || [subdomains isEqualToString:@"FALSE"]) &&
                    ([secure isEqualToString:@"TRUE"] || [secure isEqualToString:@"FALSE"])) {
                    if (BRRowDomainBelongs(fields[0], self.host)) BRAddPasted(fields[5], fields[6], [line hasPrefix:@"#HttpOnly_"], order, byName);
                    else otherSites++;
                    continue;
                }
            }
            // a browser's cookie table: name, value, domain, path, expires, size, HttpOnly (a tick), ...
            if (fields.count >= 3) {
                BOOL httpOnly = fields.count > 6 && ([fields[6] rangeOfString:@"✓"].location != NSNotFound ||
                                                     [[[fields[6] stringByTrimmingCharactersInSet:ws] lowercaseString] isEqualToString:@"true"]);
                if (BRRowDomainBelongs(fields[2], self.host)) BRAddPasted(fields[0], fields[1], httpOnly, order, byName);
                else otherSites++;
            }
            continue;
        }
        if ([line hasPrefix:@"#"]) continue;   // (a cookies.txt's comments)
        line = BRWithoutQuotes(line);
        NSString *lower = [line lowercaseString];
        if ([lower hasPrefix:@"cookie:"]) {
            BRAddPastedPairs([line substringFromIndex:7], order, byName);
            continue;
        }
        if ([lower hasPrefix:@"set-cookie:"]) {
            BRAddPastedSetCookie([[line substringFromIndex:11] componentsSeparatedByString:@";"], order, byName);
            continue;
        }
        if (BRIsHeaderLine(line)) continue;
        NSArray *segments = [line componentsSeparatedByString:@";"];
        // (the value of another header on a line of its own, "en-US,en;q=0.9": cookies start with a name=value)
        NSString *first = nil;
        for (NSString *seg in segments) {
            if (![seg stringByTrimmingCharactersInSet:ws].length) continue;
            first = seg;
            break;
        }
        if ([first rangeOfString:@"="].location == NSNotFound) continue;
        // a Set-Cookie value without its header name ("s=abc; Path=/; HttpOnly"): its attributes give it away
        BOOL setCookieValue = NO;
        for (NSUInteger i = 1; i < segments.count && !setCookieValue; i++) {
            NSString *seg = segments[i];
            NSRange e = [seg rangeOfString:@"="];
            setCookieValue = BRIsCookieAttribute(e.location == NSNotFound ? seg : [seg substringToIndex:e.location]);
        }
        if (setCookieValue) {
            BRAddPastedSetCookie(segments, order, byName);
        } else {
            for (NSString *pair in segments) {
                NSRange e = [pair rangeOfString:@"="];
                if (e.location != NSNotFound && BRIsCookieAttribute([pair substringToIndex:e.location])) continue;   // ("Path=/" alone)
                BRAddPastedPair(pair, NO, order, byName);
            }
        }
    }
    self.otherSitesCookies = otherSites;
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSString *name in order) [cookies addObject:byName[name]];
    return cookies;
}

@end
