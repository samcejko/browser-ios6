#import "BRJSEngine.h"
#import "BRCommon.h"
#import "BRMemory.h"

#include <dlfcn.h>
#include <malloc/malloc.h>

// JavaScriptCore C API, resolved at runtime (no link-time dependency on the framework path).
typedef void *JSCtx;
typedef void *JSStr;
typedef const void *JSVal;
typedef void *JSObj;

static JSCtx (*p_JSGlobalContextCreate)(void *cls);
// (optional) a context group per engine: without one this JavaScriptCore may give every context of an app that does
// not link it the same shared VM, which two threads must not use at once
static void *(*p_JSContextGroupCreate)(void);
static void (*p_JSContextGroupRelease)(void *group);
static JSCtx (*p_JSGlobalContextCreateInGroup)(void *group, void *cls);
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
// (optional) native functions for scripts: __brAvailableMB() lets the transpiler give up before iOS runs out of memory
typedef JSVal (*BRJSNativeFn)(JSCtx ctx, JSObj function, JSObj thisObject, size_t argc, const JSVal argv[], JSVal *exception);
static JSObj (*p_JSObjectMakeFunctionWithCallback)(JSCtx ctx, JSStr name, BRJSNativeFn callback);
static JSVal (*p_JSValueMakeNumber)(JSCtx ctx, double number);
// WTF::releaseFastMallocFreeMemory(): JavaScriptCore's malloc (shared with WebCore) keeps freed pages for reuse; a
// big transpile leaves ~45 MB of them resident after its heap is gone
static void (*p_releaseFastMallocFreeMemory)(void);

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
    p_JSContextGroupCreate = BRLookup(handle, "JSContextGroupCreate");
    p_JSContextGroupRelease = BRLookup(handle, "JSContextGroupRelease");
    p_JSObjectMakeFunctionWithCallback = BRLookup(handle, "JSObjectMakeFunctionWithCallback");
    p_JSValueMakeNumber = BRLookup(handle, "JSValueMakeNumber");
    p_releaseFastMallocFreeMemory = BRLookup(handle, "_ZN3WTF27releaseFastMallocFreeMemoryEv");
    if (!p_releaseFastMallocFreeMemory) BRLog(@"WTF::releaseFastMallocFreeMemory not found");
    p_JSGlobalContextCreateInGroup = BRLookup(handle, "JSGlobalContextCreateInGroup");
    resolved = YES;
    return YES;
}

NSString * const BRJSEngineDidResetNotification = @"BRJSEngineDidResetNotification";

static JSVal BRAvailableMBCallback(JSCtx ctx, JSObj function, JSObj thisObject, size_t argc, const JSVal argv[], JSVal *exception)
{
    return p_JSValueMakeNumber(ctx, (double)[BRMemory availableMB]);
}

@implementation BRJSEngine {
    NSThread *_thread;
    NSCondition *_condition;
    NSMutableArray *_queue;
    JSCtx _ctx;
    void *_group;       // this engine's context group (its VM and heap)
    BOOL _available;
    NSUInteger _uses;   // engine thread: counts evaluations, so an idle release can tell whether it was used since
}

+ (instancetype)shared
{
    static BRJSEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[BRJSEngine alloc] initWithName:@"com.samcejko.browser.js"]; });
    return engine;
}

+ (instancetype)transpiler
{
    static BRJSEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[BRJSEngine alloc] initWithName:@"com.samcejko.browser.js2"]; });
    return engine;
}

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (self) {
        _available = BRResolveJSC();
        _condition = [[NSCondition alloc] init];
        _queue = [NSMutableArray array];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        _thread.name = name;
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
    [self performAsync:^{ [self releaseContext:@"reset"]; }];
}

- (void)releaseContextNow
{
    [self releaseContext:@"requested"];
}

- (void)releaseWhenIdleFor:(NSTimeInterval)seconds aboveMB:(long)minimumMB
{
    NSUInteger uses = _uses;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self performAsync:^{
            if (uses != _uses || !_ctx) return;   // used again in the meantime (that use schedules its own release)
            if (minimumMB > 0 && BRResidentMemoryMB() < minimumMB) return;
            [self releaseContext:@"idle"];
        }];
    });
}

// engine thread
- (void)releaseContext:(NSString *)why
{
    if (!_ctx) return;
    long before = (long)BRResidentMemoryMB();
    // the group goes first: releasing the context then drops the last reference to the VM, which destroys the whole
    // heap at once (with the group kept, the context's objects are only garbage the heap holds on to)
    if (_group && p_JSContextGroupRelease) {
        p_JSContextGroupRelease(_group);
        _group = NULL;
    }
    p_JSGlobalContextRelease(_ctx);
    _ctx = NULL;
    long released = (long)BRResidentMemoryMB();
    if (p_releaseFastMallocFreeMemory) p_releaseFastMallocFreeMemory();
    size_t relief = malloc_zone_pressure_relief(NULL, 0);
    BRLog(@"JavaScript context %@ released (%@): %ld -> %ld MB, free malloc pages returned (%ld MB): %ld MB", _thread.name, why, before, released,
          (long)(relief >> 20), (long)BRResidentMemoryMB());
    [[NSNotificationCenter defaultCenter] postNotificationName:BRJSEngineDidResetNotification object:self];
}

+ (void)returnFreeMemory
{
    if (BRResolveJSC() && p_releaseFastMallocFreeMemory) p_releaseFastMallocFreeMemory();
    // (this JavaScriptCore may allocate through the system malloc: its free pages go back only on request)
    malloc_zone_pressure_relief(NULL, 0);
}

// The engine's tiers: the interpreter, the baseline JIT and the optimizing JIT for hot code. Their switches are
// JavaScriptCore's global JSC::Options (exported; JSC::initializeThreading sets the defaults once, and they are read
// whenever a function is compiled). The optimizing JIT of this engine miscompiles some of today's minified code
// (rohlik.cz: e[l++]+e[l++] read the same character twice and the page fell over; the interpreter alone got it right).
// BRJSCMode: 0 all tiers, 1 no optimizing JIT, 2 the interpreter only (debugging; regular expressions keep their JIT).
static const NSInteger BRJSCDefaultMode = 0;

+ (void)applyEngineTiers
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger mode = [d objectForKey:@"BRJSCMode"] ? [d integerForKey:@"BRJSCMode"] : BRJSCDefaultMode;
    void (*initialize)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "_ZN3JSC19initializeThreadingEv");
    unsigned *candidates = (unsigned *)dlsym(RTLD_DEFAULT, "_ZN3JSC7Options44maximumOptimizationCandidateInstructionCountE");
    int32_t *jitAfterWarmUp = (int32_t *)dlsym(RTLD_DEFAULT, "_ZN3JSC7Options26thresholdForJITAfterWarmUpE");
    int32_t *jitSoon = (int32_t *)dlsym(RTLD_DEFAULT, "_ZN3JSC7Options19thresholdForJITSoonE");
    if (!initialize || !candidates || !jitAfterWarmUp || !jitSoon) {
        BRLog(@"JavaScriptCore tiers: the engine's switches were not found, all tiers stay");
        return;
    }
    initialize();
    unsigned oldCandidates = *candidates;
    int32_t oldWarmUp = *jitAfterWarmUp;
    if (mode >= 1) *candidates = 0;   // no function is small enough for the optimizing JIT
    if (mode >= 2) { *jitAfterWarmUp = INT32_MAX; *jitSoon = INT32_MAX; }   // (the maximum: never)
    BRLog(@"JavaScriptCore tiers: mode %ld (optimizing JIT for functions up to %u -> %u instructions, baseline JIT after %d -> %d runs)",
          (long)mode, oldCandidates, *candidates, oldWarmUp, *jitAfterWarmUp);
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
@"  Object.prototype.toString = n.Object.toString;"
@"  parseInt = n.global.parseInt; parseFloat = n.global.parseFloat;"
@"  __brInstallJSHelpers();"
@"}"
// Contexts made through the C API get a tiny native-to-JS re-entry limit (16 levels) in this JSC. Callback
// based natives (forEach, map, replace with a function, sort with a comparator, bound functions) each count
// as a re-entry, so Babel's recursive traversal overflows. Pure JavaScript versions call back directly.
@"function __brInstallJSHelpers() {"
@"  var AP = Array.prototype, SP = String.prototype;"
@"  function len(o) { return o.length >>> 0; }"
@"  AP.forEach = function (cb, t) { var n = len(this); for (var i = 0; i < n; i++) if (i in this) cb.call(t, this[i], i, this); };"
@"  AP.map = function (cb, t) { var n = len(this), out = new Array(n); for (var i = 0; i < n; i++) if (i in this) out[i] = cb.call(t, this[i], i, this); return out; };"
@"  AP.filter = function (cb, t) { var n = len(this), out = []; for (var i = 0; i < n; i++) if (i in this) { var v = this[i]; if (cb.call(t, v, i, this)) out.push(v); } return out; };"
@"  AP.some = function (cb, t) { var n = len(this); for (var i = 0; i < n; i++) if (i in this && cb.call(t, this[i], i, this)) return true; return false; };"
@"  AP.every = function (cb, t) { var n = len(this); for (var i = 0; i < n; i++) if (i in this && !cb.call(t, this[i], i, this)) return false; return true; };"
@"  AP.reduce = function (cb, init) { var n = len(this), i = 0, acc; if (arguments.length >= 2) acc = init; else { while (i < n && !(i in this)) i++; if (i >= n) throw new TypeError('Reduce of empty array with no initial value'); acc = this[i++]; } for (; i < n; i++) if (i in this) acc = cb(acc, this[i], i, this); return acc; };"
@"  AP.reduceRight = function (cb, init) { var i = len(this) - 1, acc; if (arguments.length >= 2) acc = init; else { while (i >= 0 && !(i in this)) i--; if (i < 0) throw new TypeError('Reduce of empty array with no initial value'); acc = this[i--]; } for (; i >= 0; i--) if (i in this) acc = cb(acc, this[i], i, this); return acc; };"
@"  var nativeSort = __brNatives.Array.sort;"
@"  AP.sort = function (cmp) {"
@"    if (typeof cmp !== 'function') return nativeSort.call(this);"
@"    var n = len(this), a = new Array(n), tmp = new Array(n), i;"
@"    for (i = 0; i < n; i++) a[i] = this[i];"
@"    for (var w = 1; w < n; w *= 2) {"
@"      for (var lo = 0; lo < n; lo += 2 * w) {"
@"        var mid = Math.min(lo + w, n), hi = Math.min(lo + 2 * w, n), l = lo, r = mid, k = lo;"
@"        while (l < mid && r < hi) { if (cmp(a[l], a[r]) <= 0) tmp[k++] = a[l++]; else tmp[k++] = a[r++]; }"
@"        while (l < mid) tmp[k++] = a[l++]; while (r < hi) tmp[k++] = a[r++];"
@"      }"
@"      var sw = a; a = tmp; tmp = sw;"
@"    }"
@"    for (i = 0; i < n; i++) this[i] = a[i];"
@"    return this;"
@"  };"
@"  var nativeReplace = __brNatives.String.replace;"
@"  SP.replace = function (search, replacer) {"
@"    if (typeof replacer !== 'function') return nativeReplace.call(this, search, replacer);"
@"    var str = String(this), m, args;"
@"    if (!(search instanceof RegExp)) { search = String(search); var idx = str.indexOf(search); if (idx < 0) return str; return str.slice(0, idx) + String(replacer(search, idx, str)) + str.slice(idx + search.length); }"
@"    if (search.global) {"
@"      var out = '', last = 0; search.lastIndex = 0;"
@"      while ((m = search.exec(str)) !== null) {"
@"        args = m.slice(0); args.push(m.index, str);"
@"        out += str.slice(last, m.index) + String(replacer.apply(null, args));"
@"        last = m.index + m[0].length;"
@"        if (m[0] === '') { if (search.lastIndex >= str.length) break; search.lastIndex++; }"
@"      }"
@"      search.lastIndex = 0;"
@"      return out + str.slice(last);"
@"    }"
@"    m = search.exec(str); if (!m) return str;"
@"    args = m.slice(0); args.push(m.index, str);"
@"    return str.slice(0, m.index) + String(replacer.apply(null, args)) + str.slice(m.index + m[0].length);"
@"  };"
@"  if (typeof __brJSBind === 'function') Function.prototype.bind = __brJSBind;"
@"}"
// closure based bind: calls into a bound function are plain JavaScript calls
@"var __brJSBind = function bind(thisArg) {"
@"  var fn = this, bound = Array.prototype.slice.call(arguments, 1);"
@"  if (typeof fn !== 'function') throw new TypeError('Bind must be called on a function');"
@"  var F = function () { var args = bound.concat(Array.prototype.slice.call(arguments));"
@"    if (this instanceof F) { var obj = Object.create(fn.prototype || Object.prototype); var r = fn.apply(obj, args); return (r !== null && typeof r === 'object') || typeof r === 'function' ? r : obj; }"
@"    return fn.apply(thisArg, args); };"
@"  if (fn.prototype) F.prototype = fn.prototype;"
@"  return F;"
@"};"
@"__brInstallJSHelpers();";

- (BOOL)ensureContext
{
    if (!_available) return NO;
    if (!_ctx) {
        if (p_JSContextGroupCreate && p_JSGlobalContextCreateInGroup) {
            if (!_group) _group = p_JSContextGroupCreate();
            _ctx = _group ? p_JSGlobalContextCreateInGroup(_group, NULL) : NULL;
        }
        if (!_ctx) _ctx = p_JSGlobalContextCreate(NULL);
        if (!_ctx) {
            BRLog(@"JSGlobalContextCreate failed");
            return NO;
        }
        [self evaluateScript:BRContextPrelude sourceName:@"prelude.js"];
        if (p_JSObjectMakeFunctionWithCallback && p_JSValueMakeNumber) {
            JSStr name = p_JSStringCreateWithCFString(CFSTR("__brAvailableMB"));
            JSObj fn = p_JSObjectMakeFunctionWithCallback(_ctx, name, BRAvailableMBCallback);
            JSVal exc = NULL;
            if (fn) p_JSObjectSetProperty(_ctx, p_JSContextGetGlobalObject(_ctx), name, (JSVal)fn, 0, &exc);
            p_JSStringRelease(name);
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
    _uses++;
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
    _uses++;
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
