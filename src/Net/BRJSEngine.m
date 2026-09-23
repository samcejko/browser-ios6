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
static JSVal (*p_JSObjectGetProperty)(JSCtx ctx, JSObj object, JSStr propertyName, JSVal *exception);
static JSObj (*p_JSValueToObject)(JSCtx ctx, JSVal value, JSVal *exception);
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
    RESOLVE(JSObjectGetProperty);
    RESOLVE(JSValueToObject);
    RESOLVE(JSGarbageCollect);
#undef RESOLVE
    resolved = YES;
    return YES;
}

NSString * const BRJSEngineDidResetNotification = @"BRJSEngineDidResetNotification";

@implementation BRJSEngine {
    NSThread *_thread;
    NSCondition *_condition;
    NSMutableArray *_queue;
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
        _available = BRResolveJSC();
        _condition = [[NSCondition alloc] init];
        _queue = [NSMutableArray array];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        _thread.name = @"com.samcejko.browser.js";
        _thread.stackSize = 16 * 1024 * 1024;   // Babel's traversal recurses far deeper than the 512 KB default allows
        [_thread start];
    }
    return self;
}

- (void)threadMain
{
    for (;;) {
        dispatch_block_t block = nil;
        [_condition lock];
        while (!_queue.count) [_condition wait];
        block = _queue[0];
        [_queue removeObjectAtIndex:0];
        [_condition unlock];
        @autoreleasepool {
            block();
        }
    }
}

- (BOOL)available
{
    return _available;
}

- (void)performAsync:(dispatch_block_t)block
{
    if (!block) return;
    [_condition lock];
    [_queue addObject:[block copy]];
    [_condition signal];
    [_condition unlock];
}

- (void)performSync:(dispatch_block_t)block
{
    if (!block) return;
    if ([NSThread currentThread] == _thread) {
        block();
        return;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [self performAsync:^{
        block();
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

- (void)resetContext
{
    [self performAsync:^{
        if (!_ctx) return;
        p_JSGlobalContextRelease(_ctx);
        _ctx = NULL;
        BRLog(@"JavaScript context released, process uses %ld MB", (long)BRResidentMemoryMB());
        [[NSNotificationCenter defaultCenter] postNotificationName:BRJSEngineDidResetNotification object:self];
    }];
}

// A bare JavaScriptCore context has no console, timers or globalThis; libraries expect them.
static NSString * const BRContextPrelude =
@"var globalThis = this; var self = this;"
@"var console = (function () { var c = {}, names = ['log','info','warn','error','debug','trace','dir','dirxml','table','group','groupEnd','groupCollapsed','time','timeEnd','timeLog','count','assert'];"
@"  for (var i = 0; i < names.length; i++) c[names[i]] = function () {}; return c; })();"
@"var setTimeout = function () { return 0; }, clearTimeout = function () {}, setInterval = setTimeout, clearInterval = clearTimeout;"
@"var queueMicrotask = function (f) { try { f(); } catch (e) {} };"
// RegExp constructor shim: the 2012 engine rejects the u, y and s flags; strip them with best-effort pattern rewrites
@"(function () { var Native = RegExp; try { new Native('a', 'u'); return; } catch (e) {}"
@"  function fromCodePoint(cp) { if (cp <= 0xFFFF) return '\\\\u' + ('0000' + cp.toString(16)).slice(-4); cp -= 0x10000;"
@"    return '\\\\u' + (0xD800 + (cp >> 10)).toString(16) + '\\\\u' + (0xDC00 + (cp & 0x3FF)).toString(16); }"
@"  var Shim = function RegExp(pattern, flags) {"
@"    if (pattern instanceof Native) { if (flags === undefined) return new Native(pattern); pattern = pattern.source; }"
@"    var f = flags === undefined ? '' : String(flags), src = String(pattern);"
@"    if (f.indexOf('u') >= 0) { f = f.replace(/u/g, ''); src = src.replace(/\\\\u\\{([0-9a-fA-F]+)\\}/g, function (m, h) { return fromCodePoint(parseInt(h, 16)); }); }"
@"    if (f.indexOf('s') >= 0) { f = f.replace(/s/g, ''); src = src.replace(/\\\\.|\\[(?:\\\\.|[^\\]])*\\]|\\./g, function (m) { return m === '.' ? '[\\\\s\\\\S]' : m; }); }"
@"    if (f.indexOf('y') >= 0) f = f.replace(/y/g, '');"
@"    if (f.indexOf('d') >= 0) f = f.replace(/d/g, '');"
@"    return new Native(src, f);"
@"  };"
@"  Shim.prototype = Native.prototype; Native.prototype.constructor = Shim;"
@"  RegExp = Shim;"
@"})();"
// natives that polyfill libraries like to replace with slow JavaScript versions; restored after each library load
@"var __brNatives = { JSON: { stringify: JSON.stringify, parse: JSON.parse },"
@"  String: { replace: String.prototype.replace, split: String.prototype.split, match: String.prototype.match, search: String.prototype.search,"
@"            trim: String.prototype.trim, indexOf: String.prototype.indexOf, slice: String.prototype.slice, toLowerCase: String.prototype.toLowerCase, charAt: String.prototype.charAt, charCodeAt: String.prototype.charCodeAt },"
@"  RegExp: { exec: RegExp.prototype.exec, test: RegExp.prototype.test, toString: RegExp.prototype.toString },"
@"  Array: { sort: Array.prototype.sort, slice: Array.prototype.slice, splice: Array.prototype.splice, concat: Array.prototype.concat, filter: Array.prototype.filter,"
@"           map: Array.prototype.map, forEach: Array.prototype.forEach, reduce: Array.prototype.reduce, reduceRight: Array.prototype.reduceRight, indexOf: Array.prototype.indexOf,"
@"           lastIndexOf: Array.prototype.lastIndexOf, join: Array.prototype.join, reverse: Array.prototype.reverse, some: Array.prototype.some, every: Array.prototype.every,"
@"           push: Array.prototype.push, unshift: Array.prototype.unshift },"
@"  Number: { toFixed: Number.prototype.toFixed, toPrecision: Number.prototype.toPrecision }, Function: { bind: Function.prototype.bind },"
@"  Object: { toString: Object.prototype.toString }, global: { parseInt: parseInt, parseFloat: parseFloat } };"
@"function __brRestoreNatives() {"
@"  var n = __brNatives, k;"
@"  for (k in n.JSON) JSON[k] = n.JSON[k];"
@"  for (k in n.String) String.prototype[k] = n.String[k];"
@"  for (k in n.RegExp) RegExp.prototype[k] = n.RegExp[k];"
@"  for (k in n.Array) Array.prototype[k] = n.Array[k];"
@"  for (k in n.Number) Number.prototype[k] = n.Number[k];"
@"  Function.prototype.bind = n.Function.bind; Object.prototype.toString = n.Object.toString;"
@"  parseInt = n.global.parseInt; parseFloat = n.global.parseFloat;"
@"}";

- (BOOL)ensureContext
{
    if (!_available) return NO;
    if (!_ctx) {
        _ctx = p_JSGlobalContextCreate(NULL);
        if (!_ctx) {
            BRLog(@"JSGlobalContextCreate failed");
            return NO;
        }
        [self evaluateScript:BRContextPrelude sourceName:@"prelude.js"];
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
    NSString *stack = nil;
    JSVal exc2 = NULL;
    JSObj obj = p_JSValueToObject(_ctx, exception, &exc2);
    if (obj) {
        JSStr name = p_JSStringCreateWithCFString(CFSTR("stack"));
        JSVal v = p_JSObjectGetProperty(_ctx, obj, name, &exc2);
        p_JSStringRelease(name);
        if (v && !p_JSValueIsUndefined(_ctx, v)) stack = [self stringFromValue:v];
    }
    if (stack.length > 1200) stack = [stack substringToIndex:1200];
    BRLog(@"JavaScript exception in %@: %@%@%@", what, text.length > 300 ? [text substringToIndex:300] : text, stack.length ? @"\n" : @"", stack ?: @"");
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
