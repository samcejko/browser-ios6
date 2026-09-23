#import <Foundation/Foundation.h>

// Bookmarks and browsing history, persisted as JSON in Library/Application Support.
// Entries are dictionaries with "url", "title" and (history only) "time" (seconds since 1970).
@interface BRLibrary : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray *bookmarks;     // in user order
@property (nonatomic, readonly) NSArray *history;       // newest first

- (BOOL)isBookmarked:(NSURL *)url;
- (void)addBookmark:(NSURL *)url title:(NSString *)title;
- (void)removeBookmark:(NSURL *)url;
- (void)removeBookmarkAtIndex:(NSUInteger)index;
- (void)moveBookmarkFromIndex:(NSUInteger)from toIndex:(NSUInteger)to;

- (void)recordVisit:(NSURL *)url title:(NSString *)title;
- (void)removeHistoryAtIndex:(NSUInteger)index;
- (void)clearHistory;

@end
