/*
 * jsfix.js: ES2015-ES2022 syntax to ES5 for the JavaScriptCore of iOS 6.
 *
 * Runs in the app's own JavaScriptCore context on the rewriter thread (BRCSSRewriter), after acorn (MIT, fetched in CI
 * into Resources/js/acorn.js), and in desktop browsers for the tests (tools/jsfix-test.html). A script the engine
 * already parses (new Function) is left alone. Otherwise the acorn tree is analysed (scopes: block bindings that must
 * be renamed when they become function-scoped `var`s, loops whose closures capture per-iteration bindings) and printed
 * back as ES5 by a printer that lowers the newer syntax while it prints; subtrees without newer syntax are copied from
 * the source text. The helpers the output needs are prepended as function declarations (every script carries its own
 * copy; they are identical, so scripts redefining them do no harm).
 *
 * ES5 only in this file (it runs on the old engine itself).
 */
(function (root) {
    'use strict';

    var hasOwn = Object.prototype.hasOwnProperty;

    // ------------------------------------------------------------------------------------------------ runtime helpers
    // Written as functions here and emitted from their source text ("function __br_x" + everything from the "(").
    var RUNTIME = {
        // for...of: a function returning {done, value} steps (one reused object for arrays and array-likes)
        __br_iter: function (x) {
            if (x == null) throw new TypeError(x + ' is not iterable');
            var i = 0, step = { done: false, value: undefined }, it, S = typeof Symbol === 'function' ? Symbol.iterator : null;
            var list = function () { if (i < x.length) { step.value = x[i++]; return step; } step.done = true; step.value = undefined; return step; };
            if (Object.prototype.toString.call(x) === '[object Array]') return list;
            if (S && x[S] != null) { it = x[S](); return function () { return it.next(); }; }
            if (typeof x['@@iterator'] === 'function') { it = x['@@iterator'](); return function () { return it.next(); }; }
            if (typeof x === 'string') { x = x.match(/[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]/g) || []; return list; }
            if (typeof x.length === 'number') return list;
            throw new TypeError(x + ' is not iterable');
        },
        // [...x], f(...x): a fresh array from any iterable
        __br_spread: function (x) {
            if (Object.prototype.toString.call(x) === '[object Array]') return Array.prototype.slice.call(x);
            var next = __br_iter(x), a = [], s;
            while (!(s = next()).done) a.push(s.value);
            return a;
        },
        // array destructuring: arrays as they are, other iterables read up to n items (all when n < 0)
        __br_arr: function (x, n) {
            if (Object.prototype.toString.call(x) === '[object Array]') return x;
            var next = __br_iter(x), a = [], s;
            while ((n < 0 || a.length < n) && !(s = next()).done) a.push(s.value);
            return a;
        },
        // {a, ...rest} = src
        __br_objRest: function (src, keys) {
            if (src == null) throw new TypeError('Cannot destructure ' + src);
            var out = {}, ex = {}, k, i;
            for (i = 0; i < keys.length; i++) ex['$' + keys[i]] = 1;
            for (k in src) {
                if (!Object.prototype.hasOwnProperty.call(src, k) || ex['$' + k]) continue;
                if (k === '__proto__') Object.defineProperty(out, k, { value: src[k], enumerable: true, writable: true, configurable: true });
                else out[k] = src[k];
            }
            if (Object.getOwnPropertySymbols && typeof src === 'object') {
                var syms = Object.getOwnPropertySymbols(src);
                for (i = 0; i < syms.length; i++) if (!ex['$' + String(syms[i])] && Object.prototype.propertyIsEnumerable.call(src, syms[i])) out[syms[i]] = src[syms[i]];
            }
            return out;
        },
        // {...src}: own enumerable properties copied
        __br_assignOwn: function (target, src) {
            if (src == null) return target;
            var k, i;
            for (k in src) {
                if (!Object.prototype.hasOwnProperty.call(src, k)) continue;
                if (k === '__proto__') Object.defineProperty(target, k, { value: src[k], enumerable: true, writable: true, configurable: true });
                else target[k] = src[k];
            }
            if (Object.getOwnPropertySymbols && typeof src === 'object') {
                var syms = Object.getOwnPropertySymbols(src);
                for (i = 0; i < syms.length; i++) if (Object.prototype.propertyIsEnumerable.call(src, syms[i])) target[syms[i]] = src[syms[i]];
            }
            return target;
        },
        // object literal members after the first computed key or spread: [key, value, kind]* (0 data, 1 get, 2 set, 3 spread)
        __br_props: function (obj, list) {
            for (var i = 0; i < list.length; i += 3) {
                var k = list[i], v = list[i + 1], kind = list[i + 2];
                if (kind === 3) { __br_assignOwn(obj, v); continue; }
                if (kind === 0) { Object.defineProperty(obj, k, { value: v, enumerable: true, writable: true, configurable: true }); continue; }
                var old = Object.getOwnPropertyDescriptor(obj, k), d = { enumerable: true, configurable: true };
                if (old && !('value' in old)) { d.get = old.get; d.set = old.set; }
                if (kind === 1) d.get = v; else d.set = v;
                Object.defineProperty(obj, k, d);
            }
            return obj;
        },
        // tagged templates: the strings array with .raw, frozen, one per call site
        __br_tpl: function (s, r) {
            Object.defineProperty(s, 'raw', { value: r });
            if (Object.freeze) { Object.freeze(r); Object.freeze(s); }
            return s;
        },
        // class C extends S
        __br_inherits: function (C, S) {
            if (S !== null && !(S && (typeof S === 'function' || typeof S === 'object') && S.prototype !== undefined)) throw new TypeError('Class extends value ' + S + ' is not a constructor or null');
            C.prototype = Object.create(S === null ? null : S.prototype, { constructor: { value: C, writable: true, configurable: true } });
            if (S === null) return;
            try { C.__proto__ = S; } catch (e) {}
            // the DOM interface objects of this engine are not functions: the class keeps call/apply
            if (typeof S !== 'function') { C.call = Function.prototype.call; C.apply = Function.prototype.apply; C.bind = Function.prototype.bind; }
        },
        // methods and accessors: [key, value, kind]* (0 method, 1 get, 2 set), not enumerable
        __br_defs: function (o, list) {
            for (var i = 0; i < list.length; i += 3) {
                var k = list[i], v = list[i + 1], kind = list[i + 2], d;
                if (kind === 0) d = { value: v, writable: true, configurable: true, enumerable: false };
                else {
                    var old = Object.getOwnPropertyDescriptor(o, k);
                    d = { configurable: true, enumerable: false };
                    if (old && !('value' in old)) { d.get = old.get; d.set = old.set; }
                    if (kind === 1) d.get = v; else d.set = v;
                }
                try { Object.defineProperty(o, k, d); } catch (e) { if (kind === 0) o[k] = v; }
            }
        },
        __br_class: function (C, proto, stat) {
            if (proto) __br_defs(C.prototype, proto);
            if (stat) __br_defs(C, stat);
            try { Object.defineProperty(C, '__br_c', { value: 1 }); } catch (e) {}
            return C;
        },
        // native constructors (built-ins, DOM interfaces) cannot be called on an existing object
        __br_isNative: function (f) {
            if (typeof f !== 'function') return true;
            if (f.__br_c) return false;
            if (Object.prototype.hasOwnProperty.call(f, '__br_n')) return f.__br_n;
            var n;
            try { n = /\{\s*\[native code\]\s*\}\s*$/.test(Function.prototype.toString.call(f)); } catch (e) { n = true; }
            try { Object.defineProperty(f, '__br_n', { value: n }); } catch (e2) {}
            return n;
        },
        __br_new: function (C, a) {
            switch (a.length) {
                case 0: return new C();
                case 1: return new C(a[0]);
                case 2: return new C(a[0], a[1]);
                case 3: return new C(a[0], a[1], a[2]);
                case 4: return new C(a[0], a[1], a[2], a[3]);
            }
            return new (Function.prototype.bind.apply(C, [null].concat(Array.prototype.slice.call(a))))();
        },
        // super(...args) in a derived constructor: the object the constructor continues with
        __br_super: function (self, S, args) {
            if (S === null) return self;
            if (__br_isNative(S)) {
                var r = __br_new(S, args), p = Object.getPrototypeOf(self);
                if (p && r !== null && (typeof r === 'object' || typeof r === 'function')) { try { r.__proto__ = p; } catch (e) {} }
                return r;
            }
            var r2 = S.apply(self, args);
            return r2 !== null && (typeof r2 === 'object' || typeof r2 === 'function') ? r2 : self;
        },
        // private fields: not enumerable
        __br_defp: function (o, k, v) {
            Object.defineProperty(o, k, { value: v, writable: true, configurable: true });
            return v;
        },
        // regular expressions with named groups: exec results get .groups
        __br_named: function (re, names) {
            var exec = re.exec;
            re.exec = function (s) {
                var m = exec.call(this, s);
                if (m) { var g = {}; for (var k in names) if (Object.prototype.hasOwnProperty.call(names, k)) g[k] = m[names[k]]; m.groups = g; }
                return m;
            };
            return re;
        },
        // import(): the module loader of the page shim, when there is one
        __br_import: function (spec, base) {
            if (typeof window !== 'undefined' && window.__brImport) return window.__brImport(spec, base);
            return Promise.reject(new Error('import() is not supported: ' + spec));
        },
        // async function expressions: Object.getPrototypeOf(async function () {}).constructor is an AsyncFunction
        // (Alpine compiles its expressions with it) whose functions return promises
        __br_asyncFn: function (fn) {
            var G = typeof window !== 'undefined' ? window : {}, proto = G.__br_asyncProto;
            if (!proto) {
                var AsyncFunction = function AsyncFunction() {
                    var f = Function.apply(null, arguments);
                    var w = function () { try { return Promise.resolve(f.apply(this, arguments)); } catch (e) { return Promise.reject(e); } };
                    try { w.__proto__ = proto; } catch (e2) {}
                    return w;
                };
                proto = Object.create(Function.prototype);
                try { Object.defineProperty(proto, 'constructor', { value: AsyncFunction, writable: true, configurable: true }); } catch (e3) { proto.constructor = AsyncFunction; }
                AsyncFunction.prototype = proto;
                G.__br_asyncProto = proto;
            }
            try { fn.__proto__ = proto; } catch (e4) {}
            return fn;
        },
        // generators and async functions: the state machines the printer writes run on this (the protocol of
        // facebook/regenerator's runtime: wrap/async/awrap, context prev/next/sent, abrupt/finish/catch/delegateYield)
        __br_regen: function () {
            var G = typeof window !== 'undefined' ? window : {};
            if (G.__br_rtObj) return G.__br_rtObj;
            var hasOwn = Object.prototype.hasOwnProperty, Continue = {};
            var iterSym = typeof Symbol === 'function' && Symbol.iterator ? Symbol.iterator : '@@iterator';
            var Generator = function () {};
            var Gp = Generator.prototype;
            Gp[iterSym] = function () { return this; };
            if (iterSym !== '@@iterator') Gp['@@iterator'] = Gp[iterSym];
            Gp.toString = function () { return '[object Generator]'; };
            var tryCatch = function (fn, obj, arg) { try { return { type: 'normal', arg: fn.call(obj, arg) }; } catch (err) { return { type: 'throw', arg: err }; } };
            var values = function (iterable) {
                if (iterable) {
                    var m = iterable[iterSym] || iterable['@@iterator'];
                    if (m) return m.call(iterable);
                    if (typeof iterable.next === 'function') return iterable;
                    if (!isNaN(iterable.length)) {
                        var i = -1, next = function () { while (++i < iterable.length) { next.value = iterable[i]; next.done = false; return next; } next.value = undefined; next.done = true; return next; };
                        next.next = next;
                        return next;
                    }
                }
                throw new TypeError(iterable + ' is not iterable');
            };
            var resetEntry = function (entry) { var r = entry.completion || {}; r.type = 'normal'; delete r.arg; entry.completion = r; };
            var Context = function (tryLocs) {
                this.tryEntries = [{ tryLoc: 'root' }];
                for (var i = 0; i < tryLocs.length; i++) {
                    var locs = tryLocs[i], e = { tryLoc: locs[0] };
                    if (locs[1] != null) e.catchLoc = locs[1];
                    if (locs[2] != null) { e.finallyLoc = locs[2]; e.afterLoc = locs[3]; }
                    this.tryEntries.push(e);
                }
                this.prev = 0; this.next = 0; this.sent = undefined; this.done = false; this.delegate = null; this.method = 'next'; this.arg = undefined;
                for (var j = 0; j < this.tryEntries.length; j++) resetEntry(this.tryEntries[j]);
            };
            Context.prototype = {
                stop: function () {
                    this.done = true;
                    var root = this.tryEntries[0].completion;
                    if (root.type === 'throw') throw root.arg;
                    return this.rval;
                },
                dispatchException: function (exception) {
                    if (this.done) throw exception;
                    var ctx = this, record;
                    var handle = function (loc, caught) { record.type = 'throw'; record.arg = exception; ctx.next = loc; if (caught) { ctx.method = 'next'; ctx.arg = undefined; } return !!caught; };
                    for (var i = this.tryEntries.length - 1; i >= 0; --i) {
                        var entry = this.tryEntries[i];
                        record = entry.completion;
                        if (entry.tryLoc === 'root') return handle('end');
                        if (entry.tryLoc <= this.prev) {
                            var hasCatch = hasOwn.call(entry, 'catchLoc'), hasFinally = hasOwn.call(entry, 'finallyLoc');
                            if (hasCatch && this.prev < entry.catchLoc) return handle(entry.catchLoc, true);
                            if (hasFinally && this.prev < entry.finallyLoc) return handle(entry.finallyLoc);
                        }
                    }
                },
                abrupt: function (type, arg) {
                    var finallyEntry = null;
                    for (var i = this.tryEntries.length - 1; i >= 0; --i) {
                        var entry = this.tryEntries[i];
                        if (entry.tryLoc <= this.prev && hasOwn.call(entry, 'finallyLoc') && this.prev < entry.finallyLoc) { finallyEntry = entry; break; }
                    }
                    if (finallyEntry && (type === 'break' || type === 'continue') && finallyEntry.tryLoc <= arg && arg <= finallyEntry.finallyLoc) finallyEntry = null;
                    var record = finallyEntry ? finallyEntry.completion : {};
                    record.type = type;
                    record.arg = arg;
                    if (finallyEntry) { this.method = 'next'; this.next = finallyEntry.finallyLoc; return Continue; }
                    return this.complete(record);
                },
                complete: function (record, afterLoc) {
                    if (record.type === 'throw') throw record.arg;
                    if (record.type === 'break' || record.type === 'continue') this.next = record.arg;
                    else if (record.type === 'return') { this.rval = this.arg = record.arg; this.method = 'return'; this.next = 'end'; }
                    else if (record.type === 'normal' && afterLoc) this.next = afterLoc;
                    return Continue;
                },
                finish: function (finallyLoc) {
                    for (var i = this.tryEntries.length - 1; i >= 0; --i) {
                        var entry = this.tryEntries[i];
                        if (entry.finallyLoc === finallyLoc) { this.complete(entry.completion, entry.afterLoc); resetEntry(entry); return Continue; }
                    }
                },
                'catch': function (tryLoc) {
                    for (var i = this.tryEntries.length - 1; i >= 0; --i) {
                        var entry = this.tryEntries[i];
                        if (entry.tryLoc === tryLoc) {
                            var record = entry.completion, thrown;
                            if (record.type === 'throw') { thrown = record.arg; resetEntry(entry); }
                            return thrown;
                        }
                    }
                    throw new Error('illegal catch attempt');
                },
                delegateYield: function (iterable, resultName, nextLoc) {
                    this.delegate = { iterator: values(iterable), resultName: resultName, nextLoc: nextLoc };
                    if (this.method === 'next') this.arg = undefined;
                    return Continue;
                }
            };
            var invokeDelegate = function (delegate, ctx) {
                var method = delegate.iterator[ctx.method];
                if (method === undefined) {
                    ctx.delegate = null;
                    if (ctx.method === 'throw') {
                        if (delegate.iterator['return']) { ctx.method = 'return'; ctx.arg = undefined; invokeDelegate(delegate, ctx); if (ctx.method === 'throw') return Continue; }
                        ctx.method = 'throw';
                        ctx.arg = new TypeError("The iterator does not provide a 'throw' method");
                    }
                    return Continue;
                }
                var record = tryCatch(method, delegate.iterator, ctx.arg);
                if (record.type === 'throw') { ctx.method = 'throw'; ctx.arg = record.arg; ctx.delegate = null; return Continue; }
                var info = record.arg;
                if (!info) { ctx.method = 'throw'; ctx.arg = new TypeError('iterator result is not an object'); ctx.delegate = null; return Continue; }
                if (!info.done) return info;
                ctx[delegate.resultName] = info.value;
                ctx.next = delegate.nextLoc;
                if (ctx.method !== 'return') { ctx.method = 'next'; ctx.arg = undefined; }
                ctx.delegate = null;
                return Continue;
            };
            var wrap = function (innerFn, outerFn, self, tryLocs) {
                var gen = Object.create(Gp), ctx = new Context(tryLocs || []), state = 'start';
                gen._invoke = function (method, arg) {
                    if (state === 'running') throw new Error('Generator is already running');
                    if (state === 'done') { if (method === 'throw') throw arg; return { value: undefined, done: true }; }
                    ctx.method = method;
                    ctx.arg = arg;
                    for (;;) {
                        if (ctx.delegate) {
                            var dr = invokeDelegate(ctx.delegate, ctx);
                            if (dr) { if (dr === Continue) continue; return dr; }
                        }
                        if (ctx.method === 'next') ctx.sent = ctx.arg;
                        else if (ctx.method === 'throw') {
                            if (state === 'start') { state = 'done'; throw ctx.arg; }
                            ctx.dispatchException(ctx.arg);
                        } else if (ctx.method === 'return') ctx.abrupt('return', ctx.arg);
                        state = 'running';
                        var record = tryCatch(innerFn, self, ctx);
                        if (record.type === 'normal') {
                            state = ctx.done ? 'done' : 'yield';
                            if (record.arg === Continue) continue;
                            return { value: record.arg, done: ctx.done };
                        }
                        state = 'done';
                        ctx.method = 'throw';
                        ctx.arg = record.arg;
                    }
                };
                return gen;
            };
            Gp.next = function (arg) { return this._invoke('next', arg); };
            Gp['throw'] = function (arg) { return this._invoke('throw', arg); };
            Gp['return'] = function (arg) { return this._invoke('return', arg); };
            var AsyncIterator = function (gen, P) {
                var invoke = function (method, arg, resolve, reject) {
                    var record = tryCatch(gen[method], gen, arg);
                    if (record.type === 'throw') { reject(record.arg); return; }
                    var result = record.arg, value = result.value;
                    if (value && typeof value === 'object' && hasOwn.call(value, '__await')) {
                        P.resolve(value.__await).then(function (v) { invoke('next', v, resolve, reject); }, function (err) { invoke('throw', err, resolve, reject); });
                        return;
                    }
                    P.resolve(value).then(function (v) { result.value = v; resolve(result); }, function (err) { invoke('throw', err, resolve, reject); });
                };
                this.next = function (arg) { return new P(function (resolve, reject) { invoke('next', arg, resolve, reject); }); };
            };
            var rt = {
                wrap: wrap,
                awrap: function (arg) { return { __await: arg }; },
                async: function (innerFn, outerFn, self, tryLocs) {
                    var P = G.Promise || (typeof Promise !== 'undefined' ? Promise : null);
                    var it = new AsyncIterator(wrap(innerFn, outerFn, self, tryLocs), P);
                    return it.next().then(function (r) { return r.done ? r.value : it.next(); });
                },
                // for (k in o) around a yield: the keys when the loop starts, skipping those deleted meanwhile
                keys: function (object) {
                    var keys = [];
                    for (var key in object) keys.push(key);
                    keys.reverse();
                    var next = function () {
                        while (keys.length) { var k = keys.pop(); if (k in object) { next.value = k; next.done = false; return next; } }
                        next.done = true;
                        return next;
                    };
                    return next;
                },
                values: values
            };
            G.__br_rtObj = rt;
            return rt;
        }
    };
    var RUNTIME_DEPS = { __br_spread: ['__br_iter'], __br_arr: ['__br_iter'], __br_props: ['__br_assignOwn'], __br_class: ['__br_defs'],
                         __br_super: ['__br_isNative', '__br_new'] };

    // ------------------------------------------------------------------------------------------------ small utilities
    var hex4 = function (c) { return ('0000' + c.toString(16)).slice(-4); };
    var LS = String.fromCharCode(0x2028), PS = String.fromCharCode(0x2029), LS_G = new RegExp(LS, 'g'), PS_G = new RegExp(PS, 'g'), LSPS = new RegExp('[' + LS + PS + ']');
    var QUOTE_RE = new RegExp('["\\\\\\u0000-\\u001f\\u007f' + LS + PS + '\\ud800-\\udfff]|<\\/', 'g'), QUOTE_TEST = new RegExp(QUOTE_RE.source);
    var quoteChar = function (c) {
        switch (c) {
            case '"': return '\\"';
            case '\\': return '\\\\';
            case '\n': return '\\n';
            case '\r': return '\\r';
            case '\t': return '\\t';
            case '</': return '<\\/';
        }
        return '\\u' + hex4(c.charCodeAt(0));
    };
    // a double-quoted ES5 string literal (line separators, surrogates and "</" escaped)
    var quote = function (s) {
        s = String(s);
        return '"' + (QUOTE_TEST.test(s) ? s.replace(QUOTE_RE, quoteChar) : s) + '"';
    };
    var IDENT = /^[A-Za-z_$][\w$]*$/;
    var ES5_RESERVED = { 'break': 1, 'case': 1, 'catch': 1, 'continue': 1, 'debugger': 1, 'default': 1, 'delete': 1, 'do': 1, 'else': 1, 'finally': 1, 'for': 1,
        'function': 1, 'if': 1, 'in': 1, 'instanceof': 1, 'new': 1, 'return': 1, 'switch': 1, 'this': 1, 'throw': 1, 'try': 1, 'typeof': 1, 'var': 1,
        'void': 1, 'while': 1, 'with': 1, 'class': 1, 'const': 1, 'enum': 1, 'export': 1, 'extends': 1, 'import': 1, 'super': 1, 'null': 1, 'true': 1, 'false': 1 };
    var Unsupported = function (what) { this.what = what; this.message = 'unsupported: ' + what; };

    // ------------------------------------------------------------------------------------------------ precedence
    var BIN = { '??': 4, '||': 4, '&&': 5, '|': 6, '^': 7, '&': 8, '==': 9, '!=': 9, '===': 9, '!==': 9, '<': 10, '>': 10, '<=': 10, '>=': 10,
                'in': 10, 'instanceof': 10, '<<': 11, '>>': 11, '>>>': 11, '+': 12, '-': 12, '*': 13, '/': 13, '%': 13, '**': 14 };
    var P_SEQ = 1, P_ASSIGN = 2, P_COND = 3, P_UNARY = 15, P_POSTFIX = 16, P_CALL = 18, P_PRIMARY = 20;
    // the precedence of a node printed as it is in the source
    var precOf = function (n, src) {
        switch (n.type) {
            case 'SequenceExpression': return P_SEQ;
            case 'AssignmentExpression': case 'ArrowFunctionExpression': case 'YieldExpression': return P_ASSIGN;
            case 'ConditionalExpression': return P_COND;
            case 'LogicalExpression': case 'BinaryExpression': return BIN[n.operator];
            case 'UnaryExpression': case 'AwaitExpression': return P_UNARY;
            case 'UpdateExpression': return n.prefix ? P_UNARY : P_POSTFIX;
            case 'NewExpression': return src.charAt(n.end - 1) === ')' ? P_CALL : 17;
            case 'CallExpression': case 'MemberExpression': case 'TaggedTemplateExpression': case 'ChainExpression': case 'ImportExpression': return P_CALL;
        }
        return P_PRIMARY;
    };
    // statements that end in a semicolon (added when the source relied on automatic insertion)
    var SEMI_STMT = { ExpressionStatement: 1, VariableDeclaration: 1, ReturnStatement: 1, ThrowStatement: 1, BreakStatement: 1, ContinueStatement: 1,
                      DoWhileStatement: 1, DebuggerStatement: 1 };
    // a statement whose last part ended by automatic semicolon insertion (`for (...) f()` before a newline or "}")
    var endsWithoutSemi = function (src, n) {
        for (;;) {
            if (SEMI_STMT[n.type]) return src.charAt(n.end - 1) !== ';';
            if (n.type === 'IfStatement') n = n.alternate || n.consequent;
            else if (n.type === 'ForStatement' || n.type === 'ForInStatement' || n.type === 'ForOfStatement' || n.type === 'WhileStatement' ||
                     n.type === 'WithStatement' || n.type === 'LabeledStatement') n = n.body;
            else return false;
        }
    };
    var sliceStmt = function (src, n) {
        var code = src.slice(n.start, n.end);
        if (endsWithoutSemi(src, n)) code += ';';
        return code;
    };
    var isLoop = function (n) { return n.type === 'ForStatement' || n.type === 'ForInStatement' || n.type === 'ForOfStatement' || n.type === 'WhileStatement' || n.type === 'DoWhileStatement'; };
    var hasSpread = function (list) { for (var i = 0; i < list.length; i++) if (list[i] && list[i].type === 'SpreadElement') return true; return false; };

    // ------------------------------------------------------------------------------------------------ literals
    var regexNeedsWork = function (r) {
        return /[uysdv]/.test(r.flags) || /\(\?<[=!]|\(\?<[A-Za-z_$]|\\k<|\\[pP]\{|\\u\{/.test(r.pattern);
    };
    var literalDirty = function (n) {
        if (n.bigint !== undefined) return true;
        if (n.regex) return regexNeedsWork(n.regex);
        if (typeof n.value === 'number') return /^0[bBoO]|_/.test(n.raw);
        if (typeof n.value === 'string') return n.raw.indexOf('\\u{') >= 0 || LSPS.test(n.raw);
        return false;
    };
    // "." outside character classes matches line terminators too (the s flag)
    var dotAll = function (p) {
        var out = '', inClass = false;
        for (var i = 0; i < p.length; i++) {
            var c = p.charAt(i);
            if (c === '\\') { out += c + p.charAt(i + 1); i++; continue; }
            if (inClass) { if (c === ']') inClass = false; out += c; continue; }
            if (c === '[') { inClass = true; out += c; continue; }
            out += c === '.' ? '[\\s\\S]' : c;
        }
        return out;
    };
    // named groups: the names go, \k<name> becomes a numbered backreference; the numbers are returned for .groups
    var stripNamedGroups = function (p) {
        var names = {}, count = 0, out = '', inClass = false, i, c, e;
        for (i = 0; i < p.length; i++) {
            c = p.charAt(i);
            if (c === '\\') {
                if (!inClass && p.charAt(i + 1) === 'k' && p.charAt(i + 2) === '<') {
                    e = p.indexOf('>', i);
                    if (e > 0 && hasOwn.call(names, p.slice(i + 3, e))) { out += '\\' + names[p.slice(i + 3, e)]; i = e; continue; }
                }
                out += c + p.charAt(i + 1); i++; continue;
            }
            if (inClass) { if (c === ']') inClass = false; out += c; continue; }
            if (c === '[') { inClass = true; out += c; continue; }
            if (c === '(') {
                if (p.charAt(i + 1) !== '?') { count++; out += c; continue; }
                if (p.charAt(i + 2) === '<' && p.charAt(i + 3) !== '=' && p.charAt(i + 3) !== '!') {
                    e = p.indexOf('>', i);
                    count++;
                    names[p.slice(i + 3, e)] = count;
                    out += '(';
                    i = e;
                    continue;
                }
            }
            out += c;
        }
        return { pattern: out, names: names };
    };
    var surrogates = function (cp) {
        cp -= 0x10000;
        return '\\u' + hex4(0xD800 + (cp >> 10)) + '\\u' + hex4(0xDC00 + (cp & 0x3FF));
    };
    // the u flag: \u{...} escapes become \uXXXX or surrogate pairs; null when the pattern needs real unicode mode
    // (astral characters in classes, property escapes)
    var lowerUnicodeRegex = function (p) {
        if (/\\[pP]\{/.test(p)) return null;
        var out = '', inClass = false, i, c, code, e, cp;
        for (i = 0; i < p.length; i++) {
            c = p.charAt(i);
            code = p.charCodeAt(i);
            if (c === '\\') {
                if (p.charAt(i + 1) === 'u' && p.charAt(i + 2) === '{') {
                    e = p.indexOf('}', i);
                    cp = parseInt(p.slice(i + 3, e), 16);
                    if (cp > 0xFFFF) { if (inClass) return null; out += '(?:' + surrogates(cp) + ')'; }
                    else out += '\\u' + hex4(cp);
                    i = e;
                    continue;
                }
                out += c + p.charAt(i + 1); i++; continue;
            }
            if (code >= 0xD800 && code <= 0xDBFF) { if (inClass) return null; out += '(?:' + c + p.charAt(i + 1) + ')'; i++; continue; }
            if (inClass) { if (c === ']') inClass = false; out += c; continue; }
            if (c === '[') { inClass = true; out += c; continue; }
            out += c;
        }
        return out;
    };
    // \u{...} in a string literal's source
    var unicodeEscapes = function (raw) {
        return raw.replace(/\\u\{([0-9a-fA-F]+)\}/g, function (m, h) { var cp = parseInt(h, 16); return cp > 0xFFFF ? surrogates(cp) : '\\u' + hex4(cp); })
                  .replace(LS_G, '\\u2028').replace(PS_G, '\\u2029');
    };

    // ------------------------------------------------------------------------------------------------ scopes
    var LEXICAL = { 'let': 1, 'const': 1, 'class': 1, lexfn: 1, catchpat: 1 };
    // globals a top-level `let`/`const` must not turn into (a `var` there becomes a window property)
    var DANGEROUS_GLOBALS = { top: 1, parent: 1, self: 1, window: 1, location: 1, document: 1, name: 1, status: 1, frames: 1, length: 1, opener: 1,
        closed: 1, history: 1, navigator: 1, screen: 1, origin: 1, event: 1, external: 1, frameElement: 1, performance: 1, localStorage: 1,
        sessionStorage: 1, crypto: 1, caches: 1, console: 1, content: 1, find: 1, scroll: 1, stop: 1, open: 1, close: 1, print: 1, focus: 1, blur: 1 };

    var Scope = function (kind, parent, node, strict, loopNode) {
        this.kind = kind;
        this.parent = parent;
        this.node = node;
        this.strict = strict;
        this.decls = {};
        this.isFn = kind === 'program' || kind === 'function';
        this.fn = this.isFn ? this : parent.fn;
        this.loop = this.isFn ? null : (loopNode || parent.loop);
        if (this.isFn) { this.declCount = {}; this.free = {}; }
    };
    var Binding = function (name, kind, scope) {
        this.name = name;
        this.kind = kind;
        this.scope = scope;
        this.ids = [];
        this.refs = [];
        this.newName = null;
        this.loop = LEXICAL[kind] ? scope.loop : null;
    };
    var markDirty = function (n) { while (n && !n.$d) { n.$d = true; n = n.$p; } };
    var hasUseStrict = function (stmts) {
        for (var i = 0; i < stmts.length && stmts[i].directive !== undefined; i++) if (stmts[i].directive === 'use strict') return true;
        return false;
    };

    // ------------------------------------------------------------------------------------------------ analysis
    var Walker = function (src) {
        this.src = src;
        this.names = {};       // '$' + every variable name in the program (fresh names avoid them)
        this.refs = [];        // [identifier, scope]* in the order met
        this.lexicals = [];
        this.fns = [];         // function-like nodes around the current node (arrows carry $arrow)
        this.loops = [];
        this.module = false;
    };
    var W = Walker.prototype;
    W.inArrow = function () { var f = this.fns[this.fns.length - 1]; return !!(f && f.$arrow); };
    // `this` that prints differently: inside arrows (an alias), in field initialisers (the instance or the class) and in
    // derived constructors (the object super() returned)
    W.thisDirty = function () { var f = this.fns[this.fns.length - 1]; return !!(f && (f.$arrow || f.$field || f.$derived)); };
    // `arguments` of an arrow is the outer function's; in a generator or async function the body becomes an inner
    // function (the state machine): both use an alias
    W.argsDirty = function () { var f = this.fns[this.fns.length - 1]; return !!(f && (f.$arrow || f.generator || f.async)); };
    // inside a generator or async function the declarations move to the function around the state machine
    W.inGen = function () { var f = this.fns[this.fns.length - 1]; return !!(f && (f.generator || f.async)); };
    W.declare = function (scope, name, kind, id) {
        var target = (kind === 'var' || kind === 'fn') ? scope.fn : scope, key = '$' + name, b = target.decls[key];
        this.names[key] = 1;
        if (b && b.kind !== 'fnname') { b.ids.push(id); id.$b = b; return b; }
        b = new Binding(name, kind, target);
        target.decls[key] = b;
        var f = target.fn;
        f.declCount[key] = (f.declCount[key] || 0) + 1;
        b.ids.push(id);
        id.$b = b;
        if (LEXICAL[kind]) this.lexicals.push(b);
        return b;
    };
    W.ref = function (id, scope, write) {
        this.refs.push(id, scope);
        this.names['$' + id.name] = 1;
        if (write) id.$w = true;
    };
    W.list = function (list, p, s) {
        var d = false;
        for (var i = 0; i < list.length; i++) if (list[i] && this.v(list[i], p, s)) d = true;
        return d;
    };
    // statements of a block scope (a block, a switch, a catch body): in strict code function declarations are
    // block-scoped (the old engine rejects them there)
    W.stmts = function (list, p, s, nested) {
        var d = false, i, n;
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (n.type === 'FunctionDeclaration') {
                n.$p = p;
                if (nested && s.strict) { n.$lexfn = true; this.declare(s, n.id.name, 'lexfn', n.id); this.fn(n, p, s); markDirty(n); d = true; }
                else { this.declare(s, n.id.name, 'fn', n.id); if (this.fn(n, p, s)) d = true; }
                continue;
            }
            if (this.v(n, p, s)) d = true;
        }
        return d;
    };
    // a binding pattern: declared names (declKind) or assignment targets (declKind null); defaults and computed keys
    // are expressions
    W.pattern = function (n, p, s, declKind) {
        n.$p = p;
        var d = false, i;
        switch (n.type) {
            case 'Identifier':
                if (declKind) this.declare(s, n.name, declKind, n); else this.ref(n, s, true);
                if (!declKind && n.name === 'arguments' && this.argsDirty()) d = true;
                break;
            case 'MemberExpression':
                return this.v(n, p, s);
            case 'ObjectPattern':
                d = true;
                for (i = 0; i < n.properties.length; i++) {
                    var pr = n.properties[i];
                    pr.$p = n;
                    if (pr.type === 'RestElement') { this.pattern(pr.argument, pr, s, declKind); pr.$d = true; continue; }
                    if (pr.computed) this.v(pr.key, pr, s);
                    this.pattern(pr.value, pr, s, declKind);
                    pr.$d = true;
                }
                break;
            case 'ArrayPattern':
                d = true;
                for (i = 0; i < n.elements.length; i++) if (n.elements[i]) this.pattern(n.elements[i], n, s, declKind);
                break;
            case 'RestElement':
                d = true;
                this.pattern(n.argument, n, s, declKind);
                break;
            case 'AssignmentPattern':
                d = true;
                this.pattern(n.left, n, s, declKind);
                this.v(n.right, n, s);
                break;
            default:
                return this.v(n, p, s);
        }
        if (d) n.$d = true;
        return d;
    };
    W.fn = function (n, p, s) {
        n.$p = p;
        var arrow = n.type === 'ArrowFunctionExpression';
        var body = n.body, strict = s.strict || (body.type === 'BlockStatement' && hasUseStrict(body.body));
        var fs = new Scope('function', s, n, strict);
        var d = arrow || n.generator || n.async, i;
        n.$arrow = arrow;
        n.$scope = fs;
        if (n.type === 'FunctionExpression' && n.id) { this.declare(fs, n.id.name, 'fnname', n.id); n.id.$p = n; }
        for (i = 0; i < n.params.length; i++) {
            if (n.params[i].type !== 'Identifier') d = true;
            if (this.pattern(n.params[i], n, fs, 'param')) d = true;
        }
        // trailing comma after the last parameter (ES2017)
        if (n.params.length) {
            var last = n.params[n.params.length - 1], stop = body.start;
            if (this.src.slice(last.end, stop).indexOf(',') >= 0 && /,\s*\)/.test(this.src.slice(last.end, stop))) d = true;
        }
        this.fns.push(n);
        if (body.type === 'BlockStatement') { body.$p = n; if (this.stmts(body.body, body, fs, false)) { body.$d = true; d = true; } }
        else if (this.v(body, n, fs)) d = true;
        this.fns.pop();
        if (d) n.$d = true;
        return d;
    };
    W.cls = function (n, p, s) {
        n.$p = p;
        var cs = new Scope('class', s, n, true), i, m;
        // the name inside the class body is its own binding (a declaration's outer binding keeps the id node)
        if (n.id) { this.declare(cs, n.id.name, 'classname', n.type === 'ClassDeclaration' ? { type: 'Identifier', name: n.id.name } : n.id); n.id.$p = n; }
        if (n.superClass) this.v(n.superClass, n, cs);
        var body = n.body.body;
        n.body.$p = n;
        for (i = 0; i < body.length; i++) {
            m = body[i];
            m.$p = n.body;
            if (m.type === 'MethodDefinition') {
                if (m.computed) this.v(m.key, m, cs);
                if (m.kind === 'constructor' && n.superClass) m.value.$derived = true;
                this.fn(m.value, m, cs);
            } else if (m.type === 'PropertyDefinition' || m.type === 'StaticBlock') {
                if (m.computed) this.v(m.key, m, cs);
                // initialisers and static blocks run like methods: their own `this` (initialisers print it differently)
                var fs = new Scope('function', cs, m, true), marker = { $arrow: false, $field: m.type === 'PropertyDefinition' };
                this.fns.push(marker);
                if (m.type === 'StaticBlock') this.stmts(m.body, m, fs, false);
                else if (m.value) this.v(m.value, m, fs);
                this.fns.pop();
            }
            m.$d = true;
        }
        n.body.$d = true;
        n.$d = true;
        return true;
    };
    W.loop = function (n, s) {
        var ls = new Scope('block', s, n, s.strict, n);
        n.$scope = ls;
        this.loops.push(n);
        return ls;
    };
    // yield/await inside a loop body: the body cannot become a function
    W.noWrap = function (s) { for (var x = s; x && !x.isFn; x = x.parent) if (x.node && isLoop(x.node)) x.node.$noWrap = true; };
    W.v = function (n, p, s) {
        n.$p = p;
        var d = false, i, ls;
        switch (n.type) {
            case 'Identifier':
                this.ref(n, s, false);
                if (n.name === 'arguments' && this.argsDirty()) d = true;
                break;
            case 'Literal': d = literalDirty(n); break;
            case 'ThisExpression': d = this.thisDirty(); break;
            case 'Super': case 'MetaProperty': d = true; break;
            case 'ExpressionStatement': d = this.v(n.expression, n, s); break;
            case 'BlockStatement': {
                var bs = new Scope('block', s, n, s.strict);
                d = this.stmts(n.body, n, bs, true);
                break;
            }
            case 'EmptyStatement': case 'DebuggerStatement': break;
            case 'IfStatement':
                if (this.v(n.test, n, s)) d = true;
                if (this.v(n.consequent, n, s)) d = true;
                if (n.alternate && this.v(n.alternate, n, s)) d = true;
                break;
            case 'LabeledStatement': n.label.$p = n; d = this.v(n.body, n, s); break;
            case 'BreakStatement': case 'ContinueStatement': if (n.label) n.label.$p = n; break;
            case 'WithStatement': if (this.v(n.object, n, s)) d = true; if (this.v(n.body, n, s)) d = true; break;
            case 'ReturnStatement': case 'ThrowStatement': if (n.argument && this.v(n.argument, n, s)) d = true; break;
            case 'SwitchStatement': {
                if (this.v(n.discriminant, n, s)) d = true;
                var ss = new Scope('block', s, n, s.strict);
                for (i = 0; i < n.cases.length; i++) {
                    var c = n.cases[i];
                    c.$p = n;
                    var cd = false;
                    if (c.test && this.v(c.test, c, ss)) cd = true;
                    if (this.stmts(c.consequent, c, ss, true)) cd = true;
                    if (cd) { c.$d = true; d = true; }
                }
                break;
            }
            case 'TryStatement': {
                if (this.v(n.block, n, s)) d = true;
                if (n.handler) {
                    var h = n.handler, cs = new Scope('block', s, h, s.strict), hd = false;
                    h.$p = n;
                    if (!h.param) hd = true;
                    else if (h.param.type === 'Identifier') { this.declare(cs, h.param.name, 'catch', h.param); h.param.$p = h; }
                    else { this.pattern(h.param, h, cs, 'catchpat'); hd = true; }
                    h.body.$p = h;
                    var hbs = new Scope('block', cs, h.body, s.strict);
                    if (this.stmts(h.body.body, h.body, hbs, true)) { h.body.$d = true; hd = true; }
                    if (hd) { h.$d = true; d = true; }
                }
                if (n.finalizer && this.v(n.finalizer, n, s)) d = true;
                break;
            }
            case 'WhileStatement': case 'DoWhileStatement':
                ls = this.loop(n, s);
                if (this.v(n.test, n, ls)) d = true;
                if (this.v(n.body, n, ls)) d = true;
                break;
            case 'ForStatement':
                ls = this.loop(n, s);
                if (n.init && this.v(n.init, n, ls)) d = true;
                if (n.test && this.v(n.test, n, ls)) d = true;
                if (n.update && this.v(n.update, n, ls)) d = true;
                if (this.v(n.body, n, ls)) d = true;
                break;
            case 'ForInStatement': case 'ForOfStatement':
                ls = this.loop(n, s);
                if (n.type === 'ForOfStatement') { d = true; if (n.await) { this.noWrap(ls); } }
                if (n.left.type === 'VariableDeclaration') { if (this.v(n.left, n, ls)) d = true; }
                else if (this.pattern(n.left, n, ls, null)) d = true;
                if (this.v(n.right, n, ls)) d = true;
                if (this.v(n.body, n, ls)) d = true;
                break;
            case 'FunctionDeclaration':
                // (declared by the statement list it is in)
                d = this.fn(n, p, s);
                break;
            case 'VariableDeclaration': {
                var kind = n.kind;
                if (kind !== 'var' || this.inGen()) d = true;
                for (i = 0; i < n.declarations.length; i++) {
                    var dc = n.declarations[i];
                    dc.$p = n;
                    var dd = this.pattern(dc.id, dc, s, kind);
                    if (dc.init && this.v(dc.init, dc, s)) dd = true;
                    if (dd) { dc.$d = true; d = true; }
                }
                break;
            }
            case 'ClassDeclaration':
                this.declare(s, n.id.name, 'class', n.id);
                d = this.cls(n, p, s);
                break;
            case 'ClassExpression': d = this.cls(n, p, s); break;
            case 'FunctionExpression': case 'ArrowFunctionExpression': d = this.fn(n, p, s); break;
            case 'ArrayExpression': d = this.list(n.elements, n, s); break;
            case 'ObjectExpression':
                for (i = 0; i < n.properties.length; i++) {
                    var pr = n.properties[i], pd = false;
                    pr.$p = n;
                    if (pr.type === 'SpreadElement') { this.v(pr.argument, pr, s); pr.$d = true; d = true; continue; }
                    if (pr.computed) { this.v(pr.key, pr, s); pd = true; }
                    else if (pr.key.type === 'Literal' && literalDirty(pr.key)) pd = true;
                    if (pr.method || pr.shorthand) pd = true;
                    if (this.v(pr.value, pr, s)) pd = true;
                    if (pd) { pr.$d = true; d = true; }
                }
                break;
            case 'SpreadElement': this.v(n.argument, n, s); d = true; break;
            case 'TemplateLiteral': this.list(n.expressions, n, s); d = true; break;
            case 'TaggedTemplateExpression': this.v(n.tag, n, s); n.quasi.$p = n; this.list(n.quasi.expressions, n.quasi, s); d = true; break;
            case 'UnaryExpression': case 'UpdateExpression': d = this.v(n.argument, n, s); if (n.type === 'UpdateExpression' && n.argument.type === 'Identifier') n.argument.$w = true; break;
            case 'BinaryExpression':
                if (n.operator === '**') d = true;
                if (n.left.type === 'PrivateIdentifier') { d = true; n.left.$p = n; } else if (this.v(n.left, n, s)) d = true;
                if (this.v(n.right, n, s)) d = true;
                break;
            case 'LogicalExpression':
                if (n.operator === '??') d = true;
                if (this.v(n.left, n, s)) d = true;
                if (this.v(n.right, n, s)) d = true;
                break;
            case 'AssignmentExpression':
                if (n.operator === '**=' || n.operator === '||=' || n.operator === '&&=' || n.operator === '??=') d = true;
                if (n.left.type === 'Identifier') { this.ref(n.left, s, true); n.left.$p = n; if (n.left.name === 'arguments' && this.argsDirty()) d = true; }
                else if (this.pattern(n.left, n, s, null)) d = true;
                if (this.v(n.right, n, s)) d = true;
                break;
            case 'ConditionalExpression':
                if (this.v(n.test, n, s)) d = true;
                if (this.v(n.consequent, n, s)) d = true;
                if (this.v(n.alternate, n, s)) d = true;
                break;
            case 'SequenceExpression': d = this.list(n.expressions, n, s); break;
            case 'CallExpression': case 'NewExpression':
                if (n.callee.type === 'Super') { d = true; n.callee.$p = n; } else if (this.v(n.callee, n, s)) d = true;
                if (this.list(n.arguments, n, s)) d = true;
                if (n.optional) d = true;
                // trailing comma after the last argument (ES2017)
                if (n.arguments.length && /,\s*\)\s*$/.test(this.src.slice(n.arguments[n.arguments.length - 1].end, n.end))) d = true;
                break;
            case 'MemberExpression':
                if (n.object.type === 'Super') { d = true; n.object.$p = n; } else if (this.v(n.object, n, s)) d = true;
                if (n.computed) { if (this.v(n.property, n, s)) d = true; }
                else { n.property.$p = n; if (n.property.type === 'PrivateIdentifier') d = true; }
                if (n.optional) d = true;
                break;
            case 'ChainExpression': this.v(n.expression, n, s); d = true; break;
            case 'AwaitExpression': case 'YieldExpression':
                if (n.argument) this.v(n.argument, n, s);
                this.noWrap(s);
                d = true;
                break;
            case 'ImportExpression': this.v(n.source, n, s); d = true; break;
            case 'ParenthesizedExpression': d = this.v(n.expression, n, s); break;
            case 'ImportDeclaration': case 'ExportNamedDeclaration': case 'ExportDefaultDeclaration': case 'ExportAllDeclaration':
                this.module = true;
                d = true;
                break;
            default:
                throw new Unsupported(n.type);
        }
        if (d) n.$d = true;
        return d;
    };
    // references to bindings, then the decisions: renames, loops that need a function per iteration
    W.resolve = function (program) {
        var refs = this.refs, i, j, id, s, key, b, f, stop;
        for (i = 0; i < refs.length; i += 2) {
            id = refs[i];
            s = refs[i + 1];
            key = '$' + id.name;
            b = null;
            for (var x = s; x; x = x.parent) { b = x.decls[key]; if (b) break; }
            if (b) { b.refs.push(id); id.$b = b; }
            // the name is free in every function between the reference and the binding's function
            stop = b ? b.scope.fn : null;
            for (f = s.fn; f && f !== stop; f = f.parent ? f.parent.fn : null) f.free[key] = 1;
            // a closure in a loop capturing a binding of the iteration
            if (b && b.loop && s.fn !== b.scope.fn) { b.loop.$wrap = true; b.captured = true; }
        }
        for (i = 0; i < this.lexicals.length; i++) {
            b = this.lexicals[i];
            f = b.scope.fn;
            key = '$' + b.name;
            var need;
            if (b.scope !== f) need = f.declCount[key] > 1 || f.free[key] === 1;
            else need = f.kind === 'program' && hasOwn.call(DANGEROUS_GLOBALS, b.name);
            if (!need) continue;
            var nn, k = 1;
            do { nn = b.name + '$' + k++; } while (this.names['$' + nn]);
            this.names['$' + nn] = 1;
            b.newName = nn;
            for (j = 0; j < b.ids.length; j++) markDirty(b.ids[j]);
            for (j = 0; j < b.refs.length; j++) markDirty(b.refs[j]);
        }
        for (i = 0; i < this.loops.length; i++) {
            var l = this.loops[i];
            if (l.$wrap && !l.$noWrap) { markDirty(l); markWrapped(l.body); }
        }
    };
    // inside a loop body that becomes a function: this/arguments, jumps out, returns and var declarations change
    var markWrapped = function (n) {
        if (!n || typeof n.type !== 'string') return;
        switch (n.type) {
            case 'FunctionDeclaration': case 'FunctionExpression': case 'ArrowFunctionExpression': case 'ClassDeclaration': case 'ClassExpression':
                return;
            case 'ThisExpression': case 'BreakStatement': case 'ContinueStatement': case 'ReturnStatement': case 'MetaProperty': case 'Super':
                markDirty(n);
                if (n.type !== 'ReturnStatement') return;
                break;
            case 'Identifier':
                if (n.name === 'arguments' && !n.$b) markDirty(n);
                return;
            case 'VariableDeclaration':
                if (n.kind === 'var') markDirty(n);
                break;
        }
        for (var k in n) {
            if (k.charAt(0) === '$' || !hasOwn.call(n, k)) continue;
            var v = n[k];
            if (!v || typeof v !== 'object') continue;
            if (Object.prototype.toString.call(v) === '[object Array]') { for (var i = 0; i < v.length; i++) markWrapped(v[i]); }
            else if (typeof v.type === 'string') markWrapped(v);
        }
    };

    // ------------------------------------------------------------------------------------------------ printer
    // one context per output function: temps and the aliases of this/arguments its inner arrows use
    var Ctx = function (kind, parent, node) {
        this.kind = kind;       // program | fn | arrow | method | ctor | dctor | static | loop | gen (a state machine)
        this.parent = parent;
        this.node = node;
        this.temps = [];
        this.tempSet = {};
        this.gen = null;
        var inherits = kind === 'arrow' || kind === 'loop' || kind === 'gen';
        this.thisCtx = inherits ? parent.thisCtx : this;
        this.thisAlias = null;
        this.argsAlias = null;
        this.ntAlias = null;
        this.jumps = [];
        this.superRef = inherits ? parent.superRef : null;
        this.derivedThis = null;
        this.superCtor = null;
        this.fieldNodes = null;
        this.className = null;
        this.loopInfo = null;
    };
    // (the variables of a state machine live in the function around it: they survive the yields)
    Ctx.prototype.declare = function (name) {
        if (this.kind === 'gen') return this.parent.declare(name);
        if (!this.tempSet['$' + name]) { this.tempSet['$' + name] = 1; this.temps.push(name); }
    };

    var Printer = function (src, walker, opts) {
        this.src = src;
        this.names = walker.names;
        this.opts = opts || {};
        this.helpers = [];
        this.helperSet = {};
        this.ctx = null;
        this.program = null;
        this.uid = 0;
        this.prec = P_PRIMARY;
        this.privStack = [];
        // top-level names are globals shared with the page's other scripts: a per-script part keeps them apart
        var h = src.length;
        for (var i = 0; i < src.length; i += 97) h = ((h * 31) + src.charCodeAt(i)) | 0;
        this.pfx = (h >>> 0).toString(36).slice(0, 4);
    };
    var P = Printer.prototype;
    P.fresh = function (base) {
        var name;
        do { name = base + '$' + this.pfx + (++this.uid); } while (this.names['$' + name]);
        this.names['$' + name] = 1;
        return name;
    };
    P.temp = function (base) { var n = this.fresh(base || '_t'); this.ctx.declare(n); return n; };
    P.progTemp = function (base) { var n = this.fresh(base); this.program.declare(n); return n; };
    P.h = function (name) {
        if (!this.helperSet[name]) {
            var deps = RUNTIME_DEPS[name] || [];
            for (var i = 0; i < deps.length; i++) this.h(deps[i]);
            this.helperSet[name] = 1;
            this.helpers.push(name);
        }
        return name;
    };
    P.helperCode = function () {
        var out = '';
        for (var i = 0; i < this.helpers.length; i++) {
            var s = String(RUNTIME[this.helpers[i]]);
            out += 'function ' + this.helpers[i] + s.slice(s.indexOf('(')) + '\n';
        }
        return out;
    };
    P.push = function (kind, node) { this.ctx = new Ctx(kind, this.ctx, node); return this.ctx; };
    P.pop = function () { this.ctx = this.ctx.parent; };
    // a var hoisted out of a loop function to the function around it
    P.hoistVar = function (name) { var c = this.ctx; while (c.kind === 'loop' || c.kind === 'gen') c = c.parent; c.declare(name); };
    // declarations that become assignments: `var` inside a loop function, every declaration inside a state machine
    P.hoisting = function (kind) { return (this.ctx.kind === 'loop' && kind === 'var') || this.ctx.kind === 'gen'; };
    P.declLine = function (c) {
        var parts = [];
        if (c.thisAlias) parts.push(c.thisAlias + '=this');
        if (c.argsAlias) parts.push(c.argsAlias + '=arguments');
        if (c.ntAlias) parts.push(c.ntAlias + '=' + c.ntCode);
        for (var i = 0; i < c.temps.length; i++) parts.push(c.temps[i]);
        return parts.length ? 'var ' + parts.join(',') + ';' : '';
    };
    P.thisCode = function () {
        var c = this.ctx, t = c.thisCtx;
        if (t.kind === 'dctor') return t.derivedThis;
        if (t.kind === 'static') return t.className;
        if (t === c) return 'this';
        if (!t.thisAlias) t.thisAlias = this.fresh('_this');
        return t.thisAlias;
    };
    P.argsCode = function () {
        var c = this.ctx, t = c.thisCtx;
        if (t === c || t.kind === 'program' || t.kind === 'static') return 'arguments';
        if (!t.argsAlias) t.argsAlias = this.fresh('_arguments');
        return t.argsAlias;
    };
    P.bname = function (id) { var b = id.$b; return b && b.newName ? b.newName : id.name; };
    P.privName = function (name) {
        for (var i = this.privStack.length - 1; i >= 0; i--) if (hasOwn.call(this.privStack[i], '$' + name)) return this.privStack[i]['$' + name];
        return '__br$' + name;
    };

    // ---- expressions
    P.E = function (n, min) {
        var code;
        if (n.$d) code = this.X(n);
        else { code = this.src.slice(n.start, n.end); this.prec = precOf(n, this.src); }
        if (this.prec < min) { code = '(' + code + ')'; this.prec = P_PRIMARY; }
        return code;
    };
    P.X = function (n) {
        var code;
        switch (n.type) {
            case 'Identifier': code = n.$b ? (n.$b.newName || n.name) : n.name === 'arguments' ? this.argsCode() : n.name; this.prec = P_PRIMARY; return code;
            case 'Literal': code = this.literal(n); return code;
            case 'ThisExpression': code = this.thisCode(); this.prec = P_PRIMARY; return code;
            case 'Raw': this.prec = n.prec || P_PRIMARY; return n.code;
            case 'ArrayExpression': return this.array(n);
            case 'ObjectExpression': return this.object(n);
            case 'FunctionExpression': case 'ArrowFunctionExpression':
                code = n.type === 'FunctionExpression' ? this.func(n, 'fn', n.id ? n.id.name : null, null) : this.func(n, 'arrow', null, null);
                if (n.async && !n.generator) { this.prec = P_CALL; return this.h('__br_asyncFn') + '(' + code + ')'; }
                this.prec = P_PRIMARY;
                return code;
            case 'ClassExpression': return this.classExpr(n, null);
            case 'TemplateLiteral': return this.template(n);
            case 'TaggedTemplateExpression': return this.tagged(n);
            case 'SequenceExpression': return this.sequence(n);
            case 'UnaryExpression': return this.unary(n);
            case 'UpdateExpression': return this.update(n);
            case 'BinaryExpression': return this.binary(n);
            case 'LogicalExpression': return this.logical(n);
            case 'AssignmentExpression': return this.assign(n);
            case 'ConditionalExpression':
                code = this.E(n.test, 4) + '?' + this.E(n.consequent, P_ASSIGN) + ':' + this.E(n.alternate, P_ASSIGN);
                this.prec = P_COND;
                return code;
            case 'CallExpression': return this.call(n);
            case 'NewExpression': return this.newExpr(n);
            case 'MemberExpression': return this.member(n);
            case 'ChainExpression': return this.chain(n.expression, null);
            case 'ImportExpression':
                code = this.h('__br_import') + '(' + this.E(n.source, P_ASSIGN) + ',' + quote(this.opts.url || '') + ')';
                this.prec = P_CALL;
                return code;
            case 'MetaProperty': return this.meta(n);
            case 'ParenthesizedExpression': return this.X(n.expression);
            case 'AwaitExpression': throw new Unsupported('await');
            case 'YieldExpression': throw new Unsupported('yield');
        }
        throw new Unsupported(n.type);
    };
    P.literal = function (n) {
        this.prec = P_PRIMARY;
        if (n.bigint !== undefined) { this.prec = P_CALL; return 'BigInt(' + quote(n.bigint) + ')'; }
        if (n.regex) return this.regex(n);
        if (typeof n.value === 'number') {
            if (!/^0[bBoO]|_/.test(n.raw)) return n.raw;
            return String(n.value);
        }
        if (typeof n.value === 'string') return unicodeEscapes(n.raw);
        return n.raw;
    };
    P.regex = function (n) {
        var pat = n.regex.pattern, flags = n.regex.flags, names = null;
        if (flags.indexOf('s') >= 0) { pat = dotAll(pat); flags = flags.replace('s', ''); }
        if (/\(\?<[A-Za-z_$]/.test(pat)) { var r = stripNamedGroups(pat); pat = r.pattern; names = r.names; }
        if (flags.indexOf('u') >= 0) { var u = lowerUnicodeRegex(pat); if (u !== null) { pat = u; flags = flags.replace('u', ''); } }
        var code;
        // what the old engine cannot do stays a constructor call: a SyntaxError only when that code runs
        if (/[yvd]/.test(flags) || flags.indexOf('u') >= 0 || /\(\?<[=!]|\\[pP]\{/.test(pat)) { code = 'new RegExp(' + quote(pat) + ',' + quote(flags) + ')'; this.prec = P_CALL; }
        else code = '/' + pat + '/' + flags;
        if (names) {
            var parts = [];
            for (var k in names) if (hasOwn.call(names, k)) parts.push(quote(k) + ':' + names[k]);
            code = this.h('__br_named') + '(' + code + ',{' + parts.join(',') + '})';
            this.prec = P_CALL;
        }
        return code;
    };
    P.args = function (list) {
        var out = [];
        for (var i = 0; i < list.length; i++) out.push(this.E(list[i], P_ASSIGN));
        return out.join(',');
    };
    // elements with spreads as one array expression: [a].concat(__br_spread(b), [c])
    P.spreadArray = function (els) {
        var parts = [], cur = [], i, e;
        for (i = 0; i < els.length; i++) {
            e = els[i];
            if (e && e.type === 'SpreadElement') {
                if (cur.length) { parts.push('[' + cur.join(',') + ']'); cur = []; }
                parts.push(this.h('__br_spread') + '(' + this.E(e.argument, P_ASSIGN) + ')');
            } else cur.push(e ? this.E(e, P_ASSIGN) : 'void 0');
        }
        if (cur.length) parts.push('[' + cur.join(',') + ']');
        if (!parts.length) return '[]';
        if (parts.length === 1) return parts[0];
        return parts[0] + '.concat(' + parts.slice(1).join(',') + ')';
    };
    P.array = function (n) {
        var code;
        if (hasSpread(n.elements)) { code = this.spreadArray(n.elements); this.prec = P_CALL; return code; }
        var out = [];
        for (var i = 0; i < n.elements.length; i++) out.push(n.elements[i] ? this.E(n.elements[i], P_ASSIGN) : '');
        // a hole at the end needs its own comma: [a,,] has length 2
        code = '[' + out.join(',') + (n.elements.length && !n.elements[n.elements.length - 1] ? ',' : '') + ']';
        this.prec = P_PRIMARY;
        return code;
    };
    P.propKey = function (pr) {
        var k = pr.key;
        if (k.type === 'Identifier') return k.name;
        if (k.type === 'Literal') return literalDirty(k) ? quote(String(k.value)) : k.raw;
        return this.E(k, P_ASSIGN);
    };
    P.object = function (n) {
        var head = [], tail = [], dyn = false, i, pr, code;
        for (i = 0; i < n.properties.length; i++) {
            pr = n.properties[i];
            if (pr.type === 'SpreadElement') { dyn = true; tail.push('null', this.E(pr.argument, P_ASSIGN), '3'); continue; }
            if (pr.computed) dyn = true;
            var kind = pr.kind === 'get' ? 1 : pr.kind === 'set' ? 2 : 0;
            if (!dyn) {
                if (!pr.$d) { head.push(this.src.slice(pr.start, pr.end)); continue; }
                var key = this.propKey(pr);
                if (kind) head.push((kind === 1 ? 'get ' : 'set ') + key + this.func(pr.value, 'method', null, { accessor: true, superRef: 'Object.getPrototypeOf(this)' }));
                else if (pr.method) head.push(key + ':' + this.func(pr.value, 'method', null, { superRef: 'Object.getPrototypeOf(this)' }));
                else head.push(key + ':' + this.E(pr.value, P_ASSIGN));
                continue;
            }
            var k2 = pr.computed ? this.E(pr.key, P_ASSIGN) : pr.key.type === 'Identifier' ? quote(pr.key.name) : quote(String(pr.key.value));
            var val = kind || pr.method ? this.func(pr.value, 'method', null, { superRef: 'Object.getPrototypeOf(this)' }) : this.E(pr.value, P_ASSIGN);
            tail.push(k2, val, String(kind));
        }
        code = '{' + head.join(',') + '}';
        if (!tail.length) { this.prec = P_PRIMARY; return code; }
        this.prec = P_CALL;
        return this.h('__br_props') + '(' + code + ',[' + tail.join(',') + '])';
    };
    P.template = function (n) {
        var q = n.quasis, e = n.expressions, i;
        if (!e.length) { this.prec = P_PRIMARY; return quote(q[0].value.cooked); }
        var args = [];
        for (i = 0; i < e.length; i++) {
            args.push(this.E(e[i], P_ASSIGN));
            if (q[i + 1].value.cooked) args.push(quote(q[i + 1].value.cooked));
        }
        this.prec = P_CALL;
        return quote(q[0].value.cooked) + '.concat(' + args.join(',') + ')';
    };
    P.tagged = function (n) {
        var q = n.quasi.quasis, cooked = [], raw = [], i;
        for (i = 0; i < q.length; i++) {
            cooked.push(q[i].value.cooked === null || q[i].value.cooked === undefined ? 'void 0' : quote(q[i].value.cooked));
            raw.push(quote(q[i].value.raw));
        }
        var cache = this.progTemp('_tpl');
        var args = [cache + '||(' + cache + '=' + this.h('__br_tpl') + '([' + cooked.join(',') + '],[' + raw.join(',') + ']))'];
        for (i = 0; i < n.quasi.expressions.length; i++) args.push(this.E(n.quasi.expressions[i], P_ASSIGN));
        var tag = this.E(n.tag, P_CALL);
        this.prec = P_CALL;
        return tag + '(' + args.join(',') + ')';
    };
    P.sequence = function (n) {
        var out = [];
        for (var i = 0; i < n.expressions.length; i++) out.push(this.E(n.expressions[i], P_ASSIGN));
        this.prec = P_SEQ;
        return out.join(',');
    };
    P.unary = function (n) {
        var op = n.operator;
        if (op === 'delete' && n.argument.type === 'ChainExpression') return this.chain(n.argument.expression, 'delete');
        var arg = this.E(n.argument, P_UNARY), code;
        if (/^[a-z]/.test(op)) code = op + ' ' + arg;
        else code = op + ((op === '-' || op === '+') && arg.charAt(0) === op ? ' ' : '') + arg;
        this.prec = P_UNARY;
        return code;
    };
    P.update = function (n) {
        var arg = this.E(n.argument, P_POSTFIX), code = n.prefix ? n.operator + arg : arg + n.operator;
        this.prec = n.prefix ? P_UNARY : P_POSTFIX;
        return code;
    };
    P.binary = function (n) {
        var op = n.operator, p = BIN[op], code;
        if (op === '**') { code = 'Math.pow(' + this.E(n.left, P_ASSIGN) + ',' + this.E(n.right, P_ASSIGN) + ')'; this.prec = P_CALL; return code; }
        if (n.left.type === 'PrivateIdentifier') { code = quote(this.privName(n.left.name)) + ' in ' + this.E(n.right, 11); this.prec = 10; return code; }
        code = this.E(n.left, p) + ' ' + op + ' ' + this.E(n.right, p + 1);
        this.prec = p;
        return code;
    };
    var isIdentCode = function (c) { return IDENT.test(c) && c !== 'arguments'; };
    P.logical = function (n) {
        var op = n.operator, code;
        if (op === '??') {
            var l = this.E(n.left, P_ASSIGN), r = this.E(n.right, P_ASSIGN);
            if (isIdentCode(l)) code = l + ' != null?' + l + ':' + r;
            else { var t = this.temp(); code = '(' + t + '=' + l + ') != null?' + t + ':' + r; }
            this.prec = P_COND;
            return code;
        }
        var p = BIN[op];
        code = this.E(n.left, p) + op + this.E(n.right, p + 1);
        this.prec = p;
        return code;
    };
    // a member expression's tail: .name, [expr], .<private>
    P.tail = function (n) {
        if (n.computed) return '[' + this.E(n.property, P_SEQ) + ']';
        if (n.property.type === 'PrivateIdentifier') return '.' + this.privName(n.property.name);
        return '.' + n.property.name;
    };
    P.member = function (n) {
        var code;
        if (n.object.type === 'Super') code = this.ctxSuper() + this.tail(n);
        else {
            var obj = this.E(n.object, P_CALL);
            if (n.object.type === 'Literal' && typeof n.object.value === 'number' && /^\d+$/.test(obj)) obj = '(' + obj + ')';
            code = obj + this.tail(n);
        }
        this.prec = P_CALL;
        return code;
    };
    P.ctxSuper = function () {
        var r = this.ctx.superRef;
        if (!r) throw new Unsupported('super outside a class');
        return r;
    };
    // an assignment target used twice (compound logical/exponent assignment): the first use evaluates the parts
    P.refParts = function (left) {
        if (left.type === 'Identifier') { var c = this.E(left, P_CALL); return { first: c, later: c }; }
        var obj = left.object.type === 'Super' ? this.ctxSuper() : this.E(left.object, P_CALL), objFirst = obj, objLater = obj;
        if (left.object.type !== 'Super' && !isIdentCode(obj) && obj !== 'this') { var t = this.temp(); objFirst = '(' + t + '=' + obj + ')'; objLater = t; }
        var keyFirst, keyLater;
        if (left.computed) {
            var k = this.E(left.property, P_SEQ);
            if (left.property.type === 'Literal' || isIdentCode(k)) keyFirst = keyLater = '[' + k + ']';
            else { var kt = this.temp(); keyFirst = '[' + kt + '=' + k + ']'; keyLater = '[' + kt + ']'; }
        } else keyFirst = keyLater = this.tail(left);
        return { first: objFirst + keyFirst, later: objLater + keyLater };
    };
    P.assign = function (n) {
        var op = n.operator, left = n.left, code;
        if (left.type === 'ObjectPattern' || left.type === 'ArrayPattern') {
            var out = [], t = this.temp();
            out.push(t + '=' + this.E(n.right, P_ASSIGN));
            this.destructure(left, t, out, 'assign');
            out.push(t);
            this.prec = P_SEQ;
            return out.join(',');
        }
        if (op === '||=' || op === '&&=' || op === '??=') {
            var r = this.refParts(left), val = this.E(n.right, P_ASSIGN);
            if (op === '??=') { var v = this.temp(); code = '(' + v + '=' + r.first + ') != null?' + v + ':' + r.later + '=' + val; this.prec = P_COND; }
            else { code = r.first + (op === '||=' ? '||' : '&&') + '(' + r.later + '=' + val + ')'; this.prec = op === '||=' ? 4 : 5; }
            return code;
        }
        if (op === '**=') {
            var r2 = this.refParts(left);
            code = r2.first + '=Math.pow(' + r2.later + ',' + this.E(n.right, P_ASSIGN) + ')';
            this.prec = P_ASSIGN;
            return code;
        }
        code = this.E(left, P_CALL) + op + this.E(n.right, P_ASSIGN);
        this.prec = P_ASSIGN;
        return code;
    };
    // a callee that `new` can take without parentheses (no call inside)
    var simpleNewCallee = function (n) {
        while (n.type === 'MemberExpression' && !n.optional) n = n.object;
        return n.type === 'Identifier' || n.type === 'ThisExpression';
    };
    P.newExpr = function (n) {
        var code;
        if (hasSpread(n.arguments)) code = this.h('__br_new') + '(' + this.E(n.callee, P_ASSIGN) + ',' + this.spreadArray(n.arguments) + ')';
        else {
            var callee = this.E(n.callee, P_CALL);
            if (!simpleNewCallee(n.callee)) callee = '(' + callee + ')';
            code = 'new ' + callee + '(' + this.args(n.arguments) + ')';
        }
        this.prec = P_CALL;
        return code;
    };
    P.call = function (n) {
        var callee = n.callee, code;
        if (callee.type === 'Super') return this.superCall(n);
        if (n.optional) return this.chain(n, null);
        if (callee.type === 'MemberExpression' && callee.object.type === 'Super') {
            var fn = this.ctxSuper() + this.tail(callee), self = this.thisCode();
            code = hasSpread(n.arguments) ? fn + '.apply(' + self + ',' + this.spreadArray(n.arguments) + ')'
                                          : fn + '.call(' + self + (n.arguments.length ? ',' + this.args(n.arguments) : '') + ')';
            this.prec = P_CALL;
            return code;
        }
        if (hasSpread(n.arguments)) {
            var arr;
            if (callee.type === 'MemberExpression' && !callee.optional) {
                var obj = this.E(callee.object, P_CALL), thisVal = obj;
                if (!isIdentCode(obj) && obj !== 'this') { thisVal = this.temp(); obj = '(' + thisVal + '=' + obj + ')'; }
                var fcode = obj + this.tail(callee);
                arr = this.spreadArray(n.arguments);
                code = fcode + '.apply(' + thisVal + ',' + arr + ')';
            } else {
                var f = this.E(callee, P_CALL);
                arr = this.spreadArray(n.arguments);
                code = f + '.apply(void 0,' + arr + ')';
            }
            this.prec = P_CALL;
            return code;
        }
        code = this.E(callee, P_CALL) + '(' + this.args(n.arguments) + ')';
        this.prec = P_CALL;
        return code;
    };
    // optional chains: every "?." tests what is left of it once, the whole chain gives undefined when one is nullish
    P.chain = function (node, mode, baseCode) {
        var links = [], n = node, i, l;
        while (n.type === 'MemberExpression' || n.type === 'CallExpression') { links.unshift(n); n = n.type === 'MemberExpression' ? n.object : n.callee; }
        var cur = baseCode !== undefined ? baseCode : n.type === 'Super' ? this.ctxSuper() : this.E(n, P_CALL), conds = [], thisForCall = null;
        for (i = 0; i < links.length; i++) {
            l = links[i];
            if (l.optional) {
                if (isIdentCode(cur) || cur === 'this') conds.push(cur + '==null');
                else { var t = this.temp(); conds.push('(' + t + '=' + cur + ')==null'); cur = t; }
            }
            if (l.type === 'MemberExpression') {
                var nx = links[i + 1];
                if (nx && nx.type === 'CallExpression' && nx.optional) {
                    // a method called with ?.(): the object is its `this`
                    if (!isIdentCode(cur) && cur !== 'this') { var ot = this.temp(); cur = '(' + ot + '=' + cur + ')'; thisForCall = ot; }
                    else thisForCall = cur;
                } else thisForCall = null;
                cur = cur + this.tail(l);
            } else {
                var spread = hasSpread(l.arguments);
                if (l.optional && thisForCall !== null) cur = cur + (spread ? '.apply(' + thisForCall + ',' + this.spreadArray(l.arguments) + ')' : '.call(' + thisForCall + (l.arguments.length ? ',' + this.args(l.arguments) : '') + ')');
                else if (spread) cur = cur + '.apply(void 0,' + this.spreadArray(l.arguments) + ')';
                else cur = cur + '(' + this.args(l.arguments) + ')';
                thisForCall = null;
            }
        }
        if (mode === 'delete') { this.prec = conds.length ? P_COND : P_UNARY; return conds.length ? conds.join('||') + '?true:delete ' + cur : 'delete ' + cur; }
        if (!conds.length) { this.prec = P_CALL; return cur; }
        this.prec = P_COND;
        return conds.join('||') + '?void 0:' + cur;
    };
    P.meta = function (n) {
        if (n.meta.name === 'new') {
            var t = this.ctx.thisCtx;
            if (t.kind === 'method' || t.kind === 'static' || t.kind === 'program') { this.prec = P_UNARY; return 'void 0'; }
            if (!t.ntAlias) t.ntAlias = this.fresh('_newTarget');
            this.prec = P_PRIMARY;
            return t.ntAlias;
        }
        throw new Unsupported('import.meta');
    };

    // ---- destructuring: 'target=value' strings into out; mode decl (declared names), hoist (names declared in the
    // function around a loop function), assign (any assignment target)
    P.destructure = function (p, value, out, mode) {
        var i, t, el;
        switch (p.type) {
            case 'Identifier': {
                var name = mode === 'assign' ? this.E(p, P_CALL) : this.bname(p);
                if (mode === 'hoist') this.hoistVar(name);
                out.push(name + '=' + value);
                return;
            }
            case 'MemberExpression':
                out.push(this.member(p) + '=' + value);
                return;
            case 'AssignmentPattern':
                t = this.temp();
                this.destructure(p.left, '(' + t + '=' + value + ')===void 0?' + this.E(p.right, P_ASSIGN) + ':' + t, out, mode);
                return;
            case 'ObjectPattern': {
                var props = p.properties, src = value, rest = props.length && props[props.length - 1].type === 'RestElement', keys = [];
                if (!(props.length === 1 && !rest && isIdentCode(value))) { t = this.temp(); out.push(t + '=' + value); src = t; }
                for (i = 0; i < props.length; i++) {
                    var pr = props[i], access;
                    if (pr.type === 'RestElement') { this.destructure(pr.argument, this.h('__br_objRest') + '(' + src + ',[' + keys.join(',') + '])', out, mode); continue; }
                    if (pr.computed) {
                        var kc = this.E(pr.key, P_ASSIGN);
                        if (rest && !isIdentCode(kc) && pr.key.type !== 'Literal') { var kt = this.temp(); out.push(kt + '=' + kc); kc = kt; }
                        access = src + '[' + kc + ']';
                        keys.push(kc);
                    } else if (pr.key.type === 'Identifier') { access = src + '.' + pr.key.name; keys.push(quote(pr.key.name)); }
                    else { access = src + '[' + quote(String(pr.key.value)) + ']'; keys.push(quote(String(pr.key.value))); }
                    this.destructure(pr.value, access, out, mode);
                }
                return;
            }
            case 'ArrayPattern': {
                var els = p.elements, hasRest = els.length && els[els.length - 1] && els[els.length - 1].type === 'RestElement';
                t = this.temp();
                out.push(t + '=' + this.h('__br_arr') + '(' + value + ',' + (hasRest ? -1 : els.length) + ')');
                for (i = 0; i < els.length; i++) {
                    el = els[i];
                    if (!el) continue;
                    if (el.type === 'RestElement') this.destructure(el.argument, t + '.slice(' + i + ')', out, mode);
                    else this.destructure(el, t + '[' + i + ']', out, mode);
                }
                return;
            }
        }
        throw new Unsupported('pattern ' + p.type);
    };

    // ---- functions
    P.param = function (p, i) {
        var arg = 'arguments[' + i + ']', val;
        if (p.type === 'RestElement') { val = 'Array.prototype.slice.call(arguments,' + i + ')'; p = p.argument; }
        else if (p.type === 'AssignmentPattern') { val = 'arguments.length>' + i + '&&' + arg + '!==void 0?' + arg + ':' + this.E(p.right, P_ASSIGN); p = p.left; }
        else val = arg;
        if (p.type === 'Identifier') return 'var ' + p.name + '=' + val + ';';
        var list = [];
        this.destructure(p, val, list, 'decl');
        return 'var ' + list.join(',') + ';';
    };
    // o: {superRef, supVar, fields, accessor}
    P.func = function (n, kind, name, o) {
        if (n.async || n.generator) return this.genFunc(n, kind, name, o);
        var ctx = this.push(kind, n), i;
        if (o) {
            if (o.superRef !== undefined) ctx.superRef = o.superRef;
            if (o.supVar) ctx.superCtor = o.supVar;
            if (o.fields) ctx.fieldNodes = o.fields;
        }
        if (kind === 'dctor') { ctx.derivedThis = this.fresh('_this'); ctx.declare(ctx.derivedThis); }
        var params = [], pre = '', simple = n.params.length;
        for (i = 0; i < n.params.length; i++) if (n.params[i].type !== 'Identifier') { simple = i; break; }
        for (i = 0; i < simple; i++) params.push(n.params[i].name);
        for (i = simple; i < n.params.length; i++) pre += this.param(n.params[i], i);
        if (kind === 'ctor' && ctx.fieldNodes) pre += this.fieldStmts(ctx.fieldNodes);
        var dirs = '', body;
        if (n.expression) body = 'return ' + this.E(n.body, P_ASSIGN) + ';';
        else {
            var st = n.body.body, k = 0;
            while (k < st.length && st[k].directive !== undefined) { dirs += sliceStmt(this.src, st[k]); k++; }
            body = this.block(k ? st.slice(k) : st, false);
        }
        if (kind === 'dctor') body += 'return ' + ctx.derivedThis + ';';
        if (ctx.ntAlias) {
            if (kind === 'ctor' || kind === 'dctor') ctx.ntCode = 'this.constructor';
            else { if (!name) name = this.fresh('_f'); ctx.ntCode = 'this instanceof ' + name + '?this.constructor:void 0'; }
        }
        this.pop();
        var head = o && o.accessor ? '' : 'function' + (name ? ' ' + name : '');
        return head + '(' + params.join(',') + '){' + dirs + this.declLine(ctx) + pre + body + '}';
    };

    // ---- classes
    P.classKey = function (m, priv) {
        if (m.key.type === 'PrivateIdentifier') return quote(priv['$' + m.key.name]);
        if (m.computed) return this.E(m.key, P_ASSIGN);
        if (m.key.type === 'Identifier') return quote(m.key.name);
        return quote(String(m.key.value));
    };
    P.fieldExprs = function (fields) {
        var out = [], target = this.thisCode();
        for (var i = 0; i < fields.length; i++) {
            var f = fields[i], val = f.m.value ? this.E(f.m.value, P_ASSIGN) : 'void 0';
            if (f.priv) out.push(this.h('__br_defp') + '(' + target + ',' + quote(f.priv) + ',' + val + ')');
            else if (f.keyTemp) out.push(target + '[' + f.keyTemp + ']=' + val);
            else out.push(target + f.access + '=' + val);
        }
        return out;
    };
    P.fieldStmts = function (fields) { var e = this.fieldExprs(fields); return e.length ? e.join(';') + ';' : ''; };
    P.superCall = function (n) {
        var t = this.ctx.thisCtx;
        if (t.kind !== 'dctor') throw new Unsupported('super() outside a derived constructor');
        var args = hasSpread(n.arguments) ? this.spreadArray(n.arguments) : '[' + this.args(n.arguments) + ']';
        var parts = [t.derivedThis + '=' + this.h('__br_super') + '(this,' + t.superCtor + ',' + args + ')'];
        if (t.fieldNodes) parts = parts.concat(this.fieldExprs(t.fieldNodes));
        parts.push(t.derivedThis);
        this.prec = P_SEQ;
        return parts.join(',');
    };
    P.classExpr = function (n, hint) {
        var name = n.id ? n.id.name : hint && IDENT.test(hint) && !ES5_RESERVED[hint] ? hint : this.fresh('_class');
        var supCode = n.superClass ? this.E(n.superClass, P_ASSIGN) : null;
        var supVar = supCode !== null ? this.fresh('_super') : null;
        var ctx = this.push('static', n);
        ctx.className = name;
        ctx.superRef = supVar;
        var priv = {}, members = n.body.body, i, m;
        for (i = 0; i < members.length; i++) {
            m = members[i];
            if (m.key && m.key.type === 'PrivateIdentifier' && !priv['$' + m.key.name]) priv['$' + m.key.name] = '__br$' + m.key.name + '$' + this.pfx + (++this.uid);
        }
        this.privStack.push(priv);
        var ctor = null, proto = [], stat = [], fields = [], statics = [], keyPre = '';
        for (i = 0; i < members.length; i++) {
            m = members[i];
            if (m.type === 'MethodDefinition') {
                if (m.kind === 'constructor') { ctor = m; continue; }
                var key = this.classKey(m, priv);
                var fn = this.func(m.value, 'method', null, { superRef: supVar ? (m.static ? supVar : supVar + '.prototype') : null });
                (m.static ? stat : proto).push(key, fn, m.kind === 'get' ? '1' : m.kind === 'set' ? '2' : '0');
            } else if (m.type === 'PropertyDefinition') {
                var f = { m: m };
                if (m.key.type === 'PrivateIdentifier') f.priv = priv['$' + m.key.name];
                else if (m.computed) { f.keyTemp = this.temp('_key'); keyPre += f.keyTemp + '=' + this.E(m.key, P_ASSIGN) + ';'; }
                else f.access = m.key.type === 'Identifier' ? '.' + m.key.name : '[' + quote(String(m.key.value)) + ']';
                (m.static ? statics : fields).push(f);
            } else if (m.type === 'StaticBlock') statics.push({ block: m });
        }
        var ctorCode;
        if (ctor) ctorCode = this.func(ctor.value, supVar ? 'dctor' : 'ctor', name, { superRef: supVar ? supVar + '.prototype' : null, supVar: supVar, fields: fields });
        else {
            var cc = this.push(supVar ? 'dctor' : 'ctor', null), cbody;
            cc.superRef = supVar ? supVar + '.prototype' : null;
            if (supVar) {
                cc.derivedThis = this.fresh('_this');
                cc.declare(cc.derivedThis);
                cbody = cc.derivedThis + '=' + this.h('__br_super') + '(this,' + supVar + ',arguments);' + this.fieldStmts(fields) + 'return ' + cc.derivedThis + ';';
            } else cbody = this.fieldStmts(fields);
            this.pop();
            ctorCode = 'function ' + name + '(){' + this.declLine(cc) + cbody + '}';
        }
        var st = '';
        for (i = 0; i < statics.length; i++) {
            var s = statics[i];
            if (s.block) {
                var fnNode = { type: 'FunctionExpression', id: null, params: [], generator: false, async: false, expression: false, $d: true,
                               body: { type: 'BlockStatement', body: s.block.body, $d: true } };
                st += '(' + this.func(fnNode, 'fn', null, { superRef: supVar }) + ').call(' + name + ');';
                continue;
            }
            var v = s.m.value ? this.E(s.m.value, P_ASSIGN) : 'void 0';
            if (s.priv) st += this.h('__br_defp') + '(' + name + ',' + quote(s.priv) + ',' + v + ');';
            else if (s.keyTemp) st += name + '[' + s.keyTemp + ']=' + v + ';';
            else st += name + s.access + '=' + v + ';';
        }
        this.privStack.pop();
        var body = ctorCode + (supVar ? this.h('__br_inherits') + '(' + name + ',' + supVar + ');' : '') + keyPre +
                   this.h('__br_class') + '(' + name + ',' + (proto.length ? '[' + proto.join(',') + ']' : 'null') + ',' + (stat.length ? '[' + stat.join(',') + ']' : 'null') + ');' +
                   st + 'return ' + name + ';';
        this.pop();
        this.prec = P_CALL;
        return '(function(' + (supVar || '') + '){' + this.declLine(ctx) + body + '})(' + (supCode === null ? '' : supCode) + ')';
    };

    // ---- statements
    var MULTI = { VariableDeclaration: 1, FunctionDeclaration: 1, ClassDeclaration: 1, ForStatement: 1, ForInStatement: 1, ForOfStatement: 1,
                  WhileStatement: 1, DoWhileStatement: 1, LabeledStatement: 1 };
    P.S = function (n) {
        if (!n.$d) return sliceStmt(this.src, n);
        switch (n.type) {
            case 'ExpressionStatement': {
                var code = this.E(n.expression, P_SEQ);
                if (/^(?:function\b|class\b|\{|let\s*\[)/.test(code)) code = '(' + code + ')';
                return code + ';';
            }
            case 'BlockStatement': return '{' + this.block(n.body, true) + '}';
            case 'EmptyStatement': return ';';
            case 'VariableDeclaration': { var v = this.varDecl(n, false); return v ? v + ';' : ''; }
            case 'FunctionDeclaration': return n.$lexfn ? this.lexFn(n) : this.func(n, 'fn', n.id.name, null);
            case 'ClassDeclaration': {
                var cn = this.bname(n.id);
                if (this.ctx.kind === 'gen') { this.hoistVar(cn); return cn + '=' + this.classExpr(n, null) + ';'; }
                return 'var ' + cn + '=' + this.classExpr(n, null) + ';';
            }
            case 'ReturnStatement': return this.ret(n);
            case 'IfStatement': return 'if(' + this.E(n.test, P_SEQ) + ')' + this.sub(n.consequent) + (n.alternate ? 'else ' + this.sub(n.alternate) : '');
            case 'ForStatement': case 'ForInStatement': case 'ForOfStatement': case 'WhileStatement': case 'DoWhileStatement': return this.loop(n, []);
            case 'LabeledStatement': return this.labeled(n, []);
            case 'BreakStatement': case 'ContinueStatement': return this.jump(n);
            case 'ThrowStatement': return 'throw ' + this.E(n.argument, P_SEQ) + ';';
            case 'TryStatement': return this.tryStmt(n);
            case 'SwitchStatement': return this.switchStmt(n);
            case 'WithStatement': return 'with(' + this.E(n.object, P_SEQ) + ')' + this.sub(n.body);
            case 'DebuggerStatement': return 'debugger;';
            case 'ImportDeclaration': case 'ExportNamedDeclaration': case 'ExportDefaultDeclaration': case 'ExportAllDeclaration': throw new Unsupported('module');
        }
        throw new Unsupported(n.type);
    };
    // a statement in the place of one statement (if/else/loop body): several output statements get braces
    P.sub = function (n) {
        var code = this.S(n);
        if (n.$d && MULTI[n.type]) code = '{' + code + '}';
        return code;
    };
    // a statement list; nested (a block below function level): strict function declarations become variables first
    P.block = function (list, nested) {
        var out = '', i, n;
        if (nested) for (i = 0; i < list.length; i++) if (list[i].type === 'FunctionDeclaration' && list[i].$lexfn) out += this.lexFn(list[i]);
        for (i = 0; i < list.length; i++) {
            n = list[i];
            if (nested && n.type === 'FunctionDeclaration' && n.$lexfn) continue;
            out += this.S(n);
        }
        return out;
    };
    P.lexFn = function (n) { return 'var ' + this.bname(n.id) + '=' + this.func(n, 'fn', n.id.name, null) + ';'; };
    // `var` list (or, inside a loop function, assignments to variables of the function around it)
    P.varDecl = function (n, forInit) {
        var hoist = this.hoisting(n.kind), parts = [], i, d, name, c;
        for (i = 0; i < n.declarations.length; i++) {
            d = n.declarations[i];
            if (d.id.type === 'Identifier') {
                name = this.bname(d.id);
                if (hoist) {
                    this.hoistVar(name);
                    if (d.init) parts.push(name + '=' + this.E(d.init, P_ASSIGN));
                    else if (n.kind !== 'var' && !forInit) parts.push(name + '=void 0');
                    continue;
                }
                if (d.init) {
                    c = this.E(d.init, P_ASSIGN);
                    if (forInit && /\bin\b/.test(c)) c = '(' + c + ')';
                    parts.push(name + '=' + c);
                } else parts.push(n.kind === 'var' || forInit ? name : name + '=void 0');
            } else {
                var list = [];
                this.destructure(d.id, d.init ? this.E(d.init, P_ASSIGN) : 'void 0', list, hoist ? 'hoist' : 'decl');
                parts = parts.concat(list);
            }
        }
        if (!parts.length) return '';
        return hoist ? parts.join(',') : 'var ' + parts.join(',');
    };
    P.ret = function (n) {
        var c = this.ctx;
        if (c.kind === 'loop') {
            var info = c.loopInfo;
            info.usesReturn = true;
            return '{' + this.outAssigns(info) + 'return{v:' + (n.argument ? this.E(n.argument, P_ASSIGN) : 'void 0') + '};}';
        }
        if (!n.argument) return c.kind === 'dctor' ? 'return ' + c.derivedThis + ';' : 'return;';
        return 'return ' + this.E(n.argument, P_SEQ) + ';';
    };
    P.labeled = function (n, labels) {
        labels = labels.concat([n.label.name]);
        var body = n.body;
        if (body.type === 'LabeledStatement') return this.labeled(body, labels);
        if (isLoop(body)) return this.loop(body, labels);
        this.ctx.jumps.push({ kind: 'label', labels: labels });
        var code = this.S(body);
        this.ctx.jumps.pop();
        return labels.join(':') + ':' + code;
    };
    P.outAssigns = function (info) {
        var s = '';
        for (var i = 0; i < info.out.length; i++) s += info.out[i][0] + '=' + info.out[i][1] + ';';
        return s;
    };
    P.jump = function (n) {
        var brk = n.type === 'BreakStatement', label = n.label ? n.label.name : null, st = this.ctx.jumps, i, e;
        for (i = st.length - 1; i >= 0; i--) {
            e = st[i];
            if (e.kind === 'boundary') {
                // out of a loop function: the call site does the jump
                var info = e.info, code;
                if (!label || info.labels.indexOf(label) >= 0) {
                    if (brk) { info.usesBreak = true; code = 'return "break";'; } else code = 'return;';
                } else {
                    var key = (brk ? 'b|' : 'c|') + label;
                    if (!info.jumpSet[key]) { info.jumpSet[key] = 1; info.jumps.push({ code: key, brk: brk, label: label }); }
                    code = 'return ' + quote(key) + ';';
                }
                var w = this.outAssigns(info);
                return w ? '{' + w + code + '}' : code;
            }
            if (label) { if ((e.kind === 'loop' || e.kind === 'label') && e.labels.indexOf(label) >= 0) break; }
            else if (e.kind === 'loop' || (brk && e.kind === 'switch')) break;
        }
        return (brk ? 'break' : 'continue') + (label ? ' ' + label : '') + ';';
    };
    P.switchStmt = function (n) {
        var disc = this.E(n.discriminant, P_SEQ), body = '';
        this.ctx.jumps.push({ kind: 'switch', labels: [] });
        for (var i = 0; i < n.cases.length; i++) {
            var c = n.cases[i];
            body += (c.test ? 'case ' + this.E(c.test, P_SEQ) + ':' : 'default:') + this.block(c.consequent, true);
        }
        this.ctx.jumps.pop();
        return 'switch(' + disc + '){' + body + '}';
    };
    P.tryStmt = function (n) {
        var code = 'try' + this.S(n.block);
        if (n.handler) {
            var h = n.handler, param = h.param, pre = '';
            if (!param) code += 'catch(' + this.fresh('_e') + ')';
            else if (param.type === 'Identifier') code += 'catch(' + param.name + ')';
            else {
                var ev = this.fresh('_e'), list = [];
                this.destructure(param, ev, list, 'decl');
                pre = 'var ' + list.join(',') + ';';
                code += 'catch(' + ev + ')';
            }
            code += '{' + pre + this.block(h.body.body, true) + '}';
        }
        if (n.finalizer) code += 'finally' + this.S(n.finalizer);
        return code;
    };
    P.bodyWithPre = function (body, pre) {
        if (!pre) return this.sub(body);
        if (body.type === 'BlockStatement') return '{' + pre + this.block(body.body, true) + '}';
        return '{' + pre + this.S(body) + '}';
    };
    // the binding statement of a for-in/for-of head for one value
    P.forBinding = function (left, value) {
        var hoist = left.type === 'VariableDeclaration' && this.hoisting(left.kind), list;
        if (left.type === 'VariableDeclaration') {
            var d = left.declarations[0];
            if (d.id.type === 'Identifier') {
                var nm = this.bname(d.id);
                if (hoist) { this.hoistVar(nm); return nm + '=' + value + ';'; }
                return 'var ' + nm + '=' + value + ';';
            }
            list = [];
            this.destructure(d.id, value, list, hoist ? 'hoist' : 'decl');
            return (hoist ? '' : 'var ') + list.join(',') + ';';
        }
        if (left.type === 'Identifier' || left.type === 'MemberExpression') return this.E(left, P_CALL) + '=' + value + ';';
        list = [];
        this.destructure(left, value, list, 'assign');
        return list.join(',') + ';';
    };
    P.loop = function (n, labels) {
        var prefix = labels.length ? labels.join(':') + ':' : '';
        if (n.$wrap && !n.$noWrap) return this.wrappedLoop(n, labels, prefix);
        var entry = { kind: 'loop', labels: labels }, code, jumps = this.ctx.jumps;
        switch (n.type) {
            case 'WhileStatement': {
                var test = this.E(n.test, P_SEQ);
                jumps.push(entry);
                code = 'while(' + test + ')' + this.sub(n.body);
                jumps.pop();
                break;
            }
            case 'DoWhileStatement': {
                jumps.push(entry);
                var b = this.sub(n.body);
                jumps.pop();
                code = 'do ' + b + 'while(' + this.E(n.test, P_SEQ) + ');';
                break;
            }
            case 'ForStatement': {
                var init = '';
                if (n.init) {
                    if (n.init.type === 'VariableDeclaration') init = this.varDecl(n.init, true);
                    else { init = this.E(n.init, P_SEQ); if (/\bin\b/.test(init)) init = '(' + init + ')'; }
                }
                var t2 = n.test ? this.E(n.test, P_SEQ) : '', u = n.update ? this.E(n.update, P_SEQ) : '';
                jumps.push(entry);
                code = 'for(' + init + ';' + t2 + ';' + u + ')' + this.sub(n.body);
                jumps.pop();
                break;
            }
            case 'ForInStatement': {
                var left = n.left, head, pre = '';
                if (left.type === 'VariableDeclaration' && left.declarations[0].id.type === 'Identifier') {
                    var nm = this.bname(left.declarations[0].id);
                    if (this.hoisting(left.kind)) { this.hoistVar(nm); head = nm; } else head = 'var ' + nm;
                } else if (left.type === 'Identifier' || left.type === 'MemberExpression') head = this.E(left, P_CALL);
                else { head = this.temp('_k'); pre = this.forBinding(left, head); }
                var right = this.E(n.right, P_SEQ);
                jumps.push(entry);
                code = 'for(' + head + ' in ' + right + ')' + this.bodyWithPre(n.body, pre);
                jumps.pop();
                break;
            }
            case 'ForOfStatement': {
                if (n.await) throw new Unsupported('for await');
                var it = this.temp('_it'), step = this.temp('_s'), rv = this.E(n.right, P_ASSIGN);
                var bind = this.forBinding(n.left, step + '.value');
                jumps.push(entry);
                code = 'for(' + it + '=' + this.h('__br_iter') + '(' + rv + ');!(' + step + '=' + it + '()).done;)' + this.bodyWithPre(n.body, bind);
                jumps.pop();
                break;
            }
        }
        return prefix + code;
    };
    // the head's names of for(let ...): parameters of the loop function
    var headBindings = function (decl) {
        var out = [];
        var walk = function (p) {
            if (!p) return;
            switch (p.type) {
                case 'Identifier': if (p.$b) out.push(p.$b); break;
                case 'ObjectPattern': for (var i = 0; i < p.properties.length; i++) walk(p.properties[i].type === 'RestElement' ? p.properties[i].argument : p.properties[i].value); break;
                case 'ArrayPattern': for (var j = 0; j < p.elements.length; j++) walk(p.elements[j]); break;
                case 'RestElement': walk(p.argument); break;
                case 'AssignmentPattern': walk(p.left); break;
            }
        };
        for (var k = 0; k < decl.declarations.length; k++) walk(decl.declarations[k].id);
        return out;
    };
    var writtenIn = function (b, node) {
        for (var i = 0; i < b.refs.length; i++) { var r = b.refs[i]; if (r.$w && r.start >= node.start && r.end <= node.end) return true; }
        return false;
    };
    // a loop whose closures capture bindings of the iteration: the body becomes a function called per iteration
    P.wrappedLoop = function (n, labels, prefix) {
        var info = { labels: labels, usesBreak: false, usesReturn: false, jumps: [], jumpSet: {}, out: [] };
        var fnName = this.fresh('_loop'), ret = this.temp('_ret'), params = [], args = [], i;
        if (n.type === 'ForStatement' && n.init && n.init.type === 'VariableDeclaration' && n.init.kind !== 'var') {
            var hb = headBindings(n.init);
            for (i = 0; i < hb.length; i++) {
                var nm = hb[i].newName || hb[i].name;
                params.push(nm);
                args.push(nm);
                if (writtenIn(hb[i], n.body)) info.out.push([this.temp('_out'), nm]);
            }
        }
        var val = null, it = null, step = null, key = null;
        if (n.type === 'ForInStatement' || n.type === 'ForOfStatement') { val = this.fresh('_v'); params.push(val); }
        if (n.type === 'ForOfStatement') { if (n.await) throw new Unsupported('for await'); it = this.temp('_it'); step = this.temp('_s'); args.push(step + '.value'); }
        if (n.type === 'ForInStatement') { key = this.temp('_k'); args.push(key); }
        var ctx = this.push('loop', n);
        ctx.loopInfo = info;
        ctx.jumps = [{ kind: 'boundary', info: info }];
        var pro = val ? this.forBinding(n.left, val) : '';
        var body = n.body.type === 'BlockStatement' ? this.block(n.body.body, true) : this.S(n.body);
        var fnCode = 'function(' + params.join(',') + '){' + this.declLine(ctx) + pro + body + this.outAssigns(info) + '}';
        this.pop();
        var call = ret + '=' + fnName + '(' + args.join(',') + ');';
        for (i = 0; i < info.out.length; i++) call += info.out[i][1] + '=' + info.out[i][0] + ';';
        this.ctx.jumps.push({ kind: 'loop', labels: labels });
        if (info.usesBreak) call += 'if(' + ret + '==="break")break;';
        for (i = 0; i < info.jumps.length; i++) {
            var j = info.jumps[i];
            call += 'if(' + ret + '===' + quote(j.code) + ')' + this.jump({ type: j.brk ? 'BreakStatement' : 'ContinueStatement', label: { name: j.label } });
        }
        if (info.usesReturn) call += 'if(typeof ' + ret + '==="object")' + this.ret({ type: 'ReturnStatement', argument: { type: 'Raw', code: ret + '.v', $d: true } });
        this.ctx.jumps.pop();
        var loopCode;
        switch (n.type) {
            case 'ForStatement': {
                var init = n.init ? (n.init.type === 'VariableDeclaration' ? this.varDecl(n.init, true) : this.E(n.init, P_SEQ)) : '';
                loopCode = 'for(' + init + ';' + (n.test ? this.E(n.test, P_SEQ) : '') + ';' + (n.update ? this.E(n.update, P_SEQ) : '') + '){' + call + '}';
                break;
            }
            case 'ForInStatement': loopCode = 'for(' + key + ' in ' + this.E(n.right, P_SEQ) + '){' + call + '}'; break;
            case 'ForOfStatement': loopCode = 'for(' + it + '=' + this.h('__br_iter') + '(' + this.E(n.right, P_ASSIGN) + ');!(' + step + '=' + it + '()).done;){' + call + '}'; break;
            case 'WhileStatement': loopCode = 'while(' + this.E(n.test, P_SEQ) + '){' + call + '}'; break;
            case 'DoWhileStatement': loopCode = 'do{' + call + '}while(' + this.E(n.test, P_SEQ) + ');'; break;
        }
        return 'var ' + fnName + '=' + fnCode + ';' + prefix + loopCode;
    };
    P.programCode = function (ast) {
        var ctx = this.push('program', ast);
        this.program = ctx;
        this.progInit = '';
        var st = ast.body, dirs = '', k = 0;
        while (k < st.length && st[k].directive !== undefined) { dirs += sliceStmt(this.src, st[k]); k++; }
        var body = this.block(k ? st.slice(k) : st, false);
        this.pop();
        return dirs + this.helperCode() + this.declLine(ctx) + this.progInit + body;
    };

    // ------------------------------------------------------------------------------------------------ generators
    // A generator or async function becomes a function returning rt.wrap(machine) / rt.async(machine): the body is
    // cut at every yield/await (and around jumps) into the cases of `while (1) switch (ctx.prev = ctx.next)`, the
    // variables live in the function around the machine, values that must survive a yield go into ctx.t0, t1...
    // (facebook/regenerator's emitter, printed as text here).
    var LEAP = { YieldExpression: 1, AwaitExpression: 1, BreakStatement: 1, ContinueStatement: 1, ReturnStatement: 1, ThrowStatement: 1 };
    var BOUNDARY = { FunctionDeclaration: 1, FunctionExpression: 1, ArrowFunctionExpression: 1, ClassDeclaration: 1, ClassExpression: 1 };
    var containsLeap = function (n) {
        if (!n || typeof n.type !== 'string') return false;
        if (n.$lp !== undefined) return n.$lp;
        var r = false;
        if (LEAP[n.type] || (n.type === 'ForOfStatement' && n.await)) r = true;
        else if (!BOUNDARY[n.type]) {
            for (var k in n) {
                if (k.charAt(0) === '$' || !hasOwn.call(n, k)) continue;
                var v = n[k];
                if (!v || typeof v !== 'object') continue;
                if (Object.prototype.toString.call(v) === '[object Array]') { for (var i = 0; i < v.length && !r; i++) if (containsLeap(v[i])) r = true; }
                else if (typeof v.type === 'string' && containsLeap(v)) r = true;
                if (r) break;
            }
        }
        n.$lp = r;
        return r;
    };
    var anyLeap = function (list) { for (var i = 0; i < list.length; i++) if (list[i] && containsLeap(list[i])) return true; return false; };
    var LOC = String.fromCharCode(1), LOC_RE = new RegExp(LOC + '(\\d+)' + LOC, 'g');
    var LITERAL_CODE = /^(?:\d+(?:\.\d+)?|"(?:[^"\\]|\\.)*"|true|false|null|void 0)$/;
    var GenState = function (cv) {
        this.cv = cv;          // the context variable of the machine
        this.listing = [];     // statement code in order; a location is an index into it
        this.marks = {};       // location id -> index
        this.nloc = 0;
        this.tries = [];       // [tryLoc, catchLoc, finallyLoc, afterLoc]
        this.leaps = [];       // break/continue targets: {kind, labels, brk, cont}
        this.ntemp = 0;
    };
    P.gLoc = function () { return LOC + (++this.ctx.gen.nloc) + LOC; };
    P.gMark = function (loc) { var g = this.ctx.gen; g.marks[loc.slice(1, -1)] = g.listing.length; return loc; };
    P.gEmit = function (code) { this.ctx.gen.listing.push(code); };
    P.gJump = function (loc) { this.gEmit(this.ctx.gen.cv + '.next=' + loc + ';break;'); };
    P.gJumpIf = function (test, loc) { this.gEmit('if(' + test + '){' + this.ctx.gen.cv + '.next=' + loc + ';break;}'); };
    P.gJumpIfNot = function (test, loc) { this.gEmit('if(!(' + test + ')){' + this.ctx.gen.cv + '.next=' + loc + ';break;}'); };
    P.gTemp = function () { var g = this.ctx.gen; return g.cv + '.t' + (g.ntemp++); };
    P.gAssign = function (target, code) { this.gEmit(target + '=' + code + ';'); return target; };
    // the state machine records where it is at the start of try/catch/finally code (exceptions are routed by it)
    P.gPrev = function (loc) { this.gMark(loc); this.gEmit(this.ctx.gen.cv + '.prev=' + loc + ';'); };
    P.gExprStmt = function (code) { if (/^(?:function\b|class\b|\{|let\s*\[)/.test(code)) code = '(' + code + ')'; this.gEmit(code + ';'); };
    P.gAbrupt = function (type, arg) { this.gEmit('return ' + this.ctx.gen.cv + '.abrupt(' + quote(type) + (arg === null ? '' : ',' + arg) + ');'); };
    P.gTarget = function (label, cont) {
        var leaps = this.ctx.gen.leaps;
        for (var i = leaps.length - 1; i >= 0; i--) {
            var e = leaps[i];
            if (label) { if (e.labels.indexOf(label) >= 0 && (!cont || e.kind === 'loop')) return cont ? e.cont : e.brk; }
            else if (e.kind === 'loop' || (!cont && e.kind === 'switch')) return cont ? e.cont : e.brk;
        }
        throw new Unsupported('jump target');
    };
    P.rtName = function () {
        if (!this.rt) { this.rt = this.progTemp('_rt'); this.progInit += this.rt + '=' + this.h('__br_regen') + '();'; }
        return this.rt;
    };
    P.genFunc = function (n, kind, name, o) {
        if (n.async && n.generator) throw new Unsupported('async generator');
        var outer = this.push(kind, n), i;
        if (o && o.superRef !== undefined) outer.superRef = o.superRef;
        var params = [], pre = '', simple = n.params.length;
        for (i = 0; i < n.params.length; i++) if (n.params[i].type !== 'Identifier') { simple = i; break; }
        for (i = 0; i < simple; i++) params.push(n.params[i].name);
        for (i = simple; i < n.params.length; i++) pre += this.param(n.params[i], i);
        var dirs = '', stmts;
        if (n.expression) stmts = [{ type: 'ReturnStatement', argument: n.body, $d: true }];
        else {
            var st = n.body.body, k = 0;
            while (k < st.length && st[k].directive !== undefined) { dirs += sliceStmt(this.src, st[k]); k++; }
            stmts = k ? st.slice(k) : st;
        }
        // the body's function declarations stay declarations of the outer function
        var fdecls = '';
        for (i = 0; i < stmts.length; i++) if (stmts[i].type === 'FunctionDeclaration') { stmts[i].$hoisted = true; fdecls += this.func(stmts[i], 'fn', stmts[i].id.name, null); }
        var cv = this.fresh('_context'), inner = this.push('gen', n), g = inner.gen = new GenState(cv);
        for (i = 0; i < stmts.length; i++) this.gStmt(stmts[i], []);
        var resolve = function (s) { return s.replace(LOC_RE, function (m, id) { return String(g.marks[id]); }); };
        var starts = {}, id, machine = '';
        for (id in g.marks) if (hasOwn.call(g.marks, id)) starts[g.marks[id]] = 1;
        for (i = 0; i < g.listing.length; i++) machine += (i === 0 || starts[i] ? 'case ' + i + ':' : '') + g.listing[i];
        if (starts[g.listing.length] && g.listing.length) machine += 'case ' + g.listing.length + ':';
        machine = resolve(machine) + 'case "end":return ' + cv + '.stop();';
        var tries = [];
        for (i = 0; i < g.tries.length; i++) {
            var t = g.tries[i];
            tries.push('[' + t[0] + (t[1] || t[2] ? ',' + (t[1] || '') : '') + (t[2] ? ',' + t[2] + ',' + t[3] : '') + ']');
        }
        var triesCode = tries.length ? resolve('[' + tries.join(',') + ']') : '';
        this.pop();
        var self = kind === 'arrow' ? this.thisCode() : 'this', rt = this.rtName();
        var body = 'return ' + rt + '.' + (n.async ? 'async' : 'wrap') + '(function(' + cv + '){' + this.declLine(inner) + 'while(1)switch(' + cv + '.prev=' + cv + '.next){' +
                   machine + '}},null,' + self + (triesCode ? ',' + triesCode : '') + ');';
        this.pop();
        var head = o && o.accessor ? '' : 'function' + (name ? ' ' + name : '');
        return head + '(' + params.join(',') + '){' + dirs + this.declLine(outer) + pre + fdecls + body + '}';
    };
    // one statement into the machine
    P.gStmt = function (n, labels) {
        var g = this.ctx.gen, i, after, head, update, test, first, elseLoc, it, step;
        if (n.type === 'FunctionDeclaration') {
            if (!n.$hoisted) { var fname = this.bname(n.id); this.hoistVar(fname); this.gEmit(fname + '=' + this.func(n, 'fn', n.id.name, null) + ';'); }
            return;
        }
        if (!containsLeap(n)) { var code = this.S(n); if (code) this.gEmit(code); return; }
        switch (n.type) {
            case 'ExpressionStatement': this.gx(n.expression, true); return;
            case 'BlockStatement':
                // block functions first (they are hoisted in their block)
                for (i = 0; i < n.body.length; i++) if (n.body[i].type === 'FunctionDeclaration') this.gStmt(n.body[i], []);
                for (i = 0; i < n.body.length; i++) if (n.body[i].type !== 'FunctionDeclaration') this.gStmt(n.body[i], []);
                return;
            case 'LabeledStatement': {
                var lbls = labels.concat([n.label.name]);
                if (isLoop(n.body) || n.body.type === 'LabeledStatement') { this.gStmt(n.body, lbls); return; }
                after = this.gLoc();
                g.leaps.push({ kind: 'label', labels: lbls, brk: after });
                this.gStmt(n.body, []);
                g.leaps.pop();
                this.gMark(after);
                return;
            }
            case 'WhileStatement':
                head = this.gLoc(); after = this.gLoc();
                this.gMark(head);
                this.gJumpIfNot(this.gx(n.test, false), after);
                g.leaps.push({ kind: 'loop', labels: labels, brk: after, cont: head });
                this.gStmt(n.body, []);
                g.leaps.pop();
                this.gJump(head);
                this.gMark(after);
                return;
            case 'DoWhileStatement':
                first = this.gLoc(); test = this.gLoc(); after = this.gLoc();
                this.gMark(first);
                g.leaps.push({ kind: 'loop', labels: labels, brk: after, cont: test });
                this.gStmt(n.body, []);
                g.leaps.pop();
                this.gMark(test);
                this.gJumpIf(this.gx(n.test, false), first);
                this.gMark(after);
                return;
            case 'ForStatement':
                head = this.gLoc(); update = this.gLoc(); after = this.gLoc();
                if (n.init) { if (n.init.type === 'VariableDeclaration') this.gStmt(n.init, []); else this.gx(n.init, true); }
                this.gMark(head);
                if (n.test) this.gJumpIfNot(this.gx(n.test, false), after);
                g.leaps.push({ kind: 'loop', labels: labels, brk: after, cont: update });
                this.gStmt(n.body, []);
                g.leaps.pop();
                this.gMark(update);
                if (n.update) this.gx(n.update, true);
                this.gJump(head);
                this.gMark(after);
                return;
            case 'ForInStatement': case 'ForOfStatement': {
                if (n.await) throw new Unsupported('for await');
                head = this.gLoc(); after = this.gLoc();
                it = this.gTemp();
                if (n.type === 'ForInStatement') this.gAssign(it, this.rtName() + '.keys(' + this.gx(n.right, false) + ')');
                else this.gAssign(it, this.h('__br_iter') + '(' + this.gx(n.right, false) + ')');
                this.gMark(head);
                step = this.gTemp();
                this.gJumpIf('(' + step + '=' + it + '()).done', after);
                this.gEmit(this.forBinding(n.left, step + '.value'));
                g.leaps.push({ kind: 'loop', labels: labels, brk: after, cont: head });
                this.gStmt(n.body, []);
                g.leaps.pop();
                this.gJump(head);
                this.gMark(after);
                return;
            }
            case 'BreakStatement': this.gAbrupt('break', this.gTarget(n.label && n.label.name, false)); return;
            case 'ContinueStatement': this.gAbrupt('continue', this.gTarget(n.label && n.label.name, true)); return;
            case 'SwitchStatement': {
                var disc = this.gAssign(this.gTemp(), this.gx(n.discriminant, false));
                after = this.gLoc();
                var defLoc = this.gLoc(), cond = defLoc, caseLocs = [], hasDefault = false;
                for (i = n.cases.length - 1; i >= 0; i--) {
                    var c = n.cases[i];
                    if (c.test) {
                        if (containsLeap(c.test)) throw new Unsupported('yield in case test');
                        caseLocs[i] = this.gLoc();
                        cond = disc + '===' + this.E(c.test, 10) + '?' + caseLocs[i] + ':' + cond;
                    } else { caseLocs[i] = defLoc; hasDefault = true; }
                }
                this.gEmit(g.cv + '.next=' + cond + ';break;');
                g.leaps.push({ kind: 'switch', labels: labels, brk: after });
                for (i = 0; i < n.cases.length; i++) {
                    this.gMark(caseLocs[i]);
                    for (var j = 0; j < n.cases[i].consequent.length; j++) this.gStmt(n.cases[i].consequent[j], []);
                }
                g.leaps.pop();
                if (!hasDefault) this.gMark(defLoc);
                this.gMark(after);
                return;
            }
            case 'IfStatement':
                elseLoc = n.alternate ? this.gLoc() : null;
                after = this.gLoc();
                this.gJumpIfNot(this.gx(n.test, false), elseLoc || after);
                this.gStmt(n.consequent, []);
                if (elseLoc) { this.gJump(after); this.gMark(elseLoc); this.gStmt(n.alternate, []); }
                this.gMark(after);
                return;
            case 'ReturnStatement': this.gAbrupt('return', n.argument ? this.gx(n.argument, false) : null); return;
            case 'ThrowStatement': this.gEmit('throw ' + this.gx(n.argument, false) + ';'); return;
            case 'VariableDeclaration': {
                for (i = 0; i < n.declarations.length; i++) {
                    var d = n.declarations[i];
                    if (!d.init) {
                        if (d.id.type === 'Identifier') { var vn = this.bname(d.id); this.hoistVar(vn); if (n.kind !== 'var') this.gEmit(vn + '=void 0;'); }
                        continue;
                    }
                    var v = this.gx(d.init, false);
                    if (d.id.type === 'Identifier') { var nm = this.bname(d.id); this.hoistVar(nm); this.gEmit(nm + '=' + v + ';'); }
                    else { var out = []; this.destructure(d.id, v, out, 'hoist'); this.gEmit(out.join(',') + ';'); }
                }
                return;
            }
            case 'TryStatement': {
                after = this.gLoc();
                var h = n.handler, catchLoc = h ? this.gLoc() : null, finLoc = n.finalizer ? this.gLoc() : null, tryLoc = this.gLoc();
                g.tries.push([tryLoc, catchLoc, finLoc, finLoc ? after : null]);
                this.gPrev(tryLoc);
                this.gStmt(n.block, []);
                if (catchLoc) {
                    this.gJump(finLoc || after);
                    this.gPrev(catchLoc);
                    var caught = g.cv + '["catch"](' + tryLoc + ')';
                    if (!h.param) this.gEmit(caught + ';');
                    else if (h.param.type === 'Identifier') {
                        // the catch variable becomes a variable of the outer function (under a fresh name)
                        var b = h.param.$b, en = this.fresh(h.param.name);
                        if (b) { b.newName = en; for (i = 0; i < b.refs.length; i++) markDirty(b.refs[i]); }
                        this.hoistVar(en);
                        this.gEmit(en + '=' + caught + ';');
                    } else { var list = [], ct = this.gTemp(); this.gEmit(ct + '=' + caught + ';'); this.destructure(h.param, ct, list, 'hoist'); this.gEmit(list.join(',') + ';'); }
                    this.gStmt(h.body, []);
                }
                if (finLoc) {
                    this.gPrev(finLoc);
                    this.gStmt(n.finalizer, []);
                    this.gEmit('return ' + g.cv + '.finish(' + finLoc + ');');
                }
                this.gMark(after);
                return;
            }
            case 'EmptyStatement': return;
        }
        throw new Unsupported('yield in ' + n.type);
    };
    // an expression into the machine: its value as code (a temporary when later parts yield), or emitted as a
    // statement (ignore)
    P.gx = function (n, ignore) {
        var g = this.ctx.gen, self = this, i, code, after, result, elseLoc;
        if (!containsLeap(n)) {
            if (ignore) { this.gExprStmt(this.E(n, P_SEQ)); return null; }
            return this.E(n, P_PRIMARY);
        }
        var kids = !(n.type === 'YieldExpression' || n.type === 'AwaitExpression') || containsLeap(n.argument);
        var viaTemp = function (temp, child, ignoreChild) {
            var r = self.gx(child, ignoreChild);
            if (ignoreChild) return r;
            if (temp || (kids && !LITERAL_CODE.test(r))) r = self.gAssign(temp || self.gTemp(), r);
            return r;
        };
        var finish = function (c) { if (ignore) { self.gExprStmt(c); return null; } return '(' + c + ')'; };
        // a list of arguments/elements with spreads as one array
        var listCode = function (els) {
            var parts = [], cur = [];
            for (var k = 0; k < els.length; k++) {
                var e = els[k];
                if (e && e.type === 'SpreadElement') { if (cur.length) { parts.push('[' + cur.join(',') + ']'); cur = []; } parts.push(self.h('__br_spread') + '(' + viaTemp(null, e.argument) + ')'); }
                else cur.push(e ? viaTemp(null, e) : 'void 0');
            }
            if (cur.length) parts.push('[' + cur.join(',') + ']');
            if (!parts.length) return '[]';
            return parts.length === 1 ? parts[0] : parts[0] + '.concat(' + parts.slice(1).join(',') + ')';
        };
        switch (n.type) {
            case 'YieldExpression': case 'AwaitExpression': {
                after = this.gLoc();
                var arg = n.argument ? this.gx(n.argument, false) : null;
                if (n.type === 'AwaitExpression') arg = this.rtName() + '.awrap(' + (arg === null ? 'void 0' : arg) + ')';
                if (n.delegate) {
                    var res = this.gTemp();
                    this.gEmit('return ' + g.cv + '.delegateYield(' + arg + ',' + quote(res.slice(g.cv.length + 1)) + ',' + after + ');');
                    this.gMark(after);
                    return res;
                }
                this.gEmit(g.cv + '.next=' + after + ';return' + (arg === null ? '' : ' ' + arg) + ';');
                this.gMark(after);
                return g.cv + '.sent';
            }
            case 'ParenthesizedExpression': return this.gx(n.expression, ignore);
            case 'MemberExpression':
                if (n.object.type === 'Super') return finish(this.ctxSuper() + (n.computed ? '[' + this.gx(n.property, false) + ']' : this.tail(n)));
                return finish(this.gx(n.object, false) + (n.computed ? '[' + viaTemp(null, n.property) + ']' : this.tail(n)));
            case 'CallExpression': {
                if (n.callee.type === 'Super' || n.optional) throw new Unsupported('yield in super()/optional call');
                var callee = n.callee, argsLeap = anyLeap(n.arguments), spread = hasSpread(n.arguments), calleeCode, thisVal = null;
                if (callee.type === 'MemberExpression' && callee.object.type === 'Super') {
                    calleeCode = this.ctxSuper() + (callee.computed ? '[' + viaTemp(null, callee.property) + ']' : this.tail(callee));
                    thisVal = this.thisCode();
                } else if (callee.type === 'MemberExpression' && (argsLeap || spread)) {
                    // the object is its `this`: evaluated first, kept in a temporary
                    thisVal = viaTemp(this.gTemp(), callee.object);
                    calleeCode = thisVal + (callee.computed ? '[' + viaTemp(null, callee.property) + ']' : this.tail(callee));
                } else if (callee.type === 'MemberExpression') calleeCode = this.gx(callee, false);
                else {
                    calleeCode = viaTemp(null, callee);
                    if (/[.[]/.test(calleeCode)) calleeCode = '(0,' + calleeCode + ')';
                }
                if (spread) code = calleeCode + '.apply(' + (thisVal || 'void 0') + ',' + listCode(n.arguments) + ')';
                else if (thisVal !== null && (argsLeap || callee.object.type === 'Super')) {
                    var al = [];
                    for (i = 0; i < n.arguments.length; i++) al.push(argsLeap ? viaTemp(null, n.arguments[i]) : this.E(n.arguments[i], P_ASSIGN));
                    code = calleeCode + '.call(' + [thisVal].concat(al).join(',') + ')';
                } else {
                    var a2 = [];
                    for (i = 0; i < n.arguments.length; i++) a2.push(argsLeap ? viaTemp(null, n.arguments[i]) : this.E(n.arguments[i], P_ASSIGN));
                    code = calleeCode + '(' + a2.join(',') + ')';
                }
                return finish(code);
            }
            case 'NewExpression': {
                var nc = viaTemp(null, n.callee);
                if (hasSpread(n.arguments)) return finish(this.h('__br_new') + '(' + nc + ',' + listCode(n.arguments) + ')');
                var na = [];
                for (i = 0; i < n.arguments.length; i++) na.push(viaTemp(null, n.arguments[i]));
                return finish('new (' + nc + ')(' + na.join(',') + ')');
            }
            case 'ArrayExpression': return finish(listCode(n.elements));
            case 'ObjectExpression': {
                var head = [], tail = [], dyn = false;
                for (i = 0; i < n.properties.length; i++) {
                    var pr = n.properties[i];
                    if (pr.type === 'SpreadElement') { dyn = true; tail.push('null', viaTemp(null, pr.argument), '3'); continue; }
                    var kind = pr.kind === 'get' ? 1 : pr.kind === 'set' ? 2 : 0;
                    var key = pr.computed ? viaTemp(null, pr.key) : pr.key.type === 'Identifier' ? quote(pr.key.name) : quote(String(pr.key.value));
                    var val = kind || pr.method ? this.func(pr.value, 'method', null, { superRef: 'Object.getPrototypeOf(this)' }) : viaTemp(null, pr.value);
                    if (pr.computed) dyn = true;
                    if (!dyn && !kind) head.push(key + ':' + val); else { dyn = true; tail.push(key, val, String(kind)); }
                }
                code = '{' + head.join(',') + '}';
                return finish(tail.length ? this.h('__br_props') + '(' + code + ',[' + tail.join(',') + '])' : code);
            }
            case 'TemplateLiteral': {
                var q = n.quasis, parts = [];
                for (i = 0; i < n.expressions.length; i++) { parts.push(viaTemp(null, n.expressions[i])); if (q[i + 1].value.cooked) parts.push(quote(q[i + 1].value.cooked)); }
                return finish(quote(q[0].value.cooked) + '.concat(' + parts.join(',') + ')');
            }
            case 'SequenceExpression': {
                for (i = 0; i < n.expressions.length - 1; i++) this.gx(n.expressions[i], true);
                return this.gx(n.expressions[n.expressions.length - 1], ignore);
            }
            case 'LogicalExpression': {
                after = this.gLoc();
                result = ignore ? null : this.gTemp();
                var left = viaTemp(result, n.left);
                if (n.operator === '&&') this.gJumpIfNot(left, after);
                else if (n.operator === '||') this.gJumpIf(left, after);
                else this.gJumpIf(left + '!=null', after);
                viaTemp(result, n.right, ignore);
                this.gMark(after);
                return result;
            }
            case 'ConditionalExpression': {
                elseLoc = this.gLoc(); after = this.gLoc();
                this.gJumpIfNot(this.gx(n.test, false), elseLoc);
                result = ignore ? null : this.gTemp();
                viaTemp(result, n.consequent, ignore);
                this.gJump(after);
                this.gMark(elseLoc);
                viaTemp(result, n.alternate, ignore);
                this.gMark(after);
                return result;
            }
            case 'UnaryExpression': return finish(n.operator + (/^[a-z]/.test(n.operator) ? ' ' : '') + this.gx(n.argument, false));
            case 'BinaryExpression': {
                var l = viaTemp(null, n.left), r = viaTemp(null, n.right);
                return finish(n.operator === '**' ? 'Math.pow(' + l + ',' + r + ')' : l + ' ' + n.operator + ' ' + r);
            }
            case 'UpdateExpression': return finish(n.prefix ? n.operator + this.gx(n.argument, false) : this.gx(n.argument, false) + n.operator);
            case 'AssignmentExpression': {
                var op = n.operator, lhs;
                if (n.left.type === 'ObjectPattern' || n.left.type === 'ArrayPattern') {
                    var t = this.gAssign(this.gTemp(), this.gx(n.right, false)), outl = [];
                    this.destructure(n.left, t, outl, 'assign');
                    this.gEmit(outl.join(',') + ';');
                    return ignore ? null : t;
                }
                if (op === '||=' || op === '&&=' || op === '??=') throw new Unsupported('yield in logical assignment');
                lhs = n.left.type === 'MemberExpression' ? (n.left.object.type === 'Super' ? this.ctxSuper() : viaTemp(null, n.left.object)) + (n.left.computed ? '[' + viaTemp(null, n.left.property) + ']' : this.tail(n.left)) : this.E(n.left, P_CALL);
                if (op === '=') return finish(lhs + '=' + this.gx(n.right, false));
                var saved = this.gAssign(this.gTemp(), lhs), rhs = this.gx(n.right, false);
                return finish(lhs + '=' + (op === '**=' ? 'Math.pow(' + saved + ',' + rhs + ')' : saved + ' ' + op.slice(0, -1) + ' ' + rhs));
            }
            case 'ChainExpression': {
                // (await x)?.y: only the start of the chain may wait
                var base = n.expression, linkLeap = false;
                while (base.type === 'MemberExpression' || base.type === 'CallExpression') {
                    if (base.type === 'MemberExpression' ? base.computed && containsLeap(base.property) : anyLeap(base.arguments)) linkLeap = true;
                    base = base.type === 'MemberExpression' ? base.object : base.callee;
                }
                if (linkLeap) throw new Unsupported('yield inside an optional chain');
                return finish(this.chain(n.expression, null, viaTemp(null, base)));
            }
        }
        throw new Unsupported('yield in ' + n.type);
    };

    // ------------------------------------------------------------------------------------------------ entry points
    var parse = function (src) {
        var acorn = root.acorn;
        if (!acorn || !acorn.parse) throw new Unsupported('acorn missing');
        return acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'script', allowHashBang: true, allowReturnOutsideFunction: true,
                                  allowReserved: true, locations: false });
    };
    // the ES5 text for src; null when nothing needs lowering. Throws Unsupported for what it cannot do.
    var transpile = function (src, opts) {
        var ast = parse(src);
        var w = new Walker(src);
        var ps = new Scope('program', null, ast, hasUseStrict(ast.body));
        w.stmts(ast.body, ast, ps, false);
        if (w.module) throw new Unsupported('module');
        w.resolve(ast);
        var dirty = false;
        for (var i = 0; i < ast.body.length; i++) if (ast.body[i].$d) { dirty = true; break; }
        if (!dirty) return null;
        return new Printer(src, w, opts).programCode(ast);
    };
    var engineParses = function (src) {
        try { new Function(src); return true; } catch (e) { return false; }   // eslint-disable-line no-new-func
    };
    var stats = { runs: 0, skipped: 0, lowered: 0, failed: 0, ms: 0, last: '' };
    // for the app: '' when the engine takes the script as it is (or it cannot be lowered), else the ES5 text;
    // JSFix.last() tells which ("es5", "lowered", or why it failed)
    var run = function (src, optsJSON) {
        var opts = null;
        try { opts = optsJSON ? JSON.parse(optsJSON) : {}; } catch (e) { opts = {}; }
        stats.runs++;
        if (!opts.force && engineParses(src)) { stats.skipped++; stats.last = 'es5'; return ''; }
        var t0 = new Date().getTime(), out = null;
        try { out = transpile(src, opts); } catch (e2) {
            stats.failed++;
            stats.last = 'failed: ' + ((e2 && (e2.message || e2.what)) || String(e2));
            return '';
        }
        stats.ms += new Date().getTime() - t0;
        if (out === null) { stats.failed++; stats.last = 'failed: nothing to lower'; return ''; }
        if (!opts.force && !engineParses(out)) {
            var why = '';
            try { new Function(out); } catch (e3) { why = e3.message; }   // eslint-disable-line no-new-func
            stats.failed++;
            stats.last = 'failed: output does not parse (' + why + ')';
            return '';
        }
        stats.lowered++;
        stats.last = 'lowered';
        return out;
    };
    root.JSFix = { transpile: transpile, run: run, stats: stats, last: function () { return stats.last; }, version: 1, Unsupported: Unsupported };
})(this);
