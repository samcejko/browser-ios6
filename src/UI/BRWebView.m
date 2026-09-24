#import "BRWebView.h"
#import "BRCommon.h"

@implementation BRWebView

+ (void)registerMenuItems
{
    UIMenuItem *open = [[UIMenuItem alloc] initWithTitle:L(@"Open") action:@selector(brOpenSelection:)];
    UIMenuItem *search = [[UIMenuItem alloc] initWithTitle:L(@"Search") action:@selector(brSearchSelection:)];
    UIMenuItem *share = [[UIMenuItem alloc] initWithTitle:L(@"Share") action:@selector(brShareSelection:)];
    [UIMenuController sharedMenuController].menuItems = @[open, search, share];
}

// "www.example.com/path" or "https://..." selected as plain text
static BOOL BRLooksLikeAddress(NSString *text)
{
    if (!text.length || text.length > 500 || [text rangeOfString:@" "].location != NSNotFound) return NO;
    if ([[text lowercaseString] hasPrefix:@"http://"] || [[text lowercaseString] hasPrefix:@"https://"]) return YES;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(www\\.)?[a-z0-9-]+(\\.[a-z0-9-]+)+(/\\S*)?$" options:NSRegularExpressionCaseInsensitive error:NULL];
    return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

- (NSString *)selectedText
{
    NSString *text = [self stringByEvaluatingJavaScriptFromString:@"window.getSelection().toString()"] ?: @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// The document view inside asks up the responder chain; our items appear only for a text selection.
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
    if (action == @selector(brSearchSelection:) || action == @selector(brShareSelection:)) {
        NSString *length = [self stringByEvaluatingJavaScriptFromString:@"window.getSelection().toString().length"];
        return [length integerValue] > 0;
    }
    if (action == @selector(brOpenSelection:)) return self.onOpenSelection != nil && BRLooksLikeAddress([self selectedText]);
    return [super canPerformAction:action withSender:sender];
}

- (void)brOpenSelection:(id)sender
{
    NSString *text = [self selectedText];
    if (text.length && self.onOpenSelection) self.onOpenSelection(text);
}

- (void)brSearchSelection:(id)sender
{
    NSString *text = [self selectedText];
    if (text.length && self.onSearchSelection) self.onSearchSelection(text);
}

- (void)brShareSelection:(id)sender
{
    NSString *text = [self selectedText];
    if (text.length && self.onShareSelection) self.onShareSelection(text);
}

@end
