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

- (UIImage *)bookmarksImage
{
    return [self cachedImage:@"book" builder:^UIImage *{
        CGSize size = CGSizeMake(26, 22);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = [self barTextColor];
        [color setStroke];
        [color setFill];
        // two pages of an open book
        UIBezierPath *left = [UIBezierPath bezierPath];
        [left moveToPoint:CGPointMake(13, 5)];
        [left addCurveToPoint:CGPointMake(2, 3) controlPoint1:CGPointMake(10, 2.5) controlPoint2:CGPointMake(6, 2)];
        [left addLineToPoint:CGPointMake(2, 17)];
        [left addCurveToPoint:CGPointMake(13, 19.5) controlPoint1:CGPointMake(6, 16) controlPoint2:CGPointMake(10, 16.5)];
        [left closePath];
        UIBezierPath *right = [UIBezierPath bezierPath];
        [right moveToPoint:CGPointMake(13, 5)];
        [right addCurveToPoint:CGPointMake(24, 3) controlPoint1:CGPointMake(16, 2.5) controlPoint2:CGPointMake(20, 2)];
        [right addLineToPoint:CGPointMake(24, 17)];
        [right addCurveToPoint:CGPointMake(13, 19.5) controlPoint1:CGPointMake(20, 16) controlPoint2:CGPointMake(16, 16.5)];
        [right closePath];
        left.lineWidth = 1.8;
        right.lineWidth = 1.8;
        left.lineJoinStyle = kCGLineJoinRound;
        right.lineJoinStyle = kCGLineJoinRound;
        [left stroke];
        [right stroke];
        // text lines
        UIBezierPath *lines = [UIBezierPath bezierPath];
        for (int i = 0; i < 3; i++) {
            CGFloat y = 7.5 + i * 3.2;
            [lines moveToPoint:CGPointMake(5, y + 0.6)];
            [lines addLineToPoint:CGPointMake(10.5, y - 0.2)];
            [lines moveToPoint:CGPointMake(15.5, y - 0.2)];
            [lines addLineToPoint:CGPointMake(21, y + 0.6)];
        }
        lines.lineWidth = 1.0;
        [[color colorWithAlphaComponent:0.7] setStroke];
        [lines stroke];
        // spine
        UIBezierPath *spine = [UIBezierPath bezierPath];
        [spine moveToPoint:CGPointMake(13, 5)];
        [spine addLineToPoint:CGPointMake(13, 19.5)];
        spine.lineWidth = 1.8;
        [color setStroke];
        [spine stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)shareImage
{
    return [self cachedImage:@"share" builder:^UIImage *{
        CGSize size = CGSizeMake(24, 24);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = [self barTextColor];
        UIBezierPath *tray = [UIBezierPath bezierPath];   // open box
        [tray moveToPoint:CGPointMake(8, 10)];
        [tray addLineToPoint:CGPointMake(5, 10)];
        [tray addLineToPoint:CGPointMake(5, 21)];
        [tray addLineToPoint:CGPointMake(19, 21)];
        [tray addLineToPoint:CGPointMake(19, 10)];
        [tray addLineToPoint:CGPointMake(16, 10)];
        tray.lineWidth = 1.8;
        tray.lineJoinStyle = kCGLineJoinRound;
        [color setStroke];
        [tray stroke];
        UIBezierPath *arrow = [UIBezierPath bezierPath];
        [arrow moveToPoint:CGPointMake(12, 15)];
        [arrow addLineToPoint:CGPointMake(12, 3)];
        [arrow moveToPoint:CGPointMake(8, 7)];
        [arrow addLineToPoint:CGPointMake(12, 3)];
        [arrow addLineToPoint:CGPointMake(16, 7)];
        arrow.lineWidth = 1.8;
        arrow.lineCapStyle = kCGLineCapRound;
        arrow.lineJoinStyle = kCGLineJoinRound;
        [arrow stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIColor *)progressColor
{
    return self.dark ? [UIColor colorWithRed:0.35 green:0.55 blue:0.95 alpha:0.35] : [UIColor colorWithRed:0.25 green:0.5 blue:0.9 alpha:0.22];
}

- (UIImage *)lockImage
{
    return [self cachedImage:@"lock" builder:^UIImage *{
        CGSize size = CGSizeMake(16, 18);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = self.dark ? RGB(200, 200, 206) : RGB(90, 90, 100);
        UIBezierPath *shackle = [UIBezierPath bezierPath];
        [shackle moveToPoint:CGPointMake(4.5, 8)];
        [shackle addLineToPoint:CGPointMake(4.5, 5.5)];
        [shackle addArcWithCenter:CGPointMake(8, 5.5) radius:3.5 startAngle:M_PI endAngle:0 clockwise:YES];
        [shackle addLineToPoint:CGPointMake(11.5, 8)];
        shackle.lineWidth = 1.8;
        [color setStroke];
        [shackle stroke];
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 8, 12, 9) cornerRadius:2];
        [color setFill];
        [body fill];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)readerImage
{
    return [self cachedImage:@"reader" builder:^UIImage *{
        CGSize size = CGSizeMake(18, 18);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIColor *color = self.dark ? RGB(200, 200, 206) : RGB(70, 110, 180);
        [color setFill];
        CGFloat widths[4] = { 14, 10, 14, 8 };
        for (int i = 0; i < 4; i++) [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3 + i * 3.5, widths[i], 2) cornerRadius:1] fill];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)plusImage
{
    return [self cachedImage:@"plus" builder:^UIImage *{
        CGSize size = CGSizeMake(18, 18);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(9, 3)];
        [p addLineToPoint:CGPointMake(9, 15)];
        [p moveToPoint:CGPointMake(3, 9)];
        [p addLineToPoint:CGPointMake(15, 9)];
        p.lineWidth = 2.5;
        p.lineCapStyle = kCGLineCapRound;
        [[self barTextColor] setStroke];
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)closeTabImage
{
    return [self cachedImage:@"closetab" builder:^UIImage *{
        CGSize size = CGSizeMake(14, 14);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(3.5, 3.5)];
        [p addLineToPoint:CGPointMake(10.5, 10.5)];
        [p moveToPoint:CGPointMake(10.5, 3.5)];
        [p addLineToPoint:CGPointMake(3.5, 10.5)];
        p.lineWidth = 2.0;
        p.lineCapStyle = kCGLineCapRound;
        [[[self tabTextColorSelected:YES] colorWithAlphaComponent:0.75] setStroke];
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

- (UIImage *)tabBarBackgroundImage
{
    return [self cachedImage:@"tabbar" builder:^UIImage *{
        if (self.dark) return BRBarImage(RGB(44, 44, 48), RGB(30, 30, 34), RGB(10, 10, 12), 30);
        return BRBarImage(RGB(196, 199, 208), RGB(178, 181, 192), RGB(140, 143, 152), 30);
    }];
}

- (UIColor *)tabTextColorSelected:(BOOL)selected
{
    if (self.dark) return selected ? RGB(240, 240, 242) : RGB(170, 170, 176);
    return selected ? RGB(40, 40, 46) : RGB(70, 72, 80);
}

// A tab: rounded top corners, open at the bottom, filled with a gradient and outlined.
- (UIImage *)tabImageSelected:(BOOL)selected
{
    NSString *key = selected ? @"tab-on" : @"tab-off";
    return [self cachedImage:key builder:^UIImage *{
        CGFloat w = 40, h = 30, r = 6;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(0.5, h)];
        [path addLineToPoint:CGPointMake(0.5, r + 0.5)];
        [path addArcWithCenter:CGPointMake(r + 0.5, r + 0.5) radius:r startAngle:M_PI endAngle:M_PI * 1.5 clockwise:YES];
        [path addLineToPoint:CGPointMake(w - r - 0.5, 0.5)];
        [path addArcWithCenter:CGPointMake(w - r - 0.5, r + 0.5) radius:r startAngle:M_PI * 1.5 endAngle:0 clockwise:YES];
        [path addLineToPoint:CGPointMake(w - 0.5, h)];
        UIColor *top, *bottom, *stroke;
        if (self.dark) {
            top = selected ? RGB(64, 64, 70) : RGB(48, 48, 52);
            bottom = selected ? RGB(52, 52, 58) : RGB(38, 38, 42);
            stroke = RGB(14, 14, 16);
        } else {
            top = selected ? RGB(252, 252, 253) : RGB(214, 216, 224);
            bottom = selected ? RGB(240, 240, 244) : RGB(196, 199, 208);
            stroke = RGB(130, 133, 142);
        }
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, path.CGPath);
        CGContextClip(ctx);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[ (id)top.CGColor, (id)bottom.CGColor ];
        CGFloat locs[2] = { 0.0, 1.0 };
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(0, h), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(cs);
        CGContextRestoreGState(ctx);
        [stroke setStroke];
        path.lineWidth = 1.0;
        [path stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [img resizableImageWithCapInsets:UIEdgeInsetsMake(r + 2, r + 2, 0, r + 2) resizingMode:UIImageResizingModeStretch];
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
