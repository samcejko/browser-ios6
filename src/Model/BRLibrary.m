#import "BRLibrary.h"
#import "BRCommon.h"

static const NSUInteger BRMaxHistoryEntries = 500;

@implementation BRLibrary {
    NSMutableArray *_bookmarks;
    NSMutableArray *_history;
    NSString *_dir;
    BOOL _saveScheduled;
}

+ (instancetype)shared
{
    static BRLibrary *lib;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lib = [[BRLibrary alloc] init]; });
    return lib;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        _dir = [support stringByAppendingPathComponent:@"Browser"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:NULL];
        _bookmarks = [[self loadArray:@"bookmarks.json"] mutableCopy] ?: [NSMutableArray array];
        _history = [[self loadArray:@"history.json"] mutableCopy] ?: [NSMutableArray array];
        if (!_bookmarks.count && ![[NSUserDefaults standardUserDefaults] boolForKey:@"BRDefaultBookmarksCreated"]) {
            [_bookmarks addObjectsFromArray:@[
                @{ @"url": @"https://cs.wikipedia.org/", @"title": @"Wikipedie" },
                @{ @"url": @"https://lite.duckduckgo.com/lite/", @"title": @"DuckDuckGo Lite" },
                @{ @"url": @"https://news.ycombinator.com/", @"title": @"Hacker News" },
                @{ @"url": @"https://old.reddit.com/", @"title": @"Reddit" },
                @{ @"url": @"https://www.idnes.cz/", @"title": @"iDNES" },
                @{ @"url": @"https://www.seznam.cz/", @"title": @"Seznam" },
            ]];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"BRDefaultBookmarksCreated"];
            [self scheduleSave];
        }
    }
    return self;
}

#pragma mark - Persistence

- (NSArray *)loadArray:(NSString *)file
{
    NSData *d = [NSData dataWithContentsOfFile:[_dir stringByAppendingPathComponent:file]];
    if (!d) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [obj isKindOfClass:[NSArray class]] ? obj : nil;
}

- (void)scheduleSave
{
    if (_saveScheduled) return;
    _saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _saveScheduled = NO;
        [self saveNow];
    });
}

- (void)saveNow
{
    NSArray *b = [_bookmarks copy], *h = [_history copy];
    NSString *dir = _dir;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSData *bd = [NSJSONSerialization dataWithJSONObject:b options:0 error:NULL];
        NSData *hd = [NSJSONSerialization dataWithJSONObject:h options:0 error:NULL];
        if (bd) [bd writeToFile:[dir stringByAppendingPathComponent:@"bookmarks.json"] atomically:YES];
        if (hd) [hd writeToFile:[dir stringByAppendingPathComponent:@"history.json"] atomically:YES];
    });
}

#pragma mark - Bookmarks

- (NSArray *)bookmarks
{
    return [_bookmarks copy];
}

- (NSUInteger)bookmarkIndexOf:(NSURL *)url
{
    NSString *s = url.absoluteString;
    if (!s) return NSNotFound;
    for (NSUInteger i = 0; i < _bookmarks.count; i++) {
        if ([_bookmarks[i][@"url"] isEqualToString:s]) return i;
    }
    return NSNotFound;
}

- (BOOL)isBookmarked:(NSURL *)url
{
    return [self bookmarkIndexOf:url] != NSNotFound;
}

- (void)addBookmark:(NSURL *)url title:(NSString *)title
{
    if (!url.absoluteString.length || [self isBookmarked:url]) return;
    [_bookmarks addObject:@{ @"url": url.absoluteString, @"title": title.length ? title : (url.host ?: url.absoluteString) }];
    [self scheduleSave];
}

- (void)removeBookmark:(NSURL *)url
{
    NSUInteger i = [self bookmarkIndexOf:url];
    if (i != NSNotFound) [self removeBookmarkAtIndex:i];
}

- (void)removeBookmarkAtIndex:(NSUInteger)index
{
    if (index >= _bookmarks.count) return;
    [_bookmarks removeObjectAtIndex:index];
    [self scheduleSave];
}

- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to
{
    if (from >= _bookmarks.count || to >= _bookmarks.count) return;
    id item = _bookmarks[from];
    [_bookmarks removeObjectAtIndex:from];
    [_bookmarks insertObject:item atIndex:to];
    [self scheduleSave];
}

#pragma mark - History

- (NSArray *)history
{
    return [_history copy];
}

- (void)recordVisit:(NSURL *)url title:(NSString *)title
{
    NSString *s = url.absoluteString;
    if (!s.length || ![[url.scheme lowercaseString] hasPrefix:@"http"]) return;
    NSDictionary *last = _history.firstObject;
    if ([last[@"url"] isEqualToString:s]) {
        if (title.length && ![last[@"title"] isEqualToString:title]) {
            _history[0] = @{ @"url": s, @"title": title, @"time": last[@"time"] ?: @([[NSDate date] timeIntervalSince1970]) };
            [self scheduleSave];
        }
        return;
    }
    [_history insertObject:@{ @"url": s, @"title": title.length ? title : s, @"time": @([[NSDate date] timeIntervalSince1970]) } atIndex:0];
    while (_history.count > BRMaxHistoryEntries) [_history removeLastObject];
    [self scheduleSave];
}

- (void)removeHistoryAtIndex:(NSUInteger)index
{
    if (index >= _history.count) return;
    [_history removeObjectAtIndex:index];
    [self scheduleSave];
}

- (void)clearHistory
{
    [_history removeAllObjects];
    [self scheduleSave];
}

@end
