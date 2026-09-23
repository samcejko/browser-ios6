#import <Foundation/Foundation.h>

// WebP images (not supported by iOS 6) are decoded with libwebp and re-encoded as PNG before WebKit sees them.
@interface BRImageConverter : NSObject

+ (BOOL)looksLikeWebP:(NSData *)data;
+ (NSData *)pngDataFromWebP:(NSData *)data;    // nil when the data is not WebP or cannot be decoded

@end
