#import "BRFontConverter.h"
#import "BRCommon.h"

#include <woff2/decode.h>
#include <string>
#include <vector>
#include <string.h>

static inline uint32_t rd32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

static uint32_t BRFontChecksum(const uint8_t *data, size_t len)
{
    uint32_t sum = 0;
    size_t words = (len + 3) / 4;
    for (size_t i = 0; i < words; i++) {
        uint32_t v = 0;
        for (int k = 0; k < 4; k++) {
            size_t idx = i * 4 + (size_t)k;
            v = (v << 8) | (idx < len ? data[idx] : 0);
        }
        sum += v;
    }
    return sum;
}

static bool BRIsSFNT(const uint8_t *p, size_t len)
{
    if (len < 12) return false;
    uint32_t tag = rd32(p);
    return tag == 0x00010000 || tag == 0x74727565 /* 'true' */ || tag == 0x4F54544F /* 'OTTO' */;
}

// Variable fonts (fvar/gvar tables) send the iOS 6 font parser into a path that takes about a
// minute and fails anyway ("FT_Get_MM_Var failed"). Dropping the variation tables leaves a
// static font at the default instance, which the old engine loads instantly.
// Returns false when the font is not variable (or cannot be made static, e.g. CFF2 outlines).
// Fonts with large OpenType layout tables (Inter's GPOS alone is hundreds of kilobytes) send the
// iOS 6 text layout through CoreText shaping for every line, which took MDN's home page over a
// minute. Above this size the layout tables are dropped as well: kerning and ligatures are lost,
// the page appears in seconds.
static const size_t BRHeavyLayoutTables = 24 * 1024;

static bool BRStripVariationTables(const std::string &in, std::string &out, int *dropped, bool *droppedLayout)
{
    const uint8_t *p = (const uint8_t *)in.data();
    size_t len = in.size();
    if (!BRIsSFNT(p, len)) return false;
    uint16_t numTables = rd16(p + 4);
    if (len < 12 + (size_t)numTables * 16) return false;
    static const char *variationTags[] = { "fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "STAT", NULL };
    static const char *layoutTags[] = { "GSUB", "GPOS", "GDEF", "BASE", "JSTF", "morx", "mort", "kerx", NULL };
    struct Rec { char tag[4]; uint32_t checksum, offset, length; };
    std::vector<Rec> all;
    bool hasFvar = false, hasCFF2 = false;
    size_t layoutBytes = 0;
    for (uint16_t i = 0; i < numTables; i++) {
        const uint8_t *r = p + 12 + (size_t)i * 16;
        Rec rec;
        memcpy(rec.tag, r, 4);
        rec.checksum = rd32(r + 4);
        rec.offset = rd32(r + 8);
        rec.length = rd32(r + 12);
        if (memcmp(rec.tag, "fvar", 4) == 0) hasFvar = true;
        if (memcmp(rec.tag, "CFF2", 4) == 0) hasCFF2 = true;
        if (memcmp(rec.tag, "GSUB", 4) == 0 || memcmp(rec.tag, "GPOS", 4) == 0) layoutBytes += rec.length;
        if ((size_t)rec.offset + rec.length > len) return false;
        all.push_back(rec);
    }
    bool dropLayout = layoutBytes > BRHeavyLayoutTables;
    if (hasCFF2) return false;
    if (!hasFvar && !dropLayout) return false;
    std::vector<Rec> keep;
    for (size_t i = 0; i < all.size(); i++) {
        bool drop = false;
        if (hasFvar) for (int k = 0; variationTags[k]; k++) if (memcmp(all[i].tag, variationTags[k], 4) == 0) drop = true;
        if (dropLayout) for (int k = 0; layoutTags[k]; k++) if (memcmp(all[i].tag, layoutTags[k], 4) == 0) drop = true;
        if (!drop) keep.push_back(all[i]);
    }
    *dropped = (int)(numTables - keep.size());
    *droppedLayout = dropLayout;
    uint16_t n = (uint16_t)keep.size();
    uint16_t entrySelector = 0;
    while ((1u << (entrySelector + 1)) <= n) entrySelector++;
    uint16_t searchRange = (uint16_t)((1u << entrySelector) * 16);
    uint16_t rangeShift = (uint16_t)(n * 16 - searchRange);
    out.assign(12 + (size_t)n * 16, '\0');
    uint8_t *o = (uint8_t *)&out[0];
    wr32(o, rd32(p));
    wr16(o + 4, n);
    wr16(o + 6, searchRange);
    wr16(o + 8, entrySelector);
    wr16(o + 10, rangeShift);
    size_t headOffset = 0;
    for (uint16_t i = 0; i < n; i++) {
        const Rec &rec = keep[i];
        while (out.size() % 4) out.push_back('\0');
        uint32_t newOffset = (uint32_t)out.size();
        out.append(in, rec.offset, rec.length);
        if (memcmp(rec.tag, "head", 4) == 0) headOffset = newOffset;
        uint8_t *r = (uint8_t *)&out[0] + 12 + (size_t)i * 16;   // after the append: the buffer may have moved
        memcpy(r, rec.tag, 4);
        wr32(r + 4, rec.checksum);
        wr32(r + 8, newOffset);
        wr32(r + 12, rec.length);
    }
    while (out.size() % 4) out.push_back('\0');
    if (headOffset && headOffset + 12 <= out.size()) {
        uint8_t *h = (uint8_t *)&out[0] + headOffset;
        wr32(h + 8, 0);
        uint32_t sum = BRFontChecksum((const uint8_t *)out.data(), out.size());
        wr32(h + 8, 0xB1B0AFBAu - sum);
    }
    return true;
}

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
    std::string flat;
    int dropped = 0;
    bool droppedLayout = false;
    bool trimmed = BRStripVariationTables(out, flat, &dropped, &droppedLayout);
    if (trimmed) out.swap(flat);
    BRLog(@"WOFF2 -> TTF: %lu -> %lu bytes in %ld ms%@", (unsigned long)data.length, (unsigned long)out.size(),
          (long)(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000),
          trimmed ? [NSString stringWithFormat:@" (%d tables dropped%@)", dropped, droppedLayout ? @", heavy OpenType layout removed" : @""] : @"");
    return [NSData dataWithBytes:out.data() length:out.size()];
}

+ (NSData *)staticFontDataFromSFNT:(NSData *)data
{
    if (data.length < 12 || !BRIsSFNT((const uint8_t *)data.bytes, data.length)) return nil;
    std::string in((const char *)data.bytes, data.length);
    std::string flat;
    int dropped = 0;
    bool droppedLayout = false;
    if (!BRStripVariationTables(in, flat, &dropped, &droppedLayout)) return nil;
    BRLog(@"TTF trimmed: %lu -> %lu bytes, %d tables dropped%@", (unsigned long)in.size(), (unsigned long)flat.size(), dropped, droppedLayout ? @", heavy OpenType layout removed" : @"");
    return [NSData dataWithBytes:flat.data() length:flat.size()];
}

@end
