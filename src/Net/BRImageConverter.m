#import "BRImageConverter.h"
#import "BRCommon.h"

#include "webp/decode.h"

static void BRFreeWebPBuffer(void *info, const void *data, size_t size)
{
    WebPFree((void *)data);
}

@implementation BRImageConverter

+ (BOOL)looksLikeWebP:(NSData *)data
{
    if (data.length < 12) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    return b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' && b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P';
}

+ (NSData *)pngDataFromWebP:(NSData *)data
{
    if (![self looksLikeWebP:data]) return nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    int width = 0, height = 0;
    if (!WebPGetInfo((const uint8_t *)data.bytes, data.length, &width, &height) || width <= 0 || height <= 0) return nil;
    if ((long long)width * height > 16 * 1024 * 1024) {
        BRLog(@"WebP too large: %dx%d", width, height);
        return nil;
    }
    uint8_t *rgba = WebPDecodeRGBA((const uint8_t *)data.bytes, data.length, &width, &height);
    if (!rgba) {
        BRLog(@"WebP decode failed (%lu bytes)", (unsigned long)data.length);
        return nil;
    }
    size_t stride = (size_t)width * 4;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, rgba, stride * (size_t)height, BRFreeWebPBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, stride, colorSpace,
                                     kCGBitmapByteOrderDefault | kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
    CGImageRelease(image);
    if (png.length) {
        BRLog(@"WebP -> PNG: %lu -> %lu bytes (%dx%d) in %ld ms", (unsigned long)data.length, (unsigned long)png.length, width, height,
              (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000));
    }
    return png.length ? png : nil;
}

@end
