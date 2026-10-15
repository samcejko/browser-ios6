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
        [[[UIAlertView alloc] initWithTitle:nil message:L(@"No cookies were found. Paste them as name=value, separated by semicolons.") delegate:nil cancelButtonTitle:L(@"OK") otherButtonTitles:nil] show];
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
        //    .reddit.com while the page is old.reddit.com): the login is the site's, not the subdomain's.
        for (NSString *name in names) domainFor[name] = defaultDomain;
        for (NSHTTPCookie *old in existing) {
            NSString *current = domainFor[old.name];
            if (!current || ![old.domain hasPrefix:@"."]) continue;   // (a host-only cookie of another host is not the page's)
            NSString *d = [[old.domain lowercaseString] stringByTrimmingCharactersInSet:dot];
            NSString *root = [current stringByTrimmingCharactersInSet:dot];
            BOOL parent = [root hasSuffix:[@"." stringByAppendingString:d]];
            BOOL pageGetsIt = [self.host isEqualToString:d] || [self.host hasSuffix:[@"." stringByAppendingString:d]];
            if (parent && pageGetsIt && [d rangeOfString:@"."].location != NSNotFound && !BRLooksLikePublicSuffix(d)) {
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
            BOOL within = [d isEqualToString:root] || [d hasSuffix:[@"." stringByAppendingString:root]];
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

// What the user pasted, as cookies (name, value, httpOnly), the last of a name winning: "a=1; b=2"; document.cookie as a
// console prints it, in quotes; a Cookie: header, also within a block of request headers, whose other lines are skipped;
// a Set-Cookie: line, or its value alone, whose attributes are not cookies; one name=value per line; rows of a cookie
// table (tab-separated, name and value first) or of a Netscape cookies.txt. Values may contain '=': only the first one
// in each pair splits name from value.
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

// A Set-Cookie value split at ';': the cookie, then its attributes (of which only HttpOnly matters here)
static void BRAddPastedSetCookie(NSArray *segments, NSMutableArray *order, NSMutableDictionary *byName)
{
    BOOL httpOnly = NO;
    for (NSUInteger i = 1; i < segments.count; i++) {
        NSString *attr = [[segments[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if ([attr isEqualToString:@"httponly"]) httpOnly = YES;
    }
    if (segments.count) BRAddPastedPair(segments[0], httpOnly, order, byName);
}

- (NSArray *)pastedCookiesFromText:(NSString *)text
{
    if (!text.length) return @[];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSSet *attributes = [NSSet setWithObjects:@"path", @"domain", @"expires", @"max-age", @"samesite", @"secure", @"httponly",
                         @"priority", @"partitioned", nil];
    NSMutableArray *order = [NSMutableArray array];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];

    NSString *lines = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *rawLine in [lines componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
        if (line.length >= 2) {
            unichar first = [line characterAtIndex:0], last = [line characterAtIndex:line.length - 1];
            if ((first == '"' || first == '\'') && first == last) line = [[line substringWithRange:NSMakeRange(1, line.length - 2)] stringByTrimmingCharactersInSet:ws];
        }
        if (!line.length) continue;
        NSString *lower = [line lowercaseString];
        if ([lower hasPrefix:@"cookie:"]) {
            for (NSString *pair in [[line substringFromIndex:7] componentsSeparatedByString:@";"]) BRAddPastedPair(pair, NO, order, byName);
            continue;
        }
        if ([lower hasPrefix:@"set-cookie:"]) {
            BRAddPastedSetCookie([[line substringFromIndex:11] componentsSeparatedByString:@";"], order, byName);
            continue;
        }
        if ([line rangeOfString:@"\t"].location != NSNotFound) {
            // a table row: Netscape cookies.txt (domain, flag, path, secure, expiry, name, value; "#HttpOnly_" before an
            // HttpOnly cookie's domain, other "#" lines comments), or a browser's cookie table (name, value, ...)
            if ([line hasPrefix:@"#"] && ![line hasPrefix:@"#HttpOnly_"]) continue;
            NSArray *fields = [line componentsSeparatedByString:@"\t"];
            if (fields.count >= 7 && BRIsDigits([fields[4] stringByTrimmingCharactersInSet:ws])) {
                BRAddPasted(fields[5], fields[6], [line hasPrefix:@"#HttpOnly_"], order, byName);
            } else if (fields.count >= 2 && [fields[0] rangeOfString:@"="].location == NSNotFound) {
                BRAddPasted(fields[0], fields[1], NO, order, byName);
            }
            continue;
        }
        // another header of a pasted request ("Accept-Language: en;q=0.9"): its ':' comes before any '='
        NSRange colon = [line rangeOfString:@":"], eq = [line rangeOfString:@"="];
        if (colon.location != NSNotFound && (eq.location == NSNotFound || colon.location < eq.location) &&
            BRIsCookieName([line substringToIndex:colon.location])) continue;
        NSArray *segments = [line componentsSeparatedByString:@";"];
        // a Set-Cookie value without its header name ("s=abc; Path=/; HttpOnly"): its attributes give it away
        BOOL setCookieValue = NO;
        for (NSUInteger i = 1; i < segments.count && !setCookieValue; i++) {
            NSString *seg = [[segments[i] stringByTrimmingCharactersInSet:ws] lowercaseString];
            NSRange e = [seg rangeOfString:@"="];
            NSString *attr = e.location == NSNotFound ? seg : [seg substringToIndex:e.location];
            setCookieValue = [attributes containsObject:[attr stringByTrimmingCharactersInSet:ws]];
        }
        if (setCookieValue) {
            BRAddPastedSetCookie(segments, order, byName);
        } else {
            for (NSString *pair in segments) BRAddPastedPair(pair, NO, order, byName);
        }
    }
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSString *name in order) [cookies addObject:byName[name]];
    return cookies;
}

@end
