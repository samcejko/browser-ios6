#import "BRFontConverter.h"
#import "BRCommon.h"

#include <woff2/decode.h>
#include <string>

@implementation BRFontConverter

+ (BOOL)looksLikeWOFF2:(NSData *)data
{
    if (data.length < 4) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    return b[0] == 'w' && b[1] == 'O' && b[2] == 'F' && b[3] == '2';
}

+ (NSData *)ttfDataFromWOFF2:(NSData *)data
{
    if (![self looksLikeWOFF2:data]) return nil;
    std::string out;
    woff2::WOFF2StringOut sink(&out);
    sink.SetMaxSize(48u << 20);
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    bool ok = woff2::ConvertWOFF2ToTTF((const uint8_t *)data.bytes, data.length, &sink);
    if (!ok || out.empty()) {
        BRLog(@"WOFF2 decode failed (%lu bytes)", (unsigned long)data.length);
        return nil;
    }
    BRLog(@"WOFF2 -> TTF: %lu -> %lu bytes in %ld ms", (unsigned long)data.length, (unsigned long)out.size(),
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000));
    return [NSData dataWithBytes:out.data() length:out.size()];
}

@end
