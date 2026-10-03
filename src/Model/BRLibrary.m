#import "BRLibrary.h"
#import "BRCommon.h"
#include <errno.h>
#include <unistd.h>

static const NSUInteger BRMaxHistoryEntries = 500;

// A list as read from disk: a bare array (what every build writes) or {"items": [...]} (room for a later format that
// this build can still read). nil for anything else.
static NSArray *BRLibraryItems(NSData *data)
{
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([obj isKindOfClass:[NSDictionary class]]) obj = ((NSDictionary *)obj)[@"items"];
    return [obj isKindOfClass:[NSArray class]] ? obj : nil;
}

// Only entries this build understands: a dictionary with a non-empty url string, a string title (the url when it has
// none) and a number time (history). Anything else - a hand edit, a later format - would crash the code that shows the
// lists; *rejected counts what was left out.
static NSMutableArray *BRValidEntries(NSArray *items, NSUInteger *rejected)
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
    *rejected = 0;
    for (id item in items) {
        NSDictionary *e = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        NSString *url = e[@"url"];
        if (![url isKindOfClass:[NSString class]] || !url.length) { (*rejected)++; continue; }
        id title = e[@"title"], stamp = e[@"time"];
        if ([title isKindOfClass:[NSString class]] && (!stamp || [stamp isKindOfClass:[NSNumber class]])) { [out addObject:e]; continue; }
        NSMutableDictionary *fixed = [e mutableCopy];
        if (![title isKindOfClass:[NSString class]]) fixed[@"title"] = url;
        if (stamp && ![stamp isKindOfClass:[NSNumber class]]) [fixed removeObjectForKey:@"time"];
        [out addObject:[fixed copy]];
    }
    return out;
}

// Page titles can end in half of a surrogate pair (a title cut in the middle of an emoji); such a string may not make
// the round trip through JSON, and a list that cannot be written or read back is lost. The half becomes U+FFFD.
static NSString *BRWholeCharacters(NSString *s)
{
    NSUInteger n = s.length;
    if (!n) return s;
    NSMutableData *buffer = [NSMutableData dataWithLength:n * sizeof(unichar)];
    unichar *c = buffer.mutableBytes;
    [s getCharacters:c range:NSMakeRange(0, n)];
    BOOL changed = NO;
    for (NSUInteger i = 0; i < n; i++) {
        BOOL high = c[i] >= 0xD800 && c[i] <= 0xDBFF, low = c[i] >= 0xDC00 && c[i] <= 0xDFFF;
        if (high && i + 1 < n && c[i + 1] >= 0xDC00 && c[i + 1] <= 0xDFFF) { i++; continue; }
        if (high || low) { c[i] = 0xFFFD; changed = YES; }
    }
    return changed ? [NSString stringWithCharacters:c length:n] : s;
}

@implementation BRLibrary {
    NSMutableArray *_bookmarks;
    NSMutableArray *_history;
    NSString *_dir;
    dispatch_queue_t _io;          // every write, in order
    BOOL _saveScheduled;
    BOOL _bookmarksDirty, _historyDirty;
    BOOL _keepBookmarks, _keepHistory;           // the file could not be read: never written this run
    BOOL _bookmarksBackedUp, _historyBackedUp;   // (on _io) this run's first write made <file>.bak
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
        // (the folder keeps the name of the earlier builds: the user's bookmarks are there)
        _dir = [support stringByAppendingPathComponent:@"Browser"];
        _io = dispatch_queue_create("com.samcejko.browser.library", DISPATCH_QUEUE_SERIAL);
        [[NSFileManager defaultManager] createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:NULL];
        _bookmarks = [self loadList:@"bookmarks.json" keep:&_keepBookmarks];
        _history = [self loadList:@"history.json" keep:&_keepHistory];
        if (!_bookmarks.count && !_keepBookmarks && ![[NSUserDefaults standardUserDefaults] boolForKey:@"BRDefaultBookmarksCreated"]) {
            // (in the language the app shows: Czech sites only for a Czech user interface)
            BOOL czech = [[[[NSBundle mainBundle] preferredLocalizations] firstObject] hasPrefix:@"cs"];
            [_bookmarks addObjectsFromArray:czech ? @[
                @{ @"url": @"https://cs.wikipedia.org/", @"title": @"Wikipedie" },
                @{ @"url": @"https://lite.duckduckgo.com/lite/", @"title": @"DuckDuckGo Lite" },
                @{ @"url": @"https://news.ycombinator.com/", @"title": @"Hacker News" },
                @{ @"url": @"https://old.reddit.com/", @"title": @"Reddit" },
                @{ @"url": @"https://www.idnes.cz/", @"title": @"iDNES" },
                @{ @"url": @"https://www.seznam.cz/", @"title": @"Seznam" },
            ] : @[
                @{ @"url": @"https://en.wikipedia.org/", @"title": @"Wikipedia" },
                @{ @"url": @"https://lite.duckduckgo.com/lite/", @"title": @"DuckDuckGo Lite" },
                @{ @"url": @"https://news.ycombinator.com/", @"title": @"Hacker News" },
                @{ @"url": @"https://old.reddit.com/", @"title": @"Reddit" },
            ]];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"BRDefaultBookmarksCreated"];
            _bookmarksDirty = YES;
            [self scheduleSave];
        }
    }
    return self;
}

#pragma mark - Persistence

- (NSString *)asidePath:(NSString *)file reason:(NSString *)reason
{
    return [_dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@-%.0f", file, reason, [[NSDate date] timeIntervalSince1970]]];
}

// One list from disk. One bad read used to empty the list, and the next page visit saved the empty list over the
// user's bookmarks. Now a file whose content cannot be understood is renamed aside (never written over) and the copy
// the last run made (<file>.bak) is read instead; a file that cannot be read at all (an I/O error, not its content)
// stays where it is and *keep is set: that list is not written this run.
- (NSMutableArray *)loadList:(NSString *)file keep:(BOOL *)keep
{
    *keep = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [_dir stringByAppendingPathComponent:file];
    NSString *source = path;
    NSArray *items = nil;
    if ([fm fileExistsAtPath:path]) {
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
        if (!data) {
            BRLog(@"Library: %@ could not be read (%@): left as it is and not saved this run", file, error.localizedDescription);
            *keep = YES;
            return [NSMutableArray array];
        }
        items = BRLibraryItems(data);
        if (!items) {
            NSString *aside = [self asidePath:file reason:@"damaged"];
            if (![fm moveItemAtPath:path toPath:aside error:&error]) {
                BRLog(@"Library: %@ is damaged and could not be set aside (%@): not saved this run", file, error.localizedDescription);
                *keep = YES;
                return [NSMutableArray array];
            }
            BRLog(@"Library: %@ is damaged, kept as %@", file, aside.lastPathComponent);
        }
    }
    if (!items) {
        source = [path stringByAppendingString:@".bak"];
        NSData *data = [NSData dataWithContentsOfFile:source];
        items = data ? BRLibraryItems(data) : nil;
        if (items) BRLog(@"Library: %@ read from its backup (%lu entries)", file, (unsigned long)items.count);
    }
    NSUInteger rejected = 0;
    NSMutableArray *list = BRValidEntries(items, &rejected);
    if (rejected) {
        // (entries of a kind this build does not know: the next save leaves them out, a copy of the file keeps them)
        NSString *aside = [self asidePath:file reason:@"unknown"];
        [fm copyItemAtPath:source toPath:aside error:NULL];
        BRLog(@"Library: %lu entries of %@ not understood, the file is kept as %@", (unsigned long)rejected, file, aside.lastPathComponent);
    }
    return list;
}

// (on _io) The first write of a run keeps the file as the run found it as <file>.bak: when a write goes wrong (the
// iPad panics before the data reaches the disk), the next start reads that. A hard link to the old file, not a copy:
// its data was written by an earlier run and is on the disk long since, while a copy written a moment before the new
// file was as far from the disk as the new file - a panic could leave both empty, and the bookmarks are often written
// only once a run. The atomic write below puts a new file under the name and leaves the old one to .bak. (When the
// file is not there - set aside as damaged - the .bak it was read from stays as it is.)
- (void)writeList:(NSArray *)list toFile:(NSString *)file backUp:(BOOL)backUp
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:list options:0 error:NULL];
    if (!json) {
        BRLog(@"Library: %@ could not be serialized", file);
        return;
    }
    NSString *path = [_dir stringByAppendingPathComponent:file];
    if (backUp && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *bak = [path stringByAppendingString:@".bak"];
        unlink([bak fileSystemRepresentation]);
        if (link([path fileSystemRepresentation], [bak fileSystemRepresentation]) != 0) {
            int err = errno;
            BRLog(@"Library: no link for %@.bak (errno %d), copied", file, err);
            NSData *old = [NSData dataWithContentsOfFile:path];
            if (old) [old writeToFile:bak atomically:YES];
        }
    }
    NSError *error = nil;
    if (![json writeToFile:path options:NSDataWritingAtomic error:&error]) BRLog(@"Library: writing %@ failed (%@)", file, error.localizedDescription);
}

// Writes the lists that changed since the last write (only those: a page visit no longer rewrites the bookmarks).
// wait: returns when everything handed to the queue so far is on disk.
- (void)writePending:(BOOL)wait
{
    NSArray *bookmarks = _bookmarksDirty && !_keepBookmarks ? [_bookmarks copy] : nil;
    NSArray *history = _historyDirty && !_keepHistory ? [_history copy] : nil;
    _bookmarksDirty = _historyDirty = NO;
    if (!bookmarks && !history && !wait) return;
    dispatch_block_t work = ^{
        if (bookmarks) {
            [self writeList:bookmarks toFile:@"bookmarks.json" backUp:!_bookmarksBackedUp];
            _bookmarksBackedUp = YES;
        }
        if (history) {
            [self writeList:history toFile:@"history.json" backUp:!_historyBackedUp];
            _historyBackedUp = YES;
        }
    };
    if (wait) dispatch_sync(_io, work);
    else dispatch_async(_io, work);
}

// The history changes on every page visit: written at most once a second.
- (void)scheduleSave
{
    if (_saveScheduled) return;
    _saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _saveScheduled = NO;
        [self writePending:NO];
    });
}

- (void)flush
{
    [self writePending:YES];
}

// Bookmark edits are rare and the user expects them kept: written at once, not after the history's delay (a memory
// kill right after a heavy page lost the bookmark just added).
- (void)bookmarksChanged
{
    _bookmarksDirty = YES;
    [self writePending:NO];
}

// What the user removed from the history must not stay behind in the backup or in a copy set aside.
- (void)historyRemoved
{
    _historyDirty = YES;
    [self writePending:NO];
    NSString *dir = _dir;
    dispatch_async(_io, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([name hasPrefix:@"history.json."]) [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
        }
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
    [_bookmarks addObject:@{ @"url": url.absoluteString, @"title": title.length ? BRWholeCharacters(title) : (url.host ?: url.absoluteString) }];
    [self bookmarksChanged];
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
    [self bookmarksChanged];
}

- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to
{
    if (from >= _bookmarks.count || to >= _bookmarks.count) return;
    id item = _bookmarks[from];
    [_bookmarks removeObjectAtIndex:from];
    [_bookmarks insertObject:item atIndex:to];
    [self bookmarksChanged];
}

- (void)updateBookmarkAtIndex:(NSUInteger)index title:(NSString *)title url:(NSString *)url
{
    if (index >= _bookmarks.count) return;
    NSDictionary *old = _bookmarks[index];
    NSString *newTitle = title.length ? BRWholeCharacters(title) : old[@"title"];
    NSString *newURL = url.length ? url : old[@"url"];
    _bookmarks[index] = @{ @"url": newURL ?: @"", @"title": newTitle ?: @"" };
    [self bookmarksChanged];
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
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BRPrivateMode"]) return;   // private browsing keeps no history
    title = BRWholeCharacters(title);
    NSDictionary *last = _history.firstObject;
    if ([last[@"url"] isEqualToString:s]) {
        if (title.length && ![last[@"title"] isEqualToString:title]) {
            _history[0] = @{ @"url": s, @"title": title, @"time": last[@"time"] ?: @([[NSDate date] timeIntervalSince1970]) };
            _historyDirty = YES;
            [self scheduleSave];
        }
        return;
    }
    [_history insertObject:@{ @"url": s, @"title": title.length ? title : s, @"time": @([[NSDate date] timeIntervalSince1970]) } atIndex:0];
    while (_history.count > BRMaxHistoryEntries) [_history removeLastObject];
    _historyDirty = YES;
    [self scheduleSave];
}

- (void)removeHistoryAtIndex:(NSUInteger)index
{
    if (index >= _history.count) return;
    [_history removeObjectAtIndex:index];
    [self historyRemoved];
}

- (void)clearHistory
{
    [_history removeAllObjects];
    _keepHistory = NO;   // (a history file this run could not read may go now: the user asked for all of it to go)
    [self historyRemoved];
}

@end
