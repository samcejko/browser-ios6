#import "BRSpeech.h"
#import "BRCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

// VSSpeechSynthesizer (iOS 6 VoiceServices, private): the selectors are called through objc_msgSend with explicit
// signatures and the return values of the setters and start/stop calls are ignored (they return an NSError or nothing).
static NSString * const BRVoiceServicesPath = @"/System/Library/PrivateFrameworks/VoiceServices.framework/VoiceServices";
static const NSUInteger BRMaxSpeechEvents = 400;

@implementation BRSpeech {
    Class _synthClass;
    BOOL _loaded;
    float _defaultRate, _defaultPitch, _defaultVolume;
    NSArray *_languages;
    NSData *_info;                    // cached infoJSON
    NSMutableArray *_events;          // guarded by @synchronized (self)
    NSInteger _seq;
    // one synthesizer per utterance (main thread only): its delegate callbacks then belong to that utterance
    id _current;
    NSMutableArray *_live;            // synthesizers still speaking or stopping
    NSMutableDictionary *_ids;        // synthesizer pointer -> utterance id
    NSMutableDictionary *_starts;     // synthesizer pointer -> start time
}

+ (instancetype)shared
{
    static BRSpeech *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[BRSpeech alloc] init];
        // the framework is loaded and asked for its voices on the main thread, where it later speaks
        dispatch_async(dispatch_get_main_queue(), ^{ [s loadEngine]; });
    });
    return s;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
        _live = [NSMutableArray array];
        _ids = [NSMutableDictionary dictionary];
        _starts = [NSMutableDictionary dictionary];
        _defaultRate = 1; _defaultPitch = 1; _defaultVolume = 1;
    }
    return self;
}

- (BOOL)available
{
    @synchronized (self) { return _synthClass != nil; }
}

static float BRFloatGetter(id obj, SEL sel, float fallback)
{
    if (![obj respondsToSelector:sel]) return fallback;
    float v = ((float (*)(id, SEL))objc_msgSend)(obj, sel);
    return (v > 0 && v < 1000) ? v : fallback;
}

// main thread
- (void)loadEngine
{
    if (_loaded) return;
    _loaded = YES;
    NSMutableArray *voices = [NSMutableArray array];
    if (dlopen(BRVoiceServicesPath.fileSystemRepresentation, RTLD_LAZY)) {
        Class cls = NSClassFromString(@"VSSpeechSynthesizer");
        if (cls && [cls instancesRespondToSelector:NSSelectorFromString(@"startSpeakingString:withLanguageCode:")]) {
            id probe = [[cls alloc] init];
            _defaultRate = BRFloatGetter(probe, NSSelectorFromString(@"rate"), 1);
            _defaultPitch = BRFloatGetter(probe, NSSelectorFromString(@"pitch"), 1);
            _defaultVolume = BRFloatGetter(probe, NSSelectorFromString(@"volume"), 1);
            SEL langs = NSSelectorFromString(@"availableLanguageCodes");
            id codes = [cls respondsToSelector:langs] ? ((id (*)(id, SEL))objc_msgSend)(cls, langs) : nil;
            if ([codes isKindOfClass:[NSArray class]]) _languages = [codes copy];
            @synchronized (self) { _synthClass = cls; }
        }
    }
    if (!_synthClass) BRLog(@"speech: VoiceServices is not available");
    NSArray *preferred = [NSLocale preferredLanguages];
    NSString *systemLang = preferred.count ? preferred[0] : @"en";
    NSLocale *display = [NSLocale currentLocale];
    BOOL defaultTaken = NO;
    for (NSString *code in _languages) {
        if (![code isKindOfClass:[NSString class]]) continue;
        NSString *tag = [code stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
        NSString *name = [display displayNameForKey:NSLocaleIdentifier value:[tag stringByReplacingOccurrencesOfString:@"-" withString:@"_"]] ?: tag;
        BOOL isDefault = !defaultTaken && [[tag lowercaseString] hasPrefix:[[systemLang substringToIndex:MIN((NSUInteger)2, systemLang.length)] lowercaseString]];
        if (isDefault) defaultTaken = YES;
        [voices addObject:@{ @"lang": tag, @"name": name, @"default": @(isDefault) }];
    }
    NSDictionary *info = @{ @"available": @(_synthClass != nil), @"voices": voices, @"rate": @(_defaultRate), @"pitch": @(_defaultPitch), @"volume": @(_defaultVolume) };
    NSData *json = [NSJSONSerialization dataWithJSONObject:info options:0 error:NULL];
    @synchronized (self) { _info = json; }
    BRLog(@"speech: %lu voices, rate %.2f pitch %.2f volume %.2f", (unsigned long)voices.count, _defaultRate, _defaultPitch, _defaultVolume);
}

- (NSData *)infoJSON
{
    @synchronized (self) {
        if (_info) return _info;
    }
    return [@"{\"available\":false,\"loading\":true,\"voices\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Events

- (void)addEvent:(NSString *)type utterance:(NSString *)uid charIndex:(NSInteger)charIndex elapsed:(NSTimeInterval)elapsed
{
    if (!uid) return;
    @synchronized (self) {
        _seq++;
        [_events addObject:@{ @"seq": @(_seq), @"id": uid, @"type": type, @"char": @(charIndex), @"elapsed": @(round(elapsed * 1000) / 1000) }];
        while (_events.count > BRMaxSpeechEvents) [_events removeObjectAtIndex:0];
    }
}

- (NSData *)eventsJSONSince:(NSInteger)since
{
    NSMutableArray *out = [NSMutableArray array];
    @synchronized (self) {
        for (NSDictionary *e in _events) if ([e[@"seq"] integerValue] > since) [out addObject:e];
    }
    return [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL] ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSValue *BRKey(id synth) { return [NSValue valueWithNonretainedObject:synth]; }

- (NSString *)idOf:(id)synth { return _ids[BRKey(synth)]; }
- (NSTimeInterval)elapsedOf:(id)synth { NSNumber *t = _starts[BRKey(synth)]; return t ? [NSDate timeIntervalSinceReferenceDate] - t.doubleValue : 0; }

- (void)forget:(id)synth
{
    if (!synth) return;
    [_ids removeObjectForKey:BRKey(synth)];
    [_starts removeObjectForKey:BRKey(synth)];
    [_live removeObject:synth];
    if (synth == _current) _current = nil;
}

#pragma mark - Speaking (requests arrive on the network threads and are carried out on the main thread)

// "cs" -> "cs-CZ" among the installed voices; nil when none fits (the engine then speaks the system language)
- (NSString *)languageCodeFor:(NSString *)lang
{
    if (!lang.length) return nil;
    NSString *want = [[lang stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
    NSString *prefixMatch = nil;
    for (NSString *code in _languages) {
        if (![code isKindOfClass:[NSString class]]) continue;
        NSString *c = [[code stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
        if ([c isEqualToString:want]) return code;
        NSString *primary = [want componentsSeparatedByString:@"-"][0];
        if (!prefixMatch && [c hasPrefix:[primary stringByAppendingString:@"-"]]) prefixMatch = code;
    }
    return prefixMatch;
}

- (void)speak:(NSString *)text utteranceId:(NSString *)uid lang:(NSString *)lang rate:(float)rate pitch:(float)pitch volume:(float)volume
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadEngine];
        if (!self->_synthClass || !uid.length) { [self addEvent:@"error" utterance:uid charIndex:0 elapsed:0]; return; }
        if (self->_current) [self stopSynth:self->_current];
        id synth = [[self->_synthClass alloc] init];
        if (!synth) { [self addEvent:@"error" utterance:uid charIndex:0 elapsed:0]; return; }
        ((void (*)(id, SEL, id))objc_msgSend)(synth, NSSelectorFromString(@"setDelegate:"), self);
        // the Web Speech API scales are relative to normal speech: the engine's own defaults are "normal"
        float r = MAX(0.1f, MIN(10.0f, rate > 0 ? rate : 1));
        float p = MAX(0.0f, MIN(2.0f, pitch >= 0 ? pitch : 1));
        float v = MAX(0.0f, MIN(1.0f, volume >= 0 ? volume : 1));
        SEL setRate = NSSelectorFromString(@"setRate:"), setPitch = NSSelectorFromString(@"setPitch:"), setVolume = NSSelectorFromString(@"setVolume:");
        if (r != 1 && [synth respondsToSelector:setRate]) ((void (*)(id, SEL, float))objc_msgSend)(synth, setRate, self->_defaultRate * r);
        if (p != 1 && [synth respondsToSelector:setPitch]) ((void (*)(id, SEL, float))objc_msgSend)(synth, setPitch, MAX(0.05f, self->_defaultPitch * p));
        if (v != 1 && [synth respondsToSelector:setVolume]) ((void (*)(id, SEL, float))objc_msgSend)(synth, setVolume, self->_defaultVolume * v);
        self->_ids[BRKey(synth)] = uid;
        self->_starts[BRKey(synth)] = @([NSDate timeIntervalSinceReferenceDate]);
        [self->_live addObject:synth];
        self->_current = synth;
        NSString *code = [self languageCodeFor:lang];
        [self addEvent:@"start" utterance:uid charIndex:0 elapsed:0];
        if (!text.length) { [self addEvent:@"end" utterance:uid charIndex:0 elapsed:0]; [self forget:synth]; return; }
        ((void (*)(id, SEL, id, id))objc_msgSend)(synth, NSSelectorFromString(@"startSpeakingString:withLanguageCode:"), text, code);
    });
}

- (void)stopSynth:(id)synth
{
    SEL stop = NSSelectorFromString(@"stopSpeakingAtNextBoundary:");
    if ([synth respondsToSelector:stop]) ((void (*)(id, SEL, int))objc_msgSend)(synth, stop, 0);
    // the utterance ends now for the page (the engine's own callback follows and is then ignored)
    NSString *uid = [self idOf:synth];
    if (uid) [self addEvent:@"end" utterance:uid charIndex:0 elapsed:[self elapsedOf:synth]];
    [_ids removeObjectForKey:BRKey(synth)];
    if (synth == _current) _current = nil;
}

- (void)cancel
{
    dispatch_async(dispatch_get_main_queue(), ^{ if (self->_current) [self stopSynth:self->_current]; });
}

- (void)pause
{
    dispatch_async(dispatch_get_main_queue(), ^{
        id synth = self->_current;
        SEL sel = NSSelectorFromString(@"pauseSpeakingAtNextBoundary:");
        if (!synth || ![synth respondsToSelector:sel]) return;
        ((void (*)(id, SEL, int))objc_msgSend)(synth, sel, 1);   // at the next word
        [self addEvent:@"pause" utterance:[self idOf:synth] charIndex:0 elapsed:[self elapsedOf:synth]];
    });
}

- (void)resume
{
    dispatch_async(dispatch_get_main_queue(), ^{
        id synth = self->_current;
        SEL sel = NSSelectorFromString(@"continueSpeaking");
        if (!synth || ![synth respondsToSelector:sel]) return;
        ((void (*)(id, SEL))objc_msgSend)(synth, sel);
        [self addEvent:@"resume" utterance:[self idOf:synth] charIndex:0 elapsed:[self elapsedOf:synth]];
    });
}

#pragma mark - VSSpeechSynthesizer delegate (main thread)

- (void)speechSynthesizer:(id)synth willSpeakRangeOfSpeechString:(NSRange)range
{
    [self addEvent:@"boundary" utterance:[self idOf:synth] charIndex:(NSInteger)range.location elapsed:[self elapsedOf:synth]];
}

- (void)speechSynthesizer:(id)synth didFinishSpeaking:(BOOL)finished withError:(id)error
{
    NSString *uid = [self idOf:synth];
    if (uid) [self addEvent:(error ? @"error" : @"end") utterance:uid charIndex:0 elapsed:[self elapsedOf:synth]];
    [self forget:synth];
}

- (void)speechSynthesizer:(id)synth didFinishSpeaking:(BOOL)finished phonemesSpoken:(id)phonemes withError:(id)error
{
    [self speechSynthesizer:synth didFinishSpeaking:finished withError:error];
}

@end
