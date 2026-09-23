#import "BRTheme.h"
#import "BRSettings.h"
#import "BRCommon.h"

NSString * const BRThemeDidChangeNotification = @"BRThemeDidChangeNotification";

static UIColor *RGB(NSInteger r, NSInteger g, NSInteger b)
{
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

// Rounded, vertically shaded rectangle with an optional glossy top half, as a stretchable image.
static UIImage *BRRoundedGradientImage(UIColor *top, UIColor *bottom, UIColor *stroke, CGFloat radius, BOOL gloss)
{
    CGFloat side = radius * 2 + 12;
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(rect, 0.5, 0.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:radius];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)top.CGColor, (id)bottom.CGColor ];
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(0, side), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    if (gloss) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, side, floor(side / 2)));
    }
    CGContextRestoreGState(ctx);
    if (stroke) {
        [stroke setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGFloat cap = radius + 5;
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(cap, cap, cap, cap) resizingMode:UIImageResizingModeStretch];
}

// A bar background: top hairline, gradient body, bottom hairline.
static UIImage *BRBarImage(UIColor *top, UIColor *bottom, UIColor *line, CGFloat height)
{
    CGSize size = CGSizeMake(4, height);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)top.CGColor, (id)bottom.CGColor ];
    CGFloat locs[2] = { 0.0, 1.0 };
    CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(0, height), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    [[UIColor colorWithWhite:1.0 alpha:0.35] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, 1));
    [line setFill];
    UIRectFill(CGRectMake(0, height - 1, size.width, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(2, 1, 2, 1) resizingMode:UIImageResizingModeStretch];
}

@interface BRTheme ()
@property (nonatomic) BOOL dark;
@property (nonatomic, strong) NSMutableDictionary *imageCache;
@end

@implementation BRTheme

+ (instancetype)shared
{
    static BRTheme *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[BRTheme alloc] init]; });
    return t;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dark = [BRSettings darkTheme];
        _imageCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isDark { return self.dark; }

- (void)setDark:(BOOL)dark
{
    _dark = dark;
    [BRSettings setDarkTheme:dark];
    [self.imageCache removeAllObjects];
    [[UIApplication sharedApplication] setStatusBarStyle:[self statusBarStyle] animated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:BRThemeDidChangeNotification object:self];
}

#pragma mark - Colors

- (UIColor *)barTextColor { return self.dark ? RGB(235, 235, 240) : RGB(45, 45, 52); }
- (UIColor *)barTextShadowColor { return self.dark ? [UIColor colorWithWhite:0 alpha:0.6] : [UIColor colorWithWhite:1 alpha:0.7]; }
- (UIColor *)fieldTextColor { return self.dark ? RGB(240, 240, 242) : RGB(20, 20, 22); }
- (UIColor *)placeholderColor { return self.dark ? RGB(120, 120, 128) : RGB(160, 160, 168); }
- (UIColor *)pageBackgroundColor { return self.dark ? RGB(28, 28, 30) : [UIColor whiteColor]; }
- (UIStatusBarStyle)statusBarStyle { return self.dark ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault; }
- (UIBarStyle)barStyle { return self.dark ? UIBarStyleBlack : UIBarStyleDefault; }

#pragma mark - Artwork

- (UIImage *)cachedImage:(NSString *)key builder:(UIImage *(^)(void))builder
{
    UIImage *img = self.imageCache[key];
    if (!img) {
        img = builder();
        if (img) self.imageCache[key] = img;
    }
    return img;
}

- (UIImage *)barBackgroundImage
{
    return [self cachedImage:@"bar" builder:^UIImage *{
        if (self.dark) return BRBarImage(RGB(64, 64, 70), RGB(34, 34, 38), RGB(10, 10, 12), 44);
        return BRBarImage(RGB(248, 248, 250), RGB(208, 210, 218), RGB(150, 152, 160), 44);
    }];
}

- (UIImage *)fieldBackgroundImage
{
    return [self cachedImage:@"field" builder:^UIImage *{
        if (self.dark) return BRRoundedGradientImage(RGB(38, 38, 42), RGB(46, 46, 50), RGB(90, 90, 96), 7, NO);
        return BRRoundedGradientImage(RGB(252, 252, 253), [UIColor whiteColor], RGB(150, 152, 162), 7, NO);
    }];
}

- (UIImage *)buttonImageHighlighted:(BOOL)highlighted
{
    NSString *key = highlighted ? @"button-hi" : @"button";
    return [self cachedImage:key builder:^UIImage *{
        if (self.dark) {
            if (highlighted) return BRRoundedGradientImage(RGB(70, 70, 76), RGB(50, 50, 56), RGB(20, 20, 24), 6, YES);
            return BRRoundedGradientImage(RGB(100, 100, 106), RGB(66, 66, 72), RGB(20, 20, 24), 6, YES);
        }
        if (highlighted) return BRRoundedGradientImage(RGB(200, 203, 212), RGB(170, 174, 186), RGB(120, 124, 136), 6, YES);
        return BRRoundedGradientImage(RGB(250, 250, 252), RGB(214, 216, 225), RGB(140, 144, 156), 6, YES);
    }];
}

- (UIImage *)arrowImagePointingLeft:(BOOL)left enabled:(BOOL)enabled
{
    NSString *key = [NSString stringWithFormat:@"arrow-%d-%d", (int)left, (int)enabled];
    return [self cachedImage:key builder:^UIImage *{
        CGSize size = CGSizeMake(22, 22);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPath];
        if (left) {
            [p moveToPoint:CGPointMake(15, 3)];
            [p addLineToPoint:CGPointMake(6, 11)];
            [p addLineToPoint:CGPointMake(15, 19)];
        } else {
            [p moveToPoint:CGPointMake(7, 3)];
            [p addLineToPoint:CGPointMake(16, 11)];
            [p addLineToPoint:CGPointMake(7, 19)];
        }
        p.lineWidth = 3.5;
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        UIColor *color = enabled ? [self barTextColor] : [[self barTextColor] colorWithAlphaComponent:0.3];
        [color setStroke];
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)reloadImage
{
    return [self cachedImage:@"reload" builder:^UIImage *{
        CGSize size = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = self.dark ? RGB(200, 200, 206) : RGB(90, 90, 100);
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(10, 10) radius:6.5 startAngle:-M_PI * 0.35 endAngle:M_PI * 1.45 clockwise:YES];
        arc.lineWidth = 2.2;
        arc.lineCapStyle = kCGLineCapRound;
        [color setStroke];
        [arc stroke];
        UIBezierPath *head = [UIBezierPath bezierPath];   // arrow head at the start of the arc
        [head moveToPoint:CGPointMake(12.5, 1.5)];
        [head addLineToPoint:CGPointMake(16.5, 5.0)];
        [head addLineToPoint:CGPointMake(11.5, 6.5)];
        [head closePath];
        [color setFill];
        [head fill];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)stopImage
{
    return [self cachedImage:@"stop" builder:^UIImage *{
        CGSize size = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = self.dark ? RGB(200, 200, 206) : RGB(90, 90, 100);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(5, 5)];
        [p addLineToPoint:CGPointMake(15, 15)];
        [p moveToPoint:CGPointMake(15, 5)];
        [p addLineToPoint:CGPointMake(5, 15)];
        p.lineWidth = 2.5;
        p.lineCapStyle = kCGLineCapRound;
        [color setStroke];
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

#pragma mark - UIKit

- (void)applyToNavigationBar:(UINavigationBar *)bar
{
    bar.barStyle = [self barStyle];
    bar.translucent = NO;
    bar.tintColor = nil;
}

- (void)applyToTableView:(UITableView *)tableView
{
    if (self.dark) {
        tableView.backgroundView = nil;
        tableView.backgroundColor = tableView.style == UITableViewStyleGrouped ? RGB(0, 0, 0) : RGB(30, 30, 33);
        tableView.separatorColor = RGB(55, 55, 60);
        tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
}

- (void)styleCell:(UITableViewCell *)cell
{
    if (!self.dark) return;
    cell.backgroundColor = RGB(30, 30, 33);
    cell.textLabel.textColor = RGB(240, 240, 242);
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = RGB(150, 150, 158);
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = RGB(50, 50, 55);
    cell.selectedBackgroundView = sel;
}

@end
