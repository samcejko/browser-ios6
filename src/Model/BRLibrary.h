#import <Foundation/Foundation.h>

// Bookmarks and browsing history, persisted as JSON in Library/Application Support (with a <file>.bak of how each run
// found them; a file that cannot be understood is set aside, never written over).
// Entries are dictionaries with "url", "title" and (history only) "time" (seconds since 1970); entries of any other
// shape read from disk are left out.
@interface BRLibrary : NSObject

+ (instancetype)shared;

// Writes the pending changes and returns when they are on disk (the app going to the background or ending: bookmark
// edits are written at once anyway, the history at most a second late).
- (void)flush;

@property (nonatomic, readonly) NSArray *bookmarks;     // in user order
@property (nonatomic, readonly) NSArray *history;       // newest first

- (BOOL)isBookmarked:(NSURL *)url;
- (void)addBookmark:(NSURL *)url title:(NSString *)title;
- (void)removeBookmark:(NSURL *)url;
- (void)removeBookmarkAtIndex:(NSUInteger)index;
- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to;
- (void)updateBookmarkAtIndex:(NSUInteger)index title:(NSString *)title url:(NSString *)url;   // nil keeps the old value

- (void)recordVisit:(NSURL *)url title:(NSString *)title;
- (void)removeHistoryAtIndex:(NSUInteger)index;
- (void)clearHistory;

@end
