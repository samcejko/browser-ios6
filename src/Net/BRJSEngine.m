#import "BRJSEngine.h"
#import "BRCommon.h"

#include <dlfcn.h>

// JavaScriptCore C API, resolved at runtime (no link-time dependency on the framework path).
typedef void *JSCtx;
typedef void *JSStr;
typedef const void *JSVal;
typedef void *JSObj;

static JSCtx (*p_JSGlobalContextCreate)(void *cls);
static void (*p_JSGlobalContextRelease)(JSCtx ctx);
static JSVal (*p_JSEvaluateScript)(JSCtx ctx, JSStr script, JSObj thisObject, JSStr sourceURL, int startingLineNumber, JSVal *exception);
static JSStr (*p_JSStringCreateWithCFString)(CFStringRef string);
static CFStringRef (*p_JSStringCopyCFString)(CFAllocatorRef alloc, JSStr string);
static void (*p_JSStringRelease)(JSStr string);
static JSStr (*p_JSValueToStringCopy)(JSCtx ctx, JSVal value, JSVal *exception);
static bool (*p_JSValueIsString)(JSCtx ctx, JSVal value);
static bool (*p_JSValueIsUndefined)(JSCtx ctx, JSVal value);
static bool (*p_JSValueIsNull)(JSCtx ctx, JSVal value);
static JSVal (*p_JSValueMakeString)(JSCtx ctx, JSStr string);
static JSVal (*p_JSValueMakeUndefined)(JSCtx ctx);
static JSObj (*p_JSContextGetGlobalObject)(JSCtx ctx);
static void (*p_JSObjectSetProperty)(JSCtx ctx, JSObj object, JSStr propertyName, JSVal value, unsigned attributes, JSVal *exception);
static void (*p_JSGarbageCollect)(JSCtx ctx);

static void *BRLookup(void *handle, const char *name)
{
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym && handle) sym = dlsym(handle, name);
    return sym;
}

static BOOL BRResolveJSC(void)
{
    static BOOL resolved = NO;
    static BOOL tried = NO;
    if (tried) return resolved;
    tried = YES;
    void *handle = NULL;
    if (!dlsym(RTLD_DEFAULT, "JSEvaluateScript")) {
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore",
            "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
        };
        for (int i = 0; i < 2 && !handle; i++) handle = dlopen(paths[i], RTLD_NOW);
        if (!handle) {
            BRLog(@"JavaScriptCore not found: %s", dlerror() ?: "?");
            return NO;
        }
    }
#define RESOLVE(name) do { p_##name = BRLookup(handle, #name); if (!p_##name) { BRLog(@"JavaScriptCore symbol missing: %s", #name); return NO; } } while (0)
    RESOLVE(JSGlobalContextCreate);
    RESOLVE(JSGlobalContextRelease);
    RESOLVE(JSEvaluateScript);
    RESOLVE(JSStringCreateWithCFString);
    RESOLVE(JSStringCopyCFString);
    RESOLVE(JSStringRelease);
    RESOLVE(JSValueToStringCopy);
    RESOLVE(JSValueIsString);
    RESOLVE(JSValueIsUndefined);
    RESOLVE(JSValueIsNull);
    RESOLVE(JSValueMakeString);
    RESOLVE(JSValueMakeUndefined);
    RESOLVE(JSContextGetGlobalObject);
    RESOLVE(JSObjectSetProperty);
    RESOLVE(JSGarbageCollect);
#undef RESOLVE
    resolved = YES;
    return YES;
}

@implementation BRJSEngine {
    dispatch_queue_t _queue;
    JSCtx _ctx;
    BOOL _available;
}

+ (instancetype)shared
{
    static BRJSEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[BRJSEngine alloc] init]; });
    return engine;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.samcejko.browser.js", DISPATCH_QUEUE_SERIAL);
        _available = BRResolveJSC();
    }
    return self;
}

- (BOOL)available
{
    return _available;
}

- (void)performSync:(dispatch_block_t)block
{
    dispatch_sync(_queue, block);
}

- (void)performAsync:(dispatch_block_t)block
{
    dispatch_async(_queue, block);
}

- (BOOL)ensureContext
{
    if (!_available) return NO;
    if (!_ctx) {
        _ctx = p_JSGlobalContextCreate(NULL);
        if (!_ctx) {
            BRLog(@"JSGlobalContextCreate failed");
            return NO;
        }
    }
    return YES;
}

- (NSString *)stringFromValue:(JSVal)value
{
    if (!value) return nil;
    JSVal exc = NULL;
    JSStr s = p_JSValueToStringCopy(_ctx, value, &exc);
    if (!s) return nil;
    CFStringRef cf = p_JSStringCopyCFString(kCFAllocatorDefault, s);
    p_JSStringRelease(s);
    return cf ? (__bridge_transfer NSString *)cf : nil;
}

- (void)logException:(JSVal)exception context:(NSString *)what
{
    NSString *text = [self stringFromValue:exception] ?: @"?";
    BRLog(@"JavaScript exception in %@: %@", what, text.length > 300 ? [text substringToIndex:300] : text);
}

- (BOOL)evaluateScript:(NSString *)script sourceName:(NSString *)name
{
    if (![self ensureContext] || !script) return NO;
    JSStr src = p_JSStringCreateWithCFString((__bridge CFStringRef)script);
    JSStr url = p_JSStringCreateWithCFString((__bridge CFStringRef)(name ?: @"script"));
    JSVal exc = NULL;
    p_JSEvaluateScript(_ctx, src, NULL, url, 1, &exc);
    p_JSStringRelease(src);
    p_JSStringRelease(url);
    if (exc) {
        [self logException:exc context:name ?: @"script"];
        return NO;
    }
    return YES;
}

- (NSString *)callFunction:(NSString *)function arguments:(NSArray *)arguments
{
    if (![self ensureContext] || !function.length) return nil;
    JSObj global = p_JSContextGetGlobalObject(_ctx);
    NSMutableString *call = [NSMutableString stringWithFormat:@"%@(", function];
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *argName = [NSString stringWithFormat:@"__brArg%lu", (unsigned long)i];
        id arg = arguments[i];
        BOOL isNull = [arg isKindOfClass:[NSNull class]];
        if (!isNull) {
            JSStr s = p_JSStringCreateWithCFString((__bridge CFStringRef)[arg description]);
            JSVal value = p_JSValueMakeString(_ctx, s);
            p_JSStringRelease(s);
            JSStr pn = p_JSStringCreateWithCFString((__bridge CFStringRef)argName);
            JSVal exc = NULL;
            p_JSObjectSetProperty(_ctx, global, pn, value, 0, &exc);
            p_JSStringRelease(pn);
        }
        if (i) [call appendString:@","];
        [call appendString:isNull ? @"null" : argName];
    }
    [call appendString:@")"];
    JSStr src = p_JSStringCreateWithCFString((__bridge CFStringRef)call);
    JSVal exc = NULL;
    JSVal result = p_JSEvaluateScript(_ctx, src, NULL, NULL, 1, &exc);
    p_JSStringRelease(src);
    // drop the argument strings again so the context does not keep large inputs alive
    for (NSUInteger i = 0; i < arguments.count; i++) {
        JSStr pn = p_JSStringCreateWithCFString((__bridge CFStringRef)[NSString stringWithFormat:@"__brArg%lu", (unsigned long)i]);
        JSVal e2 = NULL;
        p_JSObjectSetProperty(_ctx, global, pn, p_JSValueMakeUndefined(_ctx), 0, &e2);
        p_JSStringRelease(pn);
    }
    if (exc) {
        [self logException:exc context:function];
        return nil;
    }
    if (!result || p_JSValueIsUndefined(_ctx, result) || p_JSValueIsNull(_ctx, result)) return nil;
    return [self stringFromValue:result];
}

- (void)collectGarbage
{
    if (_ctx) p_JSGarbageCollect(_ctx);
}

@end
