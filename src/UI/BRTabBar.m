#import "BRTabBar.h"
#import "BRTheme.h"
#import "BRCommon.h"

static const CGFloat BRTabMinWidth = 96;
static const CGFloat BRTabMaxWidth = 230;
static const CGFloat BRTabGap = 2;
static const CGFloat BRPlusWidth = 34;

@interface BRTabBar ()
@property (nonatomic, strong) UIImageView *background;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, strong) NSMutableArray *tabButtons;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) NSArray *titles;
@property (nonatomic) NSUInteger selectedIndex;
@end

@implementation BRTabBar

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.background = [[UIImageView alloc] initWithFrame:self.bounds];
        self.background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:self.background];
        self.scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        self.scrollView.showsHorizontalScrollIndicator = NO;
        self.scrollView.showsVerticalScrollIndicator = NO;
        self.scrollView.alwaysBounceHorizontal = NO;
        self.scrollView.scrollsToTop = NO;
        [self addSubview:self.scrollView];
        self.plusButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.plusButton addTarget:self action:@selector(plusTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.plusButton];
        self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        self.tabButtons = [NSMutableArray array];
        self.titles = @[];
        [self applyTheme];
    }
    return self;
}

- (void)applyTheme
{
    BRTheme *theme = [BRTheme shared];
    self.background.image = [theme tabBarBackgroundImage];
    [self.plusButton setImage:[theme plusImage] forState:UIControlStateNormal];
    [self.closeButton setImage:[theme closeTabImage] forState:UIControlStateNormal];
    [self rebuild];
}

- (void)setTitles:(NSArray *)titles selectedIndex:(NSUInteger)index
{
    self.titles = titles ?: @[];
    self.selectedIndex = index;
    [self rebuild];
}

- (void)rebuild
{
    for (UIView *v in self.tabButtons) [v removeFromSuperview];
    [self.tabButtons removeAllObjects];
    [self.closeButton removeFromSuperview];
    BRTheme *theme = [BRTheme shared];
    for (NSUInteger i = 0; i < self.titles.count; i++) {
        BOOL selected = i == self.selectedIndex;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = (NSInteger)i;
        [b setTitle:self.titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        b.titleLabel.shadowOffset = CGSizeMake(0, 1);
        [b setTitleColor:selected ? [theme tabTextColorSelected:YES] : [theme tabTextColorSelected:NO] forState:UIControlStateNormal];
        [b setTitleShadowColor:[theme barTextShadowColor] forState:UIControlStateNormal];
        [b setBackgroundImage:[theme tabImageSelected:selected] forState:UIControlStateNormal];
        b.titleEdgeInsets = UIEdgeInsetsMake(0, selected ? 22 : 10, 0, 10);
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:b];
        [self.tabButtons addObject:b];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    CGFloat width = self.bounds.size.width;
    self.plusButton.frame = CGRectMake(width - BRPlusWidth, 0, BRPlusWidth, h);
    CGFloat scrollWidth = width - BRPlusWidth - 6;
    self.scrollView.frame = CGRectMake(6, 0, scrollWidth, h);
    NSUInteger count = self.tabButtons.count;
    if (!count) return;
    CGFloat tabWidth = floor((scrollWidth - BRTabGap * (count - 1)) / count);
    tabWidth = MAX(BRTabMinWidth, MIN(BRTabMaxWidth, tabWidth));
    CGFloat x = 0;
    for (NSUInteger i = 0; i < count; i++) {
        UIButton *b = self.tabButtons[i];
        BOOL selected = i == self.selectedIndex;
        // the selected tab is a point taller so that it covers the bar's bottom line and joins the page
        b.frame = CGRectMake(x, selected ? 3 : 5, tabWidth, selected ? h - 3 : h - 5);
        if (selected) {
            self.closeButton.frame = CGRectMake(x, 4, 24, h - 4);
            [self.scrollView addSubview:self.closeButton];
        }
        x += tabWidth + BRTabGap;
    }
    self.scrollView.contentSize = CGSizeMake(MAX(x - BRTabGap, scrollWidth), h);
    if (self.selectedIndex < count) {
        CGRect sel = ((UIButton *)self.tabButtons[self.selectedIndex]).frame;
        [self.scrollView scrollRectToVisible:CGRectInset(sel, -8, 0) animated:NO];
    }
}

- (void)tabTapped:(UIButton *)button
{
    [self.delegate tabBar:self didSelectTabAtIndex:(NSUInteger)button.tag];
}

- (void)closeTapped
{
    [self.delegate tabBar:self didCloseTabAtIndex:self.selectedIndex];
}

- (void)plusTapped
{
    [self.delegate tabBarDidRequestNewTab:self];
}

@end
