#import "BRWebView.h"
#import "BRCommon.h"

@implementation BRWebView

+ (void)registerMenuItems
{
    UIMenuItem *search = [[UIMenuItem alloc] initWithTitle:L(@"Search") action:@selector(brSearchSelection:)];
    UIMenuItem *share = [[UIMenuItem alloc] initWithTitle:L(@"Share") action:@selector(brShareSelection:)];
    [UIMenuController sharedMenuController].menuItems = @[search, share];
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
    return [super canPerformAction:action withSender:sender];
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
