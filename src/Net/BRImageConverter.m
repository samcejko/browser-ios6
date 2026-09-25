#import "BRImageConverter.h"
#import "BRCommon.h"

#include "webp/decode.h"
#include "webp/demux.h"
#include <stdlib.h>
#include <string.h>

static void BRFreeWebPBuffer(void *info, const void *data, size_t size)
{
    WebPFree((void *)data);
}

static void BRFreeMallocBuffer(void *info, const void *data, size_t size)
{
    free((void *)data);
}

// Animated WebP: the first frame composed on the canvas (the old engine shows a still image).
static uint8_t *BRFirstAnimationFrame(const uint8_t *bytes, size_t length, int *width, int *height)
{
    WebPAnimDecoderOptions options;
    if (!WebPAnimDecoderOptionsInit(&options)) return NULL;
    options.color_mode = MODE_RGBA;
    options.use_threads = 0;
    WebPData webpData;
    webpData.bytes = bytes;
    webpData.size = length;
    WebPAnimDecoder *decoder = WebPAnimDecoderNew(&webpData, &options);
    if (!decoder) return NULL;
    WebPAnimInfo info;
    uint8_t *frame = NULL;
    int timestamp = 0;
    uint8_t *copy = NULL;
    if (WebPAnimDecoderGetInfo(decoder, &info) && info.canvas_width > 0 && info.canvas_height > 0 &&
        (long long)info.canvas_width * info.canvas_height <= 16 * 1024 * 1024 &&
        WebPAnimDecoderGetNext(decoder, &frame, &timestamp) && frame) {
        size_t size = (size_t)info.canvas_width * info.canvas_height * 4;
        copy = (uint8_t *)malloc(size);
        if (copy) {
            memcpy(copy, frame, size);
            *width = (int)info.canvas_width;
            *height = (int)info.canvas_height;
        }
    }
    WebPAnimDecoderDelete(decoder);
    return copy;
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
    NSString *type = nil;
    NSData *out = [self imageDataFromWebP:data mimeType:&type allowJPEG:NO];
    return [type isEqualToString:@"image/png"] ? out : nil;
}

+ (NSData *)imageDataFromWebP:(NSData *)data mimeType:(NSString **)mimeType
{
    return [self imageDataFromWebP:data mimeType:mimeType allowJPEG:YES];
}

// Opaque stills become JPEG (quality 0.9): encoding a 2 MP PNG took 3-6 s on the iPad 2, a JPEG a fraction of that.
+ (NSData *)imageDataFromWebP:(NSData *)data mimeType:(NSString **)mimeType allowJPEG:(BOOL)allowJPEG
{
    if (![self looksLikeWebP:data]) return nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    int width = 0, height = 0;
    if (!WebPGetInfo((const uint8_t *)data.bytes, data.length, &width, &height) || width <= 0 || height <= 0) return nil;
    if ((long long)width * height > 16 * 1024 * 1024) {
        BRLog(@"WebP too large: %dx%d", width, height);
        return nil;
    }
    WebPBitstreamFeatures features;
    BOOL known = WebPGetFeatures((const uint8_t *)data.bytes, data.length, &features) == VP8_STATUS_OK;
    BOOL animated = known && features.has_animation;
    BOOL opaque = allowJPEG && known && !animated && !features.has_alpha;
    uint8_t *rgba = animated ? BRFirstAnimationFrame((const uint8_t *)data.bytes, data.length, &width, &height)
                             : WebPDecodeRGBA((const uint8_t *)data.bytes, data.length, &width, &height);
    if (!rgba) {
        BRLog(@"WebP decode failed (%lu bytes%@)", (unsigned long)data.length, animated ? @", animated" : @"");
        return nil;
    }
    size_t stride = (size_t)width * 4;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, rgba, stride * (size_t)height, animated ? BRFreeMallocBuffer : BRFreeWebPBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, stride, colorSpace,
                                     kCGBitmapByteOrderDefault | (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaLast), provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    UIImage *ui = [UIImage imageWithCGImage:image];
    NSData *out = opaque ? UIImageJPEGRepresentation(ui, 0.9) : UIImagePNGRepresentation(ui);
    CGImageRelease(image);
    if (!out.length) return nil;
    if (mimeType) *mimeType = opaque ? @"image/jpeg" : @"image/png";
    BRLog(@"WebP -> %@: %lu -> %lu bytes (%dx%d) in %ld ms", opaque ? @"JPEG" : @"PNG", (unsigned long)data.length, (unsigned long)out.length, width, height,
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000));
    return out;
}

@end
