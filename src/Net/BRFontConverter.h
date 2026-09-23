#import <Foundation/Foundation.h>

// WOFF2 fonts (the only format many sites still ship) are not understood by iOS 6; they are converted
// to plain TrueType/OpenType with Google's woff2 decoder before WebKit sees them.
@interface BRFontConverter : NSObject

+ (BOOL)looksLikeWOFF2:(NSData *)data;
+ (NSData *)ttfDataFromWOFF2:(NSData *)data;    // nil when the data is not WOFF2 or cannot be decoded

@end
