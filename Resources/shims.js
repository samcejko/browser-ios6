/* shims.js - small browser API shims for the iOS 6 WebKit, loaded after core-js, regenerator, fetch,
 * IntersectionObserver and ResizeObserver polyfills. ES5 only. */
(function (window, document) {
    'use strict';
    var Ep = window.Element && window.Element.prototype;

    // Object.prototype.toString as in ES2015: an object's Symbol.toStringTag names it. core-js's Map, Set, Promise...
    // came out "[object Object]", and libraries tell types that way: Vue made a reactive Map with the handlers of a
    // plain object, so its methods ran on the proxy ("Incompatible receiver, Map required": kosik.cz), lodash's
    // clones and comparisons took them for plain objects too.
    (function () {
        var TAG = window.Symbol && window.Symbol.toStringTag, native = Object.prototype.toString;
        if (!TAG || native.__brTag) return;
        try { if (window.Map && native.call(new window.Map()) === '[object Map]') return; } catch (e0) {}
        var toString = function toString() {
            var s = native.call(this);
            if (s !== '[object Object]') return s;
            var t;
            try { t = this[TAG]; } catch (e) { return s; }
            return typeof t === 'string' ? '[object ' + t + ']' : s;
        };
        toString.__brTag = true;
        try { Object.defineProperty(Object.prototype, 'toString', { value: toString, writable: true, configurable: true, enumerable: false }); } catch (e1) {}
    })();

    // requestAnimationFrame (only the webkit prefixed one exists)
    if (!window.requestAnimationFrame) {
        window.requestAnimationFrame = window.webkitRequestAnimationFrame || function (cb) { return window.setTimeout(function () { cb(Date.now()); }, 16); };
        window.cancelAnimationFrame = window.webkitCancelAnimationFrame || window.webkitCancelRequestAnimationFrame || function (id) { window.clearTimeout(id); };
    }
    // Frames on a budget: a page that draws every frame (stripe.com's WebGL gradient) kept the page's thread busy all
    // the time on this hardware, and taps, scrolling and the rest of the page waited. After a frame that took more
    // than 20 ms the next one waits as long again: such drawing gets about half the time, and the animation runs slower.
    (function () {
        var native = window.requestAnimationFrame;
        if (!native || native.__brBudget) return;
        var queue = [], nextId = 1, pending = false, lastCost = 0, lastEnd = 0;
        var run = function (ts) {
            pending = false;
            var list = queue, t0 = Date.now();
            queue = [];
            for (var i = 0; i < list.length; i++) {
                if (list[i].off) continue;
                try { list[i].cb(ts); } catch (e) { window.setTimeout(function () { throw e; }, 0); }
            }
            lastEnd = Date.now();
            lastCost = lastEnd - t0;
        };
        var schedule = function () {
            if (pending) return;
            pending = true;
            var wait = lastCost > 20 ? lastEnd + lastCost - Date.now() : 0;
            if (wait > 0) window.setTimeout(function () { native.call(window, run); }, wait);
            else native.call(window, run);
        };
        window.requestAnimationFrame = function (cb) {
            var id = nextId++;
            queue.push({ id: id, cb: cb });
            schedule();
            return id;
        };
        window.cancelAnimationFrame = function (id) {
            for (var i = 0; i < queue.length; i++) if (queue[i].id === id) queue[i].off = true;
        };
        window.requestAnimationFrame.__brBudget = true;
        if (window.webkitRequestAnimationFrame) {
            window.webkitRequestAnimationFrame = window.requestAnimationFrame;
            window.webkitCancelAnimationFrame = window.webkitCancelRequestAnimationFrame = window.cancelAnimationFrame;
        }
    })();
    if (!window.MutationObserver && window.WebKitMutationObserver) window.MutationObserver = window.WebKitMutationObserver;
    if (!window.requestIdleCallback) {
        window.requestIdleCallback = function (cb) { return window.setTimeout(function () { var start = Date.now(); cb({ didTimeout: false, timeRemaining: function () { return Math.max(0, 50 - (Date.now() - start)); } }); }, 1); };
        window.cancelIdleCallback = function (id) { window.clearTimeout(id); };
    }

    // Dates: the old engine reads a date and time without an offset ("2026-09-27T10:00") as UTC, and refuses forms
    // every current browser takes: a space for the T ("2026-09-27 10:00:00"), offsets without a colon (+0200), 1-digit
    // months and days. Since ES2015 a date-time without an offset is local time (a date alone stays UTC): times on
    // pages were two hours off, and "Invalid Date" broke others (sport.cz). Date and Date.parse read these forms here;
    // everything else goes to the engine's own parser.
    (function () {
        var ND = window.Date;
        if (!ND || ND.__brNative) return;
        var ISO = /^([+-]\d{6}|\d{4})(?:-(\d{1,2})(?:-(\d{1,2}))?)?(?:(?:[Tt]|\s+)(\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(?:([Zz])|([+-])(\d{2}):?(\d{2})?)?)?$/;
        var readDate = function (s) {
            var m = ISO.exec(s);
            if (!m) return ND.parse(s);
            var y = +m[1], mo = m[2] ? m[2] - 1 : 0, d = m[3] ? +m[3] : 1;
            var h = m[4] ? +m[4] : 0, mi = m[5] ? +m[5] : 0, sec = m[6] ? +m[6] : 0, ms = m[7] ? +(m[7] + '00').slice(0, 3) : 0;
            if (mo > 11 || d < 1 || d > 31 || h > 24 || mi > 59 || sec > 59 || (h === 24 && (mi || sec || ms))) return NaN;
            // UTC: an offset, or a date alone in the standard form; local: a date-time without an offset, or a date
            // alone written otherwise (2026-9-7, like the other browsers)
            var utc = m[8] || m[9] || (!m[4] && (!m[2] || m[2].length === 2) && (!m[3] || m[3].length === 2)), t;
            if (utc) {
                t = ND.UTC(y, mo, d, h, mi, sec, ms);
                if (y >= 0 && y < 100) { var u = new ND(t); u.setUTCFullYear(y); t = u.getTime(); }
                if (m[9]) t -= (m[9] === '-' ? -1 : 1) * (+m[10] * 60 + (m[11] ? +m[11] : 0)) * 60000;
            } else {
                var l = new ND(y, mo, d, h, mi, sec, ms);
                if (y >= 0 && y < 100) l.setFullYear(y);
                t = l.getTime();
            }
            return t;
        };
        var isDate = function (v) { return Object.prototype.toString.call(v) === '[object Date]'; };
        var D = function Date(year, month, day, hours, minutes, seconds, ms) {
            if (!(this instanceof D)) return ND();   // (called as a function: the current time as text)
            var n = arguments.length, r;
            if (n === 0) r = new ND();
            else if (n === 1) {
                // (a date object keeps its milliseconds: the engine went through its text)
                r = typeof year === 'string' ? new ND(readDate(year)) : isDate(year) ? new ND(year.getTime()) : new ND(year);
            } else {
                // (as many arguments as given: a missing one is not undefined to the engine)
                switch (n) {
                    case 2: r = new ND(year, month); break;
                    case 3: r = new ND(year, month, day); break;
                    case 4: r = new ND(year, month, day, hours); break;
                    case 5: r = new ND(year, month, day, hours, minutes); break;
                    case 6: r = new ND(year, month, day, hours, minutes, seconds); break;
                    default: r = new ND(year, month, day, hours, minutes, seconds, ms);
                }
            }
            // (a subclass constructing: its prototype)
            var p = Object.getPrototypeOf(this);
            if (p !== D.prototype) { try { r.__proto__ = p; } catch (e) {} }
            return r;
        };
        D.prototype = ND.prototype;
        D.parse = function parse(s) { return readDate(String(s)); };
        D.UTC = ND.UTC;
        D.now = ND.now;
        D.toString = function () { return 'function Date() {\n    [native code]\n}'; };
        D.__brNative = ND;
        try { Object.defineProperty(ND.prototype, 'constructor', { value: D, writable: true, configurable: true, enumerable: false }); } catch (e1) { ND.prototype.constructor = D; }
        window.Date = D;
    })();

    // performance: the old engine has no Navigation/User Timing (iOS 8 brought them). Times are taken from here (the
    // polyfills run first in the page, so this is close to the start of the document): the network part of a
    // navigation is not known and counts as instant; the document's own moments are filled in as they happen.
    if (!window.performance) window.performance = {};
    var perf = window.performance, t0 = (perf.timing && perf.timing.navigationStart) || Date.now();
    if (!perf.now) perf.now = function () { return Date.now() - t0; };
    if (!perf.timeOrigin) perf.timeOrigin = t0;
    if (!perf.timing) {
        var timing = {}, T_FIELDS = ['navigationStart', 'unloadEventStart', 'unloadEventEnd', 'redirectStart', 'redirectEnd', 'fetchStart', 'domainLookupStart', 'domainLookupEnd',
                                     'connectStart', 'connectEnd', 'secureConnectionStart', 'requestStart', 'responseStart', 'responseEnd', 'domLoading', 'domInteractive',
                                     'domContentLoadedEventStart', 'domContentLoadedEventEnd', 'domComplete', 'loadEventStart', 'loadEventEnd'];
        for (var tf = 0; tf < T_FIELDS.length; tf++) timing[T_FIELDS[tf]] = /^(unload|redirect|secureConnection|dom[A-Z]|domContent|domComplete|loadEvent)/.test(T_FIELDS[tf]) ? 0 : t0;
        timing.domLoading = t0;
        timing.toJSON = function () { var o = {}; for (var i = 0; i < T_FIELDS.length; i++) o[T_FIELDS[i]] = this[T_FIELDS[i]]; return o; };
        perf.timing = timing;
        var stamp = function (names) { var now = Date.now(); for (var i = 0; i < names.length; i++) if (!timing[names[i]]) timing[names[i]] = now; };
        var interactive = function () { stamp(['domInteractive', 'domContentLoadedEventStart']); setTimeout(function () { stamp(['domContentLoadedEventEnd']); }, 0); };
        if (document.readyState === 'interactive' || document.readyState === 'complete') interactive();
        else document.addEventListener('DOMContentLoaded', interactive, false);
        window.addEventListener('load', function () { stamp(['domInteractive', 'domContentLoadedEventStart', 'domContentLoadedEventEnd', 'domComplete', 'loadEventStart']); setTimeout(function () { stamp(['loadEventEnd']); }, 0); }, false);
    }
    if (!perf.navigation) perf.navigation = { type: 0, redirectCount: 0, TYPE_NAVIGATE: 0, TYPE_RELOAD: 1, TYPE_BACK_FORWARD: 2, TYPE_RESERVED: 255, toJSON: function () { return { type: this.type, redirectCount: this.redirectCount }; } };
    // the entry interfaces (rohlik.cz: `entry instanceof PerformanceNavigationTiming` was a ReferenceError)
    var perfClass = function (name, parent) {
        if (window[name]) return window[name];
        var C = function () { throw new TypeError('Illegal constructor'); };
        try { C.prototype = Object.create(parent ? parent.prototype : Object.prototype); C.prototype.constructor = C; } catch (e) {}
        window[name] = C;
        return C;
    };
    var PerfEntry = perfClass('PerformanceEntry', null);
    var PerfResource = perfClass('PerformanceResourceTiming', PerfEntry);
    var PerfNavigation = perfClass('PerformanceNavigationTiming', PerfResource);
    var PerfMark = perfClass('PerformanceMark', PerfEntry);
    var PerfMeasure = perfClass('PerformanceMeasure', PerfEntry);
    perfClass('PerformancePaintTiming', PerfEntry);
    perfClass('PerformanceEventTiming', PerfEntry);
    perfClass('PerformanceLongTaskTiming', PerfEntry);
    perfClass('LargestContentfulPaint', PerfEntry);
    perfClass('LayoutShift', PerfEntry);
    perfClass('PerformanceObserverEntryList', null);
    var perfObject = function (C, fields) { var o; try { o = Object.create(C.prototype); } catch (e) { o = {}; } for (var k in fields) if (fields.hasOwnProperty(k)) o[k] = fields[k]; return o; };
    if (!perf.getEntries) {
        // User Timing (mark / measure) and a navigation entry made from the timing above
        var entries = [];
        var navigationEntry = function () {
            var t = perf.timing, rel = function (v) { return v ? v - t0 : 0; };
            var e = perfObject(PerfNavigation, { name: location.href, entryType: 'navigation', startTime: 0, initiatorType: 'navigation', type: 'navigate', redirectCount: 0,
                      workerStart: 0, redirectStart: 0, redirectEnd: 0, fetchStart: 0, domainLookupStart: 0, domainLookupEnd: 0, connectStart: 0, connectEnd: 0,
                      secureConnectionStart: 0, requestStart: 0, responseStart: 0, responseEnd: 0, transferSize: 0, encodedBodySize: 0, decodedBodySize: 0,
                      unloadEventStart: 0, unloadEventEnd: 0, domInteractive: rel(t.domInteractive), domContentLoadedEventStart: rel(t.domContentLoadedEventStart),
                      domContentLoadedEventEnd: rel(t.domContentLoadedEventEnd), domComplete: rel(t.domComplete), loadEventStart: rel(t.loadEventStart), loadEventEnd: rel(t.loadEventEnd),
                      nextHopProtocol: '', serverTiming: [] });
            e.duration = e.loadEventEnd;
            e.toJSON = function () { var o = {}; for (var k in this) if (typeof this[k] !== 'function') o[k] = this[k]; return o; };
            return e;
        };
        var all = function () { return [navigationEntry()].concat(entries); };
        perf.getEntries = function () { return all(); };
        perf.getEntriesByType = function (type) { var out = [], list = all(); for (var i = 0; i < list.length; i++) if (list[i].entryType === type) out.push(list[i]); return out; };
        perf.getEntriesByName = function (name, type) { var out = [], list = all(); for (var i = 0; i < list.length; i++) if (list[i].name === name && (!type || list[i].entryType === type)) out.push(list[i]); return out; };
        var entry = function (name, type, start, duration, detail) { return perfObject(type === 'mark' ? PerfMark : PerfMeasure, { name: String(name), entryType: type, startTime: start, duration: duration, detail: detail === undefined ? null : detail, toJSON: function () { return { name: this.name, entryType: this.entryType, startTime: this.startTime, duration: this.duration, detail: this.detail }; } }); };
        var timeOf = function (v) {
            if (typeof v === 'number') return v;
            if (typeof v === 'string') {
                for (var i = entries.length - 1; i >= 0; i--) if (entries[i].entryType === 'mark' && entries[i].name === v) return entries[i].startTime;
                if (perf.timing[v]) return perf.timing[v] - t0;
                throw new SyntaxError("Failed to execute 'measure': The mark '" + v + "' does not exist.");
            }
            return undefined;
        };
        perf.mark = function (name, opts) {
            var e = entry(name, 'mark', opts && typeof opts.startTime === 'number' ? opts.startTime : perf.now(), 0, opts && opts.detail);
            entries.push(e);
            if (entries.length > 2000) entries.shift();
            return e;
        };
        perf.measure = function (name, start, end) {
            var opts = start && typeof start === 'object' ? start : null, s, e2;
            if (opts) { s = timeOf(opts.start); e2 = opts.end !== undefined ? timeOf(opts.end) : opts.duration !== undefined && s !== undefined ? s + opts.duration : perf.now(); if (s === undefined) s = opts.duration !== undefined ? e2 - opts.duration : 0; }
            else { s = start === undefined ? 0 : timeOf(start); e2 = end === undefined ? perf.now() : timeOf(end); }
            var m = entry(name, 'measure', s, e2 - s, opts && opts.detail);
            entries.push(m);
            if (entries.length > 2000) entries.shift();
            return m;
        };
        var clear = function (type) { return function (name) { for (var i = entries.length - 1; i >= 0; i--) if (entries[i].entryType === type && (name === undefined || entries[i].name === name)) entries.splice(i, 1); }; };
        perf.clearMarks = clear('mark');
        perf.clearMeasures = clear('measure');
        perf.clearResourceTimings = function () {};
        perf.setResourceTimingBufferSize = function () {};
    }
    if (!perf.toJSON) perf.toJSON = function () { return { timeOrigin: perf.timeOrigin, timing: perf.timing && perf.timing.toJSON ? perf.timing.toJSON() : perf.timing, navigation: perf.navigation }; };
    if (!window.PerformanceObserver) {
        window.PerformanceObserver = function () {};
        window.PerformanceObserver.prototype.observe = function () {};
        window.PerformanceObserver.prototype.disconnect = function () {};
        window.PerformanceObserver.prototype.takeRecords = function () { return []; };
        window.PerformanceObserver.supportedEntryTypes = [];
    }

    // Element helpers
    if (Ep) {
        if (!Ep.matches) Ep.matches = Ep.webkitMatchesSelector || Ep.msMatchesSelector || function (s) {
            var list = (this.document || this.ownerDocument).querySelectorAll(s), i = list.length;
            while (--i >= 0 && list.item(i) !== this) {}
            return i > -1;
        };
        if (!Ep.closest) Ep.closest = function (s) { var el = this; while (el && el.nodeType === 1) { if (el.matches(s)) return el; el = el.parentNode; } return null; };
        var toNodes = function toNodes(args) {
            var frag = document.createDocumentFragment();
            for (var i = 0; i < args.length; i++) { var a = args[i]; frag.appendChild(a instanceof Node ? a : document.createTextNode(String(a))); }
            return frag;
        };
        var CN = [Ep, window.CharacterData && window.CharacterData.prototype, window.DocumentType && window.DocumentType.prototype];
        for (var c = 0; c < CN.length; c++) {
            var P = CN[c];
            if (!P) continue;
            if (!P.remove) P.remove = function () { if (this.parentNode) this.parentNode.removeChild(this); };
            if (!P.before) P.before = function () { if (this.parentNode) this.parentNode.insertBefore(toNodes(arguments), this); };
            if (!P.after) P.after = function () { if (this.parentNode) this.parentNode.insertBefore(toNodes(arguments), this.nextSibling); };
            if (!P.replaceWith) P.replaceWith = function () { if (this.parentNode) this.parentNode.replaceChild(toNodes(arguments), this); };
        }
        var PN = [Ep, window.Document && window.Document.prototype, window.DocumentFragment && window.DocumentFragment.prototype];
        for (var p = 0; p < PN.length; p++) {
            var Q = PN[p];
            if (!Q) continue;
            if (!Q.append) Q.append = function () { this.appendChild(toNodes(arguments)); };
            if (!Q.prepend) Q.prepend = function () { this.insertBefore(toNodes(arguments), this.firstChild); };
            if (!Q.replaceChildren) Q.replaceChildren = function () { while (this.lastChild) this.removeChild(this.lastChild); this.appendChild(toNodes(arguments)); };
        }
        // ParentNode properties on fragments and documents, element siblings of text nodes (the old engine has them on
        // elements only): walkers of template.content and shadow roots met undefined (lit.dev's declarative shadow DOM
        // polyfill went through i = i.firstElementChild and then read i.tagName)
        var parentProps = {
            firstElementChild: function () { for (var c = this.firstChild; c; c = c.nextSibling) if (c.nodeType === 1) return c; return null; },
            lastElementChild: function () { for (var c = this.lastChild; c; c = c.previousSibling) if (c.nodeType === 1) return c; return null; },
            childElementCount: function () { var n = 0; for (var c = this.firstChild; c; c = c.nextSibling) if (c.nodeType === 1) n++; return n; },
            children: function () {
                var list = [];
                for (var c = this.firstChild; c; c = c.nextSibling) if (c.nodeType === 1) list.push(c);
                list.item = function (i) { return this[i] || null; };
                return list;
            }
        };
        var siblingProps = {
            nextElementSibling: function () { for (var c = this.nextSibling; c; c = c.nextSibling) if (c.nodeType === 1) return c; return null; },
            previousElementSibling: function () { for (var c = this.previousSibling; c; c = c.previousSibling) if (c.nodeType === 1) return c; return null; }
        };
        var addProps = function (proto, probe, props) {
            if (!proto || !probe) return;
            for (var name in props) if (props.hasOwnProperty(name) && !(name in probe)) {
                try { Object.defineProperty(proto, name, { get: props[name], configurable: true, enumerable: true }); } catch (e) {}
            }
        };
        try {
            addProps(window.DocumentFragment && window.DocumentFragment.prototype, document.createDocumentFragment(), parentProps);
            addProps(window.Document && window.Document.prototype, document, parentProps);
            addProps(window.CharacterData && window.CharacterData.prototype, document.createTextNode(''), siblingProps);
        } catch (eParent) {}
        if (!Ep.getAttributeNames) Ep.getAttributeNames = function () { var r = [], a = this.attributes; for (var i = 0; i < a.length; i++) r.push(a[i].name); return r; };
        if (!Ep.toggleAttribute) Ep.toggleAttribute = function (name, force) { var has = this.hasAttribute(name); if (force === undefined ? has : !force) { if (has) this.removeAttribute(name); return false; } this.setAttribute(name, ''); return true; };
        // classList.toggle(name, force) and classList.replace
        var probe = document.createElement('div');
        if (probe.classList) {
            probe.classList.toggle('a', false);
            if (probe.classList.contains('a')) {
                var origToggle = window.DOMTokenList.prototype.toggle;
                window.DOMTokenList.prototype.toggle = function (name, force) {
                    if (force === undefined) return origToggle.call(this, name);
                    if (force) { this.add(name); return true; }
                    this.remove(name); return false;
                };
            }
            if (!window.DOMTokenList.prototype.replace) window.DOMTokenList.prototype.replace = function (a, b) { if (!this.contains(a)) return false; this.remove(a); this.add(b); return true; };
        }
        if (!Ep.animate) {
            Ep.animate = function () {
                var anim = { playState: 'finished', currentTime: 0, playbackRate: 1, onfinish: null, oncancel: null,
                    cancel: function () {}, finish: function () {}, pause: function () {}, play: function () {}, reverse: function () {},
                    addEventListener: function () {}, removeEventListener: function () {} };
                anim.finished = window.Promise ? window.Promise.resolve(anim) : null;
                anim.ready = anim.finished;
                setTimeout(function () { if (typeof anim.onfinish === 'function') anim.onfinish({ target: anim }); }, 0);
                return anim;
            };
            Ep.getAnimations = function () { return []; };
        }
        if (!Ep.scrollIntoViewIfNeeded) Ep.scrollIntoViewIfNeeded = function () { this.scrollIntoView(); };
        var origScrollIntoView = Ep.scrollIntoView;
        Ep.scrollIntoView = function (arg) { if (arg && typeof arg === 'object') return origScrollIntoView.call(this, arg.block !== 'end'); return origScrollIntoView.apply(this, arguments); };
    }
    // scrollTo / scrollBy with an options object
    function wrapScroll(obj, name) {
        var orig = obj[name];
        if (typeof orig !== 'function') return;
        obj[name] = function (x, y) {
            if (x && typeof x === 'object') return orig.call(this, x.left || 0, x.top || 0);
            return orig.call(this, x, y);
        };
    }
    wrapScroll(window, 'scrollTo'); wrapScroll(window, 'scrollBy'); wrapScroll(window, 'scroll');
    if (Ep) { wrapScroll(Ep, 'scrollTo'); wrapScroll(Ep, 'scrollBy'); }

    // Object.defineProperty(fn, 'name' | 'length', ...): a function's name and length are fixed in the old engine
    // (today they are configurable, and bundlers rename functions and set their arity that way). Refused, they stay
    // as they are instead of the page's script failing ("Attempting to change value of a readonly property").
    (function () {
        var nativeDP = Object.defineProperty, nativeDPs = Object.defineProperties;
        var probe = function f(a) {}, fixed = false;
        try { nativeDP(probe, 'length', { value: 2, configurable: true }); } catch (e) { fixed = true; }
        if (!fixed) return;
        Object.defineProperty = function (o, k, d) {
            if ((k === 'name' || k === 'length') && typeof o === 'function') { try { return nativeDP(o, k, d); } catch (e) { return o; } }
            return nativeDP(o, k, d);
        };
        var own = Object.prototype.hasOwnProperty;
        Object.defineProperties = function (o, props) {
            if (typeof o !== 'function' || !props || !(own.call(props, 'name') || own.call(props, 'length'))) return nativeDPs(o, props);
            var rest = {}, k;
            for (k in props) if (own.call(props, k)) { if (k === 'name' || k === 'length') Object.defineProperty(o, k, props[k]); else rest[k] = props[k]; }
            return nativeDPs(o, rest);
        };
    })();

    // document.currentScript: the running script's URL is read from a stack trace (the first frame that is not this
    // bundle's) and matched with the script elements; inline and eval'd code, or no stack, get the last script element
    // (the running one while the document is parsed). Chunk loaders (Turbopack, webpack's publicPath) read it.
    if (!('currentScript' in document)) {
        var stackURLs = function () {
            try { throw new Error(); } catch (err) {
                var s = String(err.stack || ''), out = [], re = /((?:https?|file):\/\/[^\s@]+?):\d+(?::\d+)?\s*$/gm, m;
                while ((m = re.exec(s))) out.push(m[1]);
                return out;
            }
        };
        var ownScriptURL = stackURLs()[0] || null;
        try {
            Object.defineProperty(document, 'currentScript', { configurable: true, get: function () {
                var scripts = document.getElementsByTagName('script'), urls = stackURLs();
                for (var i = 0; i < urls.length; i++) {
                    if (urls[i] === ownScriptURL) continue;
                    for (var j = scripts.length - 1; j >= 0; j--) if (scripts[j].src === urls[i]) return scripts[j];
                    break;
                }
                return scripts.length ? scripts[scripts.length - 1] : null;
            } });
        } catch (e) {}
    }
    if (!document.scrollingElement) {
        try { Object.defineProperty(document, 'scrollingElement', { get: function () { return document.body; } }); } catch (e2) {}
    }
    if (!document.head) document.head = document.getElementsByTagName('head')[0];

    // Events
    if (!window.CustomEvent || typeof window.CustomEvent !== 'function') {
        window.CustomEvent = function (type, params) { params = params || {}; var e = document.createEvent('CustomEvent'); e.initCustomEvent(type, !!params.bubbles, !!params.cancelable, params.detail); return e; };
    }
    try { new window.Event('x'); } catch (e3) {
        window.Event = function (type, params) { params = params || {}; var e = document.createEvent('Event'); e.initEvent(type, !!params.bubbles, !!params.cancelable); return e; };
    }
    if (!window.KeyboardEvent || typeof window.KeyboardEvent !== 'function') {}
    if (!window.EventTarget) {
        // (new EventTarget(), its subclasses and objects made from its prototype: a listener store of their own)
        var listenersOf = function (t) {
            if (!Object.prototype.hasOwnProperty.call(t, '__listeners')) {
                try { Object.defineProperty(t, '__listeners', { value: {}, writable: true, configurable: true }); } catch (e) { t.__listeners = {}; }
            }
            return t.__listeners;
        };
        window.EventTarget = function EventTarget() { listenersOf(this); };
        window.EventTarget.prototype.addEventListener = function (t, f) { if (!f) return; var all = listenersOf(this), l = all[t] || (all[t] = []); if (l.indexOf(f) < 0) l.push(f); };
        window.EventTarget.prototype.removeEventListener = function (t, f) { var l = listenersOf(this)[t] || []; var i = l.indexOf(f); if (i >= 0) l.splice(i, 1); };
        window.EventTarget.prototype.dispatchEvent = function (e) {
            var l = (listenersOf(this)[e.type] || []).slice();
            for (var i = 0; i < l.length; i++) { var f = l[i]; if (typeof f === 'function') f.call(this, e); else if (f && typeof f.handleEvent === 'function') f.handleEvent(e); }
            return !e.defaultPrevented;
        };
    }

    // AbortController
    if (!window.AbortController) {
        var AbortSignal = function () { this.aborted = false; this.reason = undefined; this.onabort = null; this.__l = []; };
        AbortSignal.prototype.addEventListener = function (t, f) { if (t === 'abort') this.__l.push(f); };
        AbortSignal.prototype.removeEventListener = function (t, f) { var i = this.__l.indexOf(f); if (i >= 0) this.__l.splice(i, 1); };
        AbortSignal.prototype.dispatchEvent = function (e) { for (var i = 0; i < this.__l.length; i++) this.__l[i](e); if (this.onabort) this.onabort(e); };
        AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
        AbortSignal.abort = function (reason) { var c = new window.AbortController(); c.abort(reason); return c.signal; };
        AbortSignal.timeout = function (ms) { var c = new window.AbortController(); setTimeout(function () { c.abort(new Error('TimeoutError')); }, ms); return c.signal; };
        window.AbortController = function () { this.signal = new AbortSignal(); };
        window.AbortController.prototype.abort = function (reason) {
            if (this.signal.aborted) return;
            this.signal.aborted = true;
            this.signal.reason = reason === undefined ? new Error('AbortError') : reason;
            this.signal.dispatchEvent({ type: 'abort', target: this.signal });
        };
        window.AbortSignal = AbortSignal;
    }

    // TextEncoder / TextDecoder (UTF-8)
    if (!window.TextEncoder) {
        window.TextEncoder = function () { this.encoding = 'utf-8'; };
        window.TextEncoder.prototype.encode = function (str) {
            var s = unescape(encodeURIComponent(str || '')), arr = new Uint8Array(s.length);
            for (var i = 0; i < s.length; i++) arr[i] = s.charCodeAt(i);
            return arr;
        };
        window.TextDecoder = function (label) { this.encoding = (label || 'utf-8').toLowerCase(); };
        window.TextDecoder.prototype.decode = function (buf) {
            if (!buf) return '';
            var bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf), s = '';
            for (var i = 0; i < bytes.length; i += 4096) s += String.fromCharCode.apply(null, Array.prototype.slice.call(bytes, i, i + 4096));
            try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
        };
    }

    // crypto
    if (!window.crypto) window.crypto = {};
    if (!window.crypto.getRandomValues) window.crypto.getRandomValues = function (arr) { for (var i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256); return arr; };
    if (!window.crypto.randomUUID) window.crypto.randomUUID = function () {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); });
    };

    // navigator
    if (!navigator.sendBeacon) navigator.sendBeacon = function (url, data) { try { var x = new XMLHttpRequest(); x.open('POST', url, true); x.send(data); } catch (e) {} return true; };
    if (!navigator.languages) try { navigator.languages = [navigator.language || 'en']; } catch (e4) {}
    // (both listener methods: RxJS fromEvent(navigator.connection, 'change') throws 'Invalid event target' otherwise)
    if (!navigator.connection) navigator.connection = { effectiveType: '3g', saveData: false, onchange: null, addEventListener: function () {}, removeEventListener: function () {}, dispatchEvent: function () { return true; } };
    // navigator.clipboard is provided by shims-extra.js (writes go to the app)
    if (!navigator.serviceWorker) navigator.serviceWorker = { register: function () { return window.Promise ? window.Promise.reject(new Error('unsupported')) : null; }, getRegistrations: function () { return window.Promise ? window.Promise.resolve([]) : null; },
        getRegistration: function () { return window.Promise ? window.Promise.resolve(undefined) : null; }, startMessages: function () {}, addEventListener: function () {}, removeEventListener: function () {},
        controller: null, oncontrollerchange: null, onmessage: null, ready: window.Promise ? new window.Promise(function () {}) : null };
    if (!navigator.storage) navigator.storage = { estimate: function () { return window.Promise ? window.Promise.resolve({ quota: 0, usage: 0 }) : null; } };
    if (!('onLine' in navigator)) navigator.onLine = true;
    if (!navigator.mediaDevices) navigator.mediaDevices = { getUserMedia: function () { return window.Promise ? window.Promise.reject(new Error('unsupported')) : null; }, enumerateDevices: function () { return window.Promise ? window.Promise.resolve([]) : null; } };

    // console
    var con = window.console = window.console || {};
    var names = ['log', 'info', 'warn', 'error', 'debug', 'trace', 'group', 'groupEnd', 'groupCollapsed', 'table', 'time', 'timeEnd', 'timeLog', 'count', 'assert', 'dir', 'dirxml'];
    for (var n = 0; n < names.length; n++) if (!con[names[n]]) con[names[n]] = con.log || function () {};

    // matchMedia listeners (addEventListener form)
    if (window.matchMedia) {
        var mql = window.matchMedia('(min-width: 1px)');
        if (mql && !mql.addEventListener) {
            var MQ = Object.getPrototypeOf(mql);
            MQ.addEventListener = function (t, f) { if (t === 'change') this.addListener(f); };
            MQ.removeEventListener = function (t, f) { if (t === 'change') this.removeListener(f); };
        }
    }

    // Intl: iOS 6 has none. A usable implementation for the languages this device meets (Czech, Slovak, English,
    // German, Polish and a generic fallback): numbers, currencies, dates, plurals, relative times, lists, collation.
    if (!window.Intl) (function () {
        var Intl = window.Intl = {};
        var canon = function (loc) {
            var l = loc && typeof loc === 'object' && loc.length !== undefined ? loc[0] : loc;
            if (l && typeof l === 'object' && l.baseName) l = l.baseName;
            return String(l || navigator.language || 'en').replace(/_/g, '-');
        };
        var lang = function (loc) { return canon(loc).split('-')[0].toLowerCase(); };
        var supportedOf = function (list) { var a = typeof list === 'string' ? [list] : (list || []), out = []; for (var i = 0; i < a.length; i++) if (typeof a[i] === 'string') out.push(a[i]); return out; };
        var pad2 = function (n) { return (n < 10 ? '0' : '') + n; };
        // ---- numbers
        // (the spaces are no-break ones, as current engines write them, U+202F narrow in French: a server-rendered
        // page compares its text with the page scripts' own, and a plain space made React throw the whole page away
        // and build it again, rohlik.cz)
        var NB = ' ';
        var SEP = { cs: [NB, ','], sk: [NB, ','], pl: [NB, ','], de: ['.', ','], fr: [' ', ','], it: ['.', ','], es: ['.', ','], ru: [NB, ','], hu: [NB, ','], nl: ['.', ','], pt: ['.', ','], sv: [NB, ','], da: ['.', ','], fi: [NB, ','], nb: [NB, ','], tr: ['.', ','], uk: [NB, ','], en: [',', '.'] };
        var CURRENCY = { CZK: ['Kč', 1], EUR: ['€', 1], USD: ['$', 0], GBP: ['£', 0], PLN: ['zł', 1], HUF: ['Ft', 1], CHF: ['CHF', 0], JPY: ['¥', 0], SEK: ['kr', 1], NOK: ['kr', 1], DKK: ['kr', 1], RUB: ['₽', 1], UAH: ['₴', 1], CNY: ['CN¥', 0], INR: ['₹', 0], BRL: ['R$', 0], CAD: ['CA$', 0], AUD: ['A$', 0] };
        var COMPACT = { cs: ['tis.', 'mil.', 'mld.', 'bil.'], sk: ['tis.', 'mil.', 'mld.', 'bil.'], pl: ['tys.', 'mln', 'mld', 'bln'], de: ['Tsd.', 'Mio.', 'Mrd.', 'Bio.'], en: ['K', 'M', 'B', 'T'] };
        // (NumberFormat, DateTimeFormat and Collator can be called without new: Intl.NumberFormat(lang).format(x) had
        // no this, kosik.cz)
        var NumberFormat = function NumberFormat(locale, opts) {
            if (!(this instanceof NumberFormat)) return new NumberFormat(locale, opts);
            this.locale = canon(locale); this.opts = opts || {};
        };
        NumberFormat.prototype.formatToParts = function (n) {
            var o = this.opts, lg = lang(this.locale), sep = SEP[lg] || SEP.en, v = Number(n), parts = [];
            if (isNaN(v)) return [{ type: 'nan', value: 'NaN' }];
            if (!isFinite(v)) return [{ type: v < 0 ? 'minusSign' : 'plusSign', value: v < 0 ? '-' : '' }, { type: 'infinity', value: '∞' }];
            var style = o.style || 'decimal', currency = o.currency ? String(o.currency).toUpperCase() : null;
            var scaled = style === 'percent' ? v * 100 : v, unitSuffix = '';
            if (o.notation === 'compact') {
                var names = COMPACT[lg] || COMPACT.en, abs = Math.abs(scaled), idx = -1;
                if (abs >= 1e12) idx = 3; else if (abs >= 1e9) idx = 2; else if (abs >= 1e6) idx = 1; else if (abs >= 1e3) idx = 0;
                if (idx >= 0) { scaled = scaled / Math.pow(1000, idx + 1); unitSuffix = (lg === 'en' ? '' : NB) + names[idx]; }
            }
            var minF = o.minimumFractionDigits, maxF = o.maximumFractionDigits;
            // (compact numbers keep two significant digits: 1.2K, 12K, 123K)
            if (maxF === undefined) maxF = style === 'currency' ? (currency === 'JPY' || currency === 'HUF' ? 0 : 2) : style === 'percent' ? 0 : o.notation === 'compact' ? (Math.abs(scaled) < 10 ? 1 : 0) : 3;
            if (minF === undefined) minF = style === 'currency' ? maxF : 0;
            if (minF > maxF) maxF = minF;
            if (o.maximumSignificantDigits) { var sig = Number(scaled.toPrecision(Math.min(21, o.maximumSignificantDigits))); scaled = sig; maxF = Math.max(maxF, 20); minF = 0; }
            var neg = scaled < 0 || (scaled === 0 && 1 / scaled < 0), abs2 = Math.abs(scaled);
            var fixed = abs2.toFixed(Math.min(maxF, 20)), dot = fixed.indexOf('.');
            var intPart = dot < 0 ? fixed : fixed.slice(0, dot), frac = dot < 0 ? '' : fixed.slice(dot + 1);
            frac = frac.replace(/0+$/, '');
            while (frac.length < minF) frac += '0';
            if (o.minimumIntegerDigits) while (intPart.length < o.minimumIntegerDigits) intPart = '0' + intPart;
            // Polish, Spanish and Portuguese group only from five digits on (CLDR minimumGroupingDigits 2)
            var grouping = o.useGrouping !== false && !(o.useGrouping === 'min2' && intPart.length < 5) && (lg !== 'pl' && lg !== 'es' && lg !== 'pt' || intPart.length > 4 || o.useGrouping === true || o.useGrouping === 'always');
            var groups = [];
            if (grouping) { var s = intPart; while (s.length > 3) { groups.unshift(s.slice(-3)); s = s.slice(0, -3); } groups.unshift(s); } else groups.push(intPart);
            var sign = neg ? '-' : (o.signDisplay === 'always' || (o.signDisplay === 'exceptZero' && abs2 !== 0) ? '+' : '');
            var cur = style === 'currency' && currency ? (o.currencyDisplay === 'code' ? currency : o.currencyDisplay === 'name' ? currency : (CURRENCY[currency] ? CURRENCY[currency][0] : currency)) : null;
            var curAfter = cur ? (lg === 'en' ? 0 : (CURRENCY[currency] && o.currencyDisplay !== 'code' ? CURRENCY[currency][1] : 1)) : 0;
            if (sign) parts.push({ type: sign === '-' ? 'minusSign' : 'plusSign', value: sign });
            if (cur && !curAfter) parts.push({ type: 'currency', value: cur }, { type: 'literal', value: lg === 'en' ? '' : NB });
            for (var g = 0; g < groups.length; g++) { if (g) parts.push({ type: 'group', value: sep[0] }); parts.push({ type: 'integer', value: groups[g] }); }
            if (frac) parts.push({ type: 'decimal', value: sep[1] }, { type: 'fraction', value: frac });
            if (unitSuffix) parts.push({ type: 'compact', value: unitSuffix });
            if (style === 'percent') parts.push({ type: 'literal', value: lg === 'en' ? '' : NB }, { type: 'percentSign', value: '%' });
            if (style === 'unit' && o.unit) parts.push({ type: 'literal', value: ' ' }, { type: 'unit', value: UNIT_SHORT[o.unit] || o.unit });
            if (cur && curAfter) parts.push({ type: 'literal', value: NB }, { type: 'currency', value: cur });
            var out = [];
            for (var i = 0; i < parts.length; i++) if (parts[i].value !== '') out.push(parts[i]);
            return out;
        };
        var UNIT_SHORT = { kilometer: 'km', meter: 'm', centimeter: 'cm', millimeter: 'mm', kilogram: 'kg', gram: 'g', liter: 'l', milliliter: 'ml', celsius: '°C', fahrenheit: '°F', percent: '%', second: 's', minute: 'min', hour: 'h', day: 'd', byte: 'B', kilobyte: 'kB', megabyte: 'MB', gigabyte: 'GB', 'kilometer-per-hour': 'km/h', 'mile-per-hour': 'mph', mile: 'mi', foot: 'ft', inch: 'in' };
        NumberFormat.prototype.format = function (n) { var p = this.formatToParts(n), s = ''; for (var i = 0; i < p.length; i++) s += p[i].value; return s; };
        NumberFormat.prototype.formatRange = function (a, b) { return this.format(a) + ' – ' + this.format(b); };
        NumberFormat.prototype.resolvedOptions = function () { var o = this.opts, r = { locale: this.locale, numberingSystem: 'latn', style: o.style || 'decimal', useGrouping: o.useGrouping === undefined ? 'auto' : o.useGrouping, notation: o.notation || 'standard', signDisplay: o.signDisplay || 'auto', minimumIntegerDigits: o.minimumIntegerDigits || 1, minimumFractionDigits: o.minimumFractionDigits === undefined ? 0 : o.minimumFractionDigits, maximumFractionDigits: o.maximumFractionDigits === undefined ? 3 : o.maximumFractionDigits }; if (o.currency) { r.currency = String(o.currency).toUpperCase(); r.currencyDisplay = o.currencyDisplay || 'symbol'; } if (o.unit) r.unit = o.unit; return r; };
        NumberFormat.supportedLocalesOf = supportedOf;
        Intl.NumberFormat = NumberFormat;
        // ---- dates
        var L = {
            cs: { months: ['ledna', 'února', 'března', 'dubna', 'května', 'června', 'července', 'srpna', 'září', 'října', 'listopadu', 'prosince'], monthsStandalone: ['leden', 'únor', 'březen', 'duben', 'květen', 'červen', 'červenec', 'srpen', 'září', 'říjen', 'listopad', 'prosinec'], monthsShort: ['led', 'úno', 'bře', 'dub', 'kvě', 'čvn', 'čvc', 'srp', 'zář', 'říj', 'lis', 'pro'], days: ['neděle', 'pondělí', 'úterý', 'středa', 'čtvrtek', 'pátek', 'sobota'], daysShort: ['ne', 'po', 'út', 'st', 'čt', 'pá', 'so'], numeric: 'd. m. y', dayMonth: 'd. m.', long: 'd. MMMM y', medium: 'd. M. y', h24: true, dayFirst: true, dateTimeSep: ' ', dayPeriods: ['dop.', 'odp.'] },
            sk: { months: ['januára', 'februára', 'marca', 'apríla', 'mája', 'júna', 'júla', 'augusta', 'septembra', 'októbra', 'novembra', 'decembra'], monthsStandalone: ['január', 'február', 'marec', 'apríl', 'máj', 'jún', 'júl', 'august', 'september', 'október', 'november', 'december'], monthsShort: ['jan', 'feb', 'mar', 'apr', 'máj', 'jún', 'júl', 'aug', 'sep', 'okt', 'nov', 'dec'], days: ['nedeľa', 'pondelok', 'utorok', 'streda', 'štvrtok', 'piatok', 'sobota'], daysShort: ['ne', 'po', 'ut', 'st', 'št', 'pi', 'so'], numeric: 'd. m. y', dayMonth: 'd. m.', long: 'd. MMMM y', medium: 'd. M. y', h24: true, dayFirst: true, dateTimeSep: ' ', dayPeriods: ['AM', 'PM'] },
            de: { months: ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'], monthsShort: ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sept.', 'Okt.', 'Nov.', 'Dez.'], days: ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag'], daysShort: ['So.', 'Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.'], numeric: 'd.m.y', dayMonth: 'd.m.', long: 'd. MMMM y', medium: 'dd.mm.y', h24: true, dayFirst: true, dateTimeSep: ', ', dayPeriods: ['AM', 'PM'] },
            pl: { months: ['stycznia', 'lutego', 'marca', 'kwietnia', 'maja', 'czerwca', 'lipca', 'sierpnia', 'września', 'października', 'listopada', 'grudnia'], monthsStandalone: ['styczeń', 'luty', 'marzec', 'kwiecień', 'maj', 'czerwiec', 'lipiec', 'sierpień', 'wrzesień', 'październik', 'listopad', 'grudzień'], monthsShort: ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'], days: ['niedziela', 'poniedziałek', 'wtorek', 'środa', 'czwartek', 'piątek', 'sobota'], daysShort: ['niedz.', 'pon.', 'wt.', 'śr.', 'czw.', 'pt.', 'sob.'], numeric: 'dd.mm.y', dayMonth: 'dd.mm', long: 'd MMMM y', medium: 'd MMM y', h24: true, dayFirst: true, dateTimeSep: ', ', dayPeriods: ['AM', 'PM'] },
            en: { months: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'], monthsShort: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'], days: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'], daysShort: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], numeric: 'm/d/y', dayMonth: 'm/d', long: 'MMMM d, y', medium: 'MMM d, y', h24: false, dayFirst: false, dateTimeSep: ', ', dayPeriods: ['AM', 'PM'] }
        };
        var localeData = function (loc) {
            var lg = lang(loc), d = L[lg] || L.en, region = canon(loc).split('-')[1];
            if (lg === 'en' && region && region !== 'US') return { months: d.months, monthsShort: d.monthsShort, days: d.days, daysShort: d.daysShort, numeric: 'dd/mm/y', dayMonth: 'dd/mm', long: 'd MMMM y', medium: 'd MMM y', h24: true, dayFirst: true, dateTimeSep: ', ', dayPeriods: d.dayPeriods };
            return d;
        };
        var DateTimeFormat = function DateTimeFormat(locale, opts) {
            if (!(this instanceof DateTimeFormat)) return new DateTimeFormat(locale, opts);
            this.locale = canon(locale); this.opts = opts || {}; this.data = localeData(this.locale);
        };
        var fields = function (d, utc) {
            return utc ? { y: d.getUTCFullYear(), mo: d.getUTCMonth(), d: d.getUTCDate(), wd: d.getUTCDay(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds(), ms: d.getUTCMilliseconds() }
                       : { y: d.getFullYear(), mo: d.getMonth(), d: d.getDate(), wd: d.getDay(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds(), ms: d.getMilliseconds() };
        };
        DateTimeFormat.prototype.formatToParts = function (date) {
            var d = date instanceof Date ? date : new Date(date === undefined ? Date.now() : date);
            if (isNaN(d.getTime())) throw new RangeError('Invalid time value');
            var o = this.opts, data = this.data, utc = /^(utc|gmt|etc\/utc)$/i.test(o.timeZone || ''), f = fields(d, utc), parts = [];
            var lit = function (v) { parts.push({ type: 'literal', value: v }); };
            var wantDate = o.dateStyle || o.year || o.month || o.day || o.weekday || o.era;
            var wantTime = o.timeStyle || o.hour || o.minute || o.second || o.dayPeriod || o.fractionalSecondDigits;
            var yearS = o.year === '2-digit' ? String(f.y).slice(-2) : String(f.y);
            var dayS = o.day === '2-digit' ? pad2(f.d) : String(f.d);
            var monthStyle = o.month || (o.dateStyle === 'full' || o.dateStyle === 'long' ? 'long' : o.dateStyle === 'medium' ? (/^(cs|sk|de)$/.test(lang(this.locale)) ? 'numeric' : 'short') : 'numeric');
            if (!wantDate && !wantTime) { wantDate = true; monthStyle = 'numeric'; o = { year: 'numeric', month: 'numeric', day: 'numeric' }; }
            if (wantDate) {
                var weekday = o.weekday || (o.dateStyle === 'full' ? 'long' : null);
                if (weekday) { parts.push({ type: 'weekday', value: weekday === 'long' ? data.days[f.wd] : data.daysShort[f.wd] }); if (o.month || o.dateStyle || o.day) lit(data.dayFirst ? ' ' : ', '); }
                var hasY = o.year || o.dateStyle, hasM = o.month || o.dateStyle, hasD = o.day || o.dateStyle;
                if (monthStyle === 'long' || monthStyle === 'short' || monthStyle === 'narrow') {
                    var mName = monthStyle === 'long' ? ((hasD || !data.monthsStandalone) ? data.months[f.mo] : data.monthsStandalone[f.mo]) : data.monthsShort[f.mo];
                    if (data.dayFirst) {
                        if (hasD) { parts.push({ type: 'day', value: dayS }); lit(/^(cs|sk|de|hu|fi|da|nb)$/.test(lang(this.locale)) ? '. ' : ' '); }
                        parts.push({ type: 'month', value: mName });
                        if (hasY) { lit(' '); parts.push({ type: 'year', value: yearS }); }
                    } else {
                        parts.push({ type: 'month', value: mName });
                        if (hasD) { lit(' '); parts.push({ type: 'day', value: dayS }); }
                        if (hasY) { lit(', '); parts.push({ type: 'year', value: yearS }); }
                    }
                } else if (hasM || hasD || hasY) {
                    var monS = o.month === '2-digit' || /mm/.test(data.numeric) ? pad2(f.mo + 1) : String(f.mo + 1);
                    if (/dd/.test(data.numeric)) dayS = pad2(f.d);
                    var sepD = data.numeric.indexOf('/') >= 0 ? '/' : data.numeric.indexOf(' ') >= 0 ? '. ' : '.';
                    var seq = [];
                    if (data.dayFirst) { if (hasD) seq.push(['day', dayS]); if (hasM) seq.push(['month', monS]); if (hasY) seq.push(['year', yearS]); }
                    else { if (hasM) seq.push(['month', monS]); if (hasD) seq.push(['day', dayS]); if (hasY) seq.push(['year', yearS]); }
                    for (var i = 0; i < seq.length; i++) {
                        parts.push({ type: seq[i][0], value: seq[i][1] });
                        if (i < seq.length - 1) lit(sepD);
                        else if (sepD !== '/' && seq[i][0] !== 'year' && data.dayFirst) lit(sepD.charAt(0));
                    }
                }
                if (wantTime) lit(data.dateTimeSep);   // ("Sep 28, 2026, 2:05 PM", "28. 9. 2026 14:05")
            }
            if (wantTime) {
                var h12 = o.hour12 !== undefined ? o.hour12 : (o.hourCycle ? o.hourCycle === 'h12' || o.hourCycle === 'h11' : !data.h24);
                var hour = f.h, period = null;
                if (h12) { period = hour < 12 ? data.dayPeriods[0] : data.dayPeriods[1]; hour = hour % 12; if (hour === 0) hour = 12; }
                var showH = o.hour || o.timeStyle, showM = o.minute || o.timeStyle, showS = o.second || (o.timeStyle && o.timeStyle !== 'short');
                if (showH) parts.push({ type: 'hour', value: o.hour === '2-digit' || (!h12 && o.hour !== 'numeric') ? pad2(hour) : String(hour) });
                if (showM) { if (showH) lit(':'); parts.push({ type: 'minute', value: pad2(f.mi) }); }
                if (showS) { lit(':'); parts.push({ type: 'second', value: pad2(f.s) }); }
                if (o.fractionalSecondDigits) { lit('.'); parts.push({ type: 'fractionalSecond', value: String(f.ms + 1000).slice(1, 1 + o.fractionalSecondDigits) }); }
                if (period && showH) { lit(' '); parts.push({ type: 'dayPeriod', value: period }); }
                if (o.timeZoneName) { lit(' '); parts.push({ type: 'timeZoneName', value: utc ? 'UTC' : 'GMT' + (d.getTimezoneOffset() ? (d.getTimezoneOffset() > 0 ? '-' : '+') + Math.abs(d.getTimezoneOffset() / 60) : '') }); }
            }
            return parts;
        };
        DateTimeFormat.prototype.format = function (d) { var p = this.formatToParts(d), s = ''; for (var i = 0; i < p.length; i++) s += p[i].value; return s; };
        DateTimeFormat.prototype.formatRange = function (a, b) { return this.format(a) + ' – ' + this.format(b); };
        DateTimeFormat.prototype.formatRangeToParts = function (a, b) { return this.formatToParts(a).concat([{ type: 'literal', value: ' – ' }], this.formatToParts(b)); };
        DateTimeFormat.prototype.resolvedOptions = function () { var o = this.opts, r = { locale: this.locale, calendar: 'gregory', numberingSystem: 'latn', timeZone: o.timeZone || 'Europe/Prague' }; var keys = ['weekday', 'era', 'year', 'month', 'day', 'hour', 'minute', 'second', 'timeZoneName', 'hour12', 'dateStyle', 'timeStyle']; for (var i = 0; i < keys.length; i++) if (o[keys[i]] !== undefined) r[keys[i]] = o[keys[i]]; return r; };
        DateTimeFormat.supportedLocalesOf = supportedOf;
        Intl.DateTimeFormat = DateTimeFormat;
        // ---- plural rules (CLDR): cs/sk one, few (2-4), many (fractions), other; pl one, few, many, other; ru/uk; en/de/... one, other
        var pluralFor = function (lg, n, ordinal) {
            var i = Math.floor(Math.abs(n)), isInt = n === i;
            if (ordinal) {
                if (lg === 'en') { var m10 = i % 10, m100 = i % 100; return m10 === 1 && m100 !== 11 ? 'one' : m10 === 2 && m100 !== 12 ? 'two' : m10 === 3 && m100 !== 13 ? 'few' : 'other'; }
                return 'other';
            }
            switch (lg) {
                case 'cs': case 'sk': return !isInt ? 'many' : i === 1 ? 'one' : i >= 2 && i <= 4 ? 'few' : 'other';
                case 'pl': { var p10 = i % 10, p100 = i % 100; return !isInt ? 'other' : i === 1 ? 'one' : p10 >= 2 && p10 <= 4 && (p100 < 12 || p100 > 14) ? 'few' : 'many'; }
                case 'ru': case 'uk': { var r10 = i % 10, r100 = i % 100; return !isInt ? 'other' : r10 === 1 && r100 !== 11 ? 'one' : r10 >= 2 && r10 <= 4 && (r100 < 12 || r100 > 14) ? 'few' : 'many'; }
                case 'fr': case 'pt': return i === 0 || i === 1 ? 'one' : 'other';
                case 'ja': case 'zh': case 'ko': case 'vi': case 'th': case 'tr': case 'hu': return 'other';
                default: return isInt && i === 1 ? 'one' : 'other';
            }
        };
        var PluralRules = function PluralRules(locale, opts) { this.locale = canon(locale); this.type = opts && opts.type === 'ordinal' ? 'ordinal' : 'cardinal'; };
        PluralRules.prototype.select = function (n) { return pluralFor(lang(this.locale), Number(n), this.type === 'ordinal'); };
        PluralRules.prototype.selectRange = function (a, b) { return this.select(b); };
        PluralRules.prototype.resolvedOptions = function () { var lg = lang(this.locale); return { locale: this.locale, type: this.type, pluralCategories: lg === 'cs' || lg === 'sk' ? ['one', 'few', 'many', 'other'] : lg === 'pl' || lg === 'ru' || lg === 'uk' ? ['one', 'few', 'many', 'other'] : ['one', 'other'] }; };
        PluralRules.supportedLocalesOf = supportedOf;
        Intl.PluralRules = PluralRules;
        // ---- relative time
        var RT = {
            cs: { units: { second: ['sekundu', 'sekundy', 'sekund'], minute: ['minutu', 'minuty', 'minut'], hour: ['hodinu', 'hodiny', 'hodin'], day: ['den', 'dny', 'dní'], week: ['týden', 'týdny', 'týdnů'], month: ['měsíc', 'měsíce', 'měsíců'], quarter: ['čtvrtletí', 'čtvrtletí', 'čtvrtletí'], year: ['rok', 'roky', 'let'] }, past: 'před {0}', future: 'za {0}', pastUnits: { second: ['sekundou', 'sekundami', 'sekundami'], minute: ['minutou', 'minutami', 'minutami'], hour: ['hodinou', 'hodinami', 'hodinami'], day: ['dnem', 'dny', 'dny'], week: ['týdnem', 'týdny', 'týdny'], month: ['měsícem', 'měsíci', 'měsíci'], quarter: ['čtvrtletím', 'čtvrtletími', 'čtvrtletími'], year: ['rokem', 'lety', 'lety'] }, auto: { day: { '-1': 'včera', '0': 'dnes', '1': 'zítra', '-2': 'předevčírem', '2': 'pozítří' }, week: { '-1': 'minulý týden', '0': 'tento týden', '1': 'příští týden' }, month: { '-1': 'minulý měsíc', '0': 'tento měsíc', '1': 'příští měsíc' }, year: { '-1': 'loni', '0': 'letos', '1': 'příští rok' }, second: { '0': 'nyní' } } },
            en: { units: { second: ['second', 'seconds'], minute: ['minute', 'minutes'], hour: ['hour', 'hours'], day: ['day', 'days'], week: ['week', 'weeks'], month: ['month', 'months'], quarter: ['quarter', 'quarters'], year: ['year', 'years'] }, past: '{0} ago', future: 'in {0}', auto: { day: { '-1': 'yesterday', '0': 'today', '1': 'tomorrow' }, week: { '-1': 'last week', '0': 'this week', '1': 'next week' }, month: { '-1': 'last month', '0': 'this month', '1': 'next month' }, year: { '-1': 'last year', '0': 'this year', '1': 'next year' }, second: { '0': 'now' } } },
            de: { units: { second: ['Sekunde', 'Sekunden'], minute: ['Minute', 'Minuten'], hour: ['Stunde', 'Stunden'], day: ['Tag', 'Tagen'], week: ['Woche', 'Wochen'], month: ['Monat', 'Monaten'], quarter: ['Quartal', 'Quartalen'], year: ['Jahr', 'Jahren'] }, past: 'vor {0}', future: 'in {0}', auto: { day: { '-1': 'gestern', '0': 'heute', '1': 'morgen' }, week: { '-1': 'letzte Woche', '0': 'diese Woche', '1': 'nächste Woche' }, month: { '-1': 'letzten Monat', '0': 'diesen Monat', '1': 'nächsten Monat' }, year: { '-1': 'letztes Jahr', '0': 'dieses Jahr', '1': 'nächstes Jahr' }, second: { '0': 'jetzt' } } }
        };
        RT.sk = RT.cs;
        var RelativeTimeFormat = function RelativeTimeFormat(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; };
        RelativeTimeFormat.prototype.format = function (value, unit) {
            var lg = lang(this.locale), t = RT[lg] || RT.en, u = String(unit).replace(/s$/, ''), v = Number(value);
            if (!t.units[u]) throw new RangeError('Invalid unit argument for format(): ' + unit);
            if (this.opts.numeric === 'auto' && t.auto[u] && t.auto[u][String(v)]) return t.auto[u][String(v)];
            var n = Math.abs(v), form = pluralFor(lg, n), names = (v < 0 && t.pastUnits ? t.pastUnits : t.units)[u];
            var word = names.length === 3 ? (form === 'one' ? names[0] : form === 'few' ? names[1] : names[2]) : (form === 'one' ? names[0] : names[1]);
            var num = new NumberFormat(this.locale).format(n);
            return (v < 0 || (v === 0 && 1 / v < 0) ? t.past : t.future).replace('{0}', num + ' ' + word);
        };
        RelativeTimeFormat.prototype.formatToParts = function (value, unit) { return [{ type: 'literal', value: this.format(value, unit) }]; };
        RelativeTimeFormat.prototype.resolvedOptions = function () { return { locale: this.locale, style: this.opts.style || 'long', numeric: this.opts.numeric || 'always', numberingSystem: 'latn' }; };
        RelativeTimeFormat.supportedLocalesOf = supportedOf;
        Intl.RelativeTimeFormat = RelativeTimeFormat;
        // ---- lists, collation, display names, locales, segmenter
        var LIST = { cs: [' a ', ' nebo '], sk: [' a ', ' alebo '], de: [' und ', ' oder '], pl: [' i ', ' lub '], fr: [' et ', ' ou '], es: [' y ', ' o '], en: [' and ', ' or '] };
        var ListFormat = function ListFormat(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; };
        ListFormat.prototype.format = function (list) {
            var a = [], i; for (i = 0; i < list.length; i++) a.push(String(list[i]));
            var lg = lang(this.locale), w = LIST[lg] || LIST.en, word = this.opts.type === 'disjunction' ? w[1] : this.opts.type === 'unit' ? (this.opts.style === 'narrow' ? ' ' : ', ') : w[0];
            if (a.length <= 1) return a.join('');
            if (a.length === 2) return a[0] + word + a[1];
            return a.slice(0, -1).join(', ') + (lg === 'en' && this.opts.type !== 'unit' ? ',' : '') + word + a[a.length - 1];
        };
        ListFormat.prototype.formatToParts = function (list) { return [{ type: 'literal', value: this.format(list) }]; };
        ListFormat.prototype.resolvedOptions = function () { return { locale: this.locale, type: this.opts.type || 'conjunction', style: this.opts.style || 'long' }; };
        ListFormat.supportedLocalesOf = supportedOf;
        Intl.ListFormat = ListFormat;
        var Collator = function Collator(locale, opts) {
            if (!(this instanceof Collator)) return new Collator(locale, opts);
            this.locale = canon(locale); this.opts = opts || {}; var self = this; this.compare = function (a, b) { return self.compareStrings(a, b); };
        };
        Collator.prototype.compareStrings = function (a, b) {
            a = String(a); b = String(b);
            var o = this.opts;
            if (o.sensitivity === 'base' || o.sensitivity === 'accent') { a = a.toLowerCase(); b = b.toLowerCase(); }
            if (o.ignorePunctuation) { a = a.replace(/[\s\-_.,;:!?'"()]/g, ''); b = b.replace(/[\s\-_.,;:!?'"()]/g, ''); }
            if (o.numeric) {
                var ra = a.match(/(\d+|\D+)/g) || [], rb = b.match(/(\d+|\D+)/g) || [];
                for (var i = 0; i < Math.min(ra.length, rb.length); i++) {
                    var da = /^\d/.test(ra[i]), db = /^\d/.test(rb[i]);
                    var c = da && db ? (parseInt(ra[i], 10) - parseInt(rb[i], 10)) : ra[i].localeCompare(rb[i]);
                    if (c) return c < 0 ? -1 : 1;
                }
                return ra.length - rb.length;
            }
            var r = a.localeCompare(b);
            return r < 0 ? -1 : r > 0 ? 1 : 0;
        };
        Collator.prototype.resolvedOptions = function () { return { locale: this.locale, usage: this.opts.usage || 'sort', sensitivity: this.opts.sensitivity || 'variant', ignorePunctuation: !!this.opts.ignorePunctuation, collation: 'default', numeric: !!this.opts.numeric, caseFirst: this.opts.caseFirst || 'false' }; };
        Collator.supportedLocalesOf = supportedOf;
        Intl.Collator = Collator;
        var NAMES = { language: { cs: { cs: 'čeština', sk: 'slovenština', en: 'angličtina', de: 'němčina', pl: 'polština', fr: 'francouzština', es: 'španělština', it: 'italština', ru: 'ruština' }, en: { cs: 'Czech', sk: 'Slovak', en: 'English', de: 'German', pl: 'Polish', fr: 'French', es: 'Spanish', it: 'Italian', ru: 'Russian' } },
                      region: { cs: { CZ: 'Česko', SK: 'Slovensko', US: 'Spojené státy', GB: 'Spojené království', DE: 'Německo', PL: 'Polsko', AT: 'Rakousko', FR: 'Francie' }, en: { CZ: 'Czechia', SK: 'Slovakia', US: 'United States', GB: 'United Kingdom', DE: 'Germany', PL: 'Poland', AT: 'Austria', FR: 'France' } },
                      currency: { cs: { CZK: 'česká koruna', EUR: 'euro', USD: 'americký dolar', GBP: 'britská libra' }, en: { CZK: 'Czech Koruna', EUR: 'Euro', USD: 'US Dollar', GBP: 'British Pound' } } };
        var DisplayNames = function DisplayNames(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; };
        DisplayNames.prototype.of = function (code) { var lg = lang(this.locale), table = NAMES[this.opts.type] || {}, t = table[lg] || table.en || {}; var key = this.opts.type === 'language' ? String(code).split('-')[0].toLowerCase() : String(code).toUpperCase(); return t[key] || (this.opts.fallback === 'none' ? undefined : String(code)); };
        DisplayNames.prototype.resolvedOptions = function () { return { locale: this.locale, style: this.opts.style || 'long', type: this.opts.type, fallback: this.opts.fallback || 'code' }; };
        DisplayNames.supportedLocalesOf = supportedOf;
        Intl.DisplayNames = DisplayNames;
        var Locale = function Locale(tag, opts) {
            var parts = canon(tag).split('-');
            this.language = (opts && opts.language) || parts[0].toLowerCase();
            this.script = (opts && opts.script) || (parts[1] && parts[1].length === 4 ? parts[1] : undefined);
            this.region = (opts && opts.region) || (parts[1] && parts[1].length === 2 ? parts[1].toUpperCase() : parts[2] && parts[2].length === 2 ? parts[2].toUpperCase() : undefined);
            this.baseName = this.language + (this.script ? '-' + this.script : '') + (this.region ? '-' + this.region : '');
            this.calendar = opts && opts.calendar; this.numberingSystem = opts && opts.numberingSystem; this.hourCycle = opts && opts.hourCycle;
        };
        Locale.prototype.toString = function () { return this.baseName; };
        Locale.prototype.maximize = function () { return this; };
        Locale.prototype.minimize = function () { return new Locale(this.language); };
        Intl.Locale = Locale;
        var Segmenter = function Segmenter(locale, opts) { this.locale = canon(locale); this.granularity = opts && opts.granularity || 'grapheme'; };
        Segmenter.prototype.segment = function (str) {
            str = String(str);
            var re = this.granularity === 'word' ? /[\wÀ-ɏЀ-ӿ]+|[^\wÀ-ɏЀ-ӿ]/g : this.granularity === 'sentence' ? /[^.!?]+[.!?]*\s*/g : /[\uD800-\uDBFF][\uDC00-\uDFFF]|[\s\S]/g;
            var out = [], m, wordLike = this.granularity === 'word';
            while ((m = re.exec(str)) !== null) out.push({ segment: m[0], index: m.index, input: str, isWordLike: wordLike ? /[\wÀ-ɏЀ-ӿ]/.test(m[0]) : undefined });
            out.containing = function (i) { for (var k = 0; k < out.length; k++) if (i >= out[k].index && i < out[k].index + out[k].segment.length) return out[k]; return undefined; };
            return out;
        };
        Segmenter.prototype.resolvedOptions = function () { return { locale: this.locale, granularity: this.granularity }; };
        Segmenter.supportedLocalesOf = supportedOf;
        Intl.Segmenter = Segmenter;
        var DurationFormat = function DurationFormat(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; };
        DurationFormat.prototype.format = function (d) { var keys = ['years', 'months', 'weeks', 'days', 'hours', 'minutes', 'seconds'], out = [], lg = lang(this.locale); var rtf = new RelativeTimeFormat(this.locale); for (var i = 0; i < keys.length; i++) if (d && d[keys[i]]) { var s = rtf.format(d[keys[i]], keys[i]); out.push(s.replace(lg === 'en' ? /^in /: /^za /, '')); } return out.join(lg === 'en' ? ', ' : ' '); };
        DurationFormat.prototype.formatToParts = function (d) { return [{ type: 'literal', value: this.format(d) }]; };
        DurationFormat.supportedLocalesOf = supportedOf;
        Intl.DurationFormat = DurationFormat;
        Intl.getCanonicalLocales = function (l) { return supportedOf(l).map(canon); };
        Intl.supportedValuesOf = function (key) { switch (key) { case 'currency': { var c = []; for (var k in CURRENCY) if (CURRENCY.hasOwnProperty(k)) c.push(k); return c.sort(); } case 'calendar': return ['gregory']; case 'numberingSystem': return ['latn']; case 'timeZone': return ['Europe/Prague', 'UTC']; case 'unit': { var u = []; for (var uk in UNIT_SHORT) if (UNIT_SHORT.hasOwnProperty(uk)) u.push(uk); return u.sort(); } case 'collation': return ['default']; } return []; };
        // the locale-aware methods of Number and Date go through the implementation above when arguments are given
        var origNumToLocale = Number.prototype.toLocaleString;
        Number.prototype.toLocaleString = function (locales, opts) { if (locales === undefined && opts === undefined) return origNumToLocale.call(this); try { return new NumberFormat(locales, opts).format(Number(this)); } catch (e) { return origNumToLocale.call(this); } };
        // ECMA-402 ToDateTimeOptions: the date / time defaults apply only when the caller named no field of that group
        var DATE_DEFAULTS = { year: 'numeric', month: 'numeric', day: 'numeric' }, TIME_DEFAULTS = { hour: 'numeric', minute: '2-digit', second: '2-digit' };
        var dateMethod = function (name, wantDate, wantTime) {
            var orig = Date.prototype[name];
            Date.prototype[name] = function (locales, opts) {
                if (locales === undefined && opts === undefined) return orig.call(this);
                var o = {}, k;
                if (opts) for (k in opts) if (opts.hasOwnProperty(k)) o[k] = opts[k];
                var hasDate = !!(o.weekday || o.year || o.month || o.day || o.dateStyle || o.era), hasTime = !!(o.hour || o.minute || o.second || o.timeStyle || o.dayPeriod || o.fractionalSecondDigits);
                if (!hasDate && !hasTime) {
                    if (wantDate) for (k in DATE_DEFAULTS) if (DATE_DEFAULTS.hasOwnProperty(k)) o[k] = DATE_DEFAULTS[k];
                    if (wantTime) for (k in TIME_DEFAULTS) if (TIME_DEFAULTS.hasOwnProperty(k)) o[k] = TIME_DEFAULTS[k];
                } else if (name === 'toLocaleDateString' && !hasDate) { for (k in DATE_DEFAULTS) if (DATE_DEFAULTS.hasOwnProperty(k)) o[k] = DATE_DEFAULTS[k]; }
                else if (name === 'toLocaleTimeString' && !hasTime) { for (k in TIME_DEFAULTS) if (TIME_DEFAULTS.hasOwnProperty(k)) o[k] = TIME_DEFAULTS[k]; }
                try { return new DateTimeFormat(locales, o).format(this); } catch (e) { return orig.call(this); }
            };
        };
        dateMethod('toLocaleDateString', true, false);
        dateMethod('toLocaleTimeString', false, true);
        dateMethod('toLocaleString', true, true);
    })();

    // IndexedDB is missing on iOS 6: expose a stub that fails cleanly (many libraries feature-detect it)
    if (!window.indexedDB) {
        window.indexedDB = null;
    }

    // customElements: registry stub so definitions do not throw (rendering of custom elements is not emulated)
    if (!window.customElements) {
        var registry = {};
        window.customElements = {
            __brStub: true,   // replaced by the upgrading registry in shims-extra.js
            define: function (name, ctor) { registry[name] = ctor; },
            get: function (name) { return registry[name]; },
            whenDefined: function () { return window.Promise ? window.Promise.resolve() : null; },
            upgrade: function () {}
        };
    }
    if (!window.HTMLTemplateElement) {
        window.HTMLTemplateElement = function () {};
    }
    if (window.HTMLUnknownElement && !('content' in document.createElement('template'))) {
        // <template> polyfill: expose .content as a document fragment of the children and hide the element
        var style = document.createElement('style');
        style.__brOwn = true;
        // (data-precedence: React 19 skips such styles in <head> when it hydrates; it took this one for the page's
        // first <style> and threw the page away over its text - vercel.com)
        style.setAttribute('data-precedence', 'br');
        style.textContent = 'template{display:none!important}';
        (document.head || document.documentElement).appendChild(style);
        var proto = Object.getPrototypeOf(document.createElement('template'));
        try {
            Object.defineProperty(proto, 'content', { get: function () {
                if (!this.__content) {
                    var frag = document.createDocumentFragment();
                    while (this.firstChild) frag.appendChild(this.firstChild);
                    this.__content = frag;
                }
                return this.__content;
            } });
        } catch (e5) {}
    }

    // structuredClone: the structured clone algorithm for data (shared and cyclic references, Date, RegExp, Map, Set,
    // boxed primitives, ArrayBuffer and views, Error; Blob/File/ImageData shared; undefined kept, class instances
    // become plain objects); functions, symbols and DOM nodes throw DataCloneError. (A JSON round trip turned dates
    // into strings and Maps into {}.)
    if (!window.structuredClone) (function () {
        var hasOwn = Object.prototype.hasOwnProperty, toStr = Object.prototype.toString;
        var VIEWS = { Int8Array: 1, Uint8Array: 1, Uint8ClampedArray: 1, Int16Array: 1, Uint16Array: 1, Int32Array: 1, Uint32Array: 1, Float32Array: 1, Float64Array: 1, BigInt64Array: 1, BigUint64Array: 1 };
        var SHARED = { Blob: 1, File: 1, FileList: 1, ImageData: 1, ImageBitmap: 1, CryptoKey: 1 };
        var cloneError = function (what) {
            var e;
            try { e = new window.DOMException(what + ' could not be cloned.', 'DataCloneError'); } catch (x) { e = null; }
            if (!e || e.name !== 'DataCloneError') { e = new Error(what + ' could not be cloned.'); e.name = 'DataCloneError'; e.code = 25; }
            return e;
        };
        var tagOf = function (v) {
            if (typeof window.Map === 'function' && v instanceof window.Map) return 'Map';
            if (typeof window.Set === 'function' && v instanceof window.Set) return 'Set';
            return toStr.call(v).slice(8, -1);
        };
        window.structuredClone = function structuredClone(value) {
            if (arguments.length === 0) throw new TypeError("Failed to execute 'structuredClone' on 'Window': 1 argument required, but only 0 present.");
            var memo = typeof window.Map === 'function' ? new window.Map() : null, keys = [], vals = [];
            var remember = function (o, c) { if (memo) memo.set(o, c); else { keys.push(o); vals.push(c); } return c; };
            var clone = function (v) {
                var t = typeof v;
                if (v === null || (t !== 'object' && t !== 'function')) {
                    if (t === 'symbol') throw cloneError('Symbol()');
                    return v;
                }
                if (t === 'function') throw cloneError(String(v).slice(0, 80));
                var known = memo ? memo.get(v) : (function () { for (var i = 0; i < keys.length; i++) if (keys[i] === v) return vals[i]; })();
                if (known !== undefined) return known;
                var tag = tagOf(v), c, i;
                if (tag === 'Symbol') throw cloneError('Symbol()');   // (a polyfilled one is an object)
                if (SHARED[tag]) return v;
                if (VIEWS[tag]) return remember(v, new v.constructor(clone(v.buffer), v.byteOffset, v.length));
                switch (tag) {
                    case 'Date': return remember(v, new Date(v.getTime()));
                    case 'RegExp':
                        return remember(v, new RegExp(v.source, typeof v.flags === 'string' ? v.flags : (v.global ? 'g' : '') + (v.ignoreCase ? 'i' : '') + (v.multiline ? 'm' : '')));
                    case 'Boolean': case 'Number': case 'String': return remember(v, Object(v.valueOf()));
                    case 'ArrayBuffer': return remember(v, v.slice(0));
                    case 'DataView': return remember(v, new DataView(clone(v.buffer), v.byteOffset, v.byteLength));
                    case 'Map':
                        c = remember(v, new window.Map());
                        v.forEach(function (val, key) { c.set(clone(key), clone(val)); });
                        return c;
                    case 'Set':
                        c = remember(v, new window.Set());
                        v.forEach(function (val) { c.add(clone(val)); });
                        return c;
                    case 'Error': case 'EvalError': case 'RangeError': case 'ReferenceError': case 'SyntaxError': case 'TypeError': case 'URIError':
                        var E = window[v.name] && /Error$/.test(v.name) ? window[v.name] : Error;
                        c = remember(v, new E(v.message));
                        if (v.stack) try { c.stack = String(v.stack); } catch (es) {}
                        return c;
                    case 'Array':
                        c = remember(v, new Array(v.length));
                        for (i = 0; i < v.length; i++) if (i in v) c[i] = clone(v[i]);
                        return c;
                }
                if (v.nodeType || v === window || v.window === v || tag === 'Promise' || tag === 'WeakMap' || tag === 'WeakSet') throw cloneError(tag || 'The object');
                c = remember(v, {});
                for (var k in v) if (hasOwn.call(v, k)) c[k] = clone(v[k]);
                return c;
            };
            return clone(value);
        };
    })();
    // matchMedia with today's queries (the rewriter does the same for stylesheets, see fixMedia in cssfix.js): range
    // syntax, rem (refused by the old engine inside media queries: the whole query fails; there it means the initial
    // font size, like em), and hover / pointer / prefers-* features it does not know (a touch device with the defaults)
    if (window.matchMedia && !window.matchMedia.__brFix) (function () {
        var nativeMatchMedia = window.matchMedia;
        var strict = function (v, op, up) {
            var m = /^(-?[\d.]+)(px|em|rem)$/i.exec(v.replace(/^\s+|\s+$/g, ''));
            if (op.length > 1 || !m) return v;
            var n = parseFloat(m[1]) + (up ? 1 : -1) * (/px/i.test(m[2]) ? 0.02 : 0.001);
            return (Math.round(n * 1000) / 1000) + m[2];
        };
        var fixQuery = function (q) {
            return String(q)
                .replace(/\(\s*(-?[\d.]+(?:px|em|rem))\s*(<=|<)\s*(width|height)\s*(<=|<)\s*(-?[\d.]+(?:px|em|rem))\s*\)/gi, function (m, a, o1, f, o2, b) { return '(min-' + f + ': ' + strict(a, o1, true) + ') and (max-' + f + ': ' + strict(b, o2, false) + ')'; })
                .replace(/\(\s*(width|height)\s*(>=|>)\s*([^)]+?)\s*\)/gi, function (m, f, o, v) { return '(min-' + f + ': ' + strict(v, o, true) + ')'; })
                .replace(/\(\s*(width|height)\s*(<=|<)\s*([^)]+?)\s*\)/gi, function (m, f, o, v) { return '(max-' + f + ': ' + strict(v, o, false) + ')'; })
                .replace(/(\d*\.?\d+)rem\b/gi, '$1em')
                .replace(/\(\s*(?:any-)?hover\s*:\s*none\s*\)|\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)|\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)|\(\s*prefers-color-scheme\s*:\s*light\s*\)|\(\s*prefers-contrast\s*:\s*no-preference\s*\)|\(\s*forced-colors\s*:\s*none\s*\)|\(\s*display-mode\s*:\s*browser\s*\)|\(\s*scripting\s*:\s*enabled\s*\)|\(\s*dynamic-range\s*:\s*standard\s*\)/gi, '(min-width: 0px)')
                .replace(/\(\s*(?:any-)?hover(?:\s*:\s*hover)?\s*\)|\(\s*(?:any-)?pointer\s*:\s*(?:fine|none)\s*\)|\(\s*prefers-reduced-motion(?:\s*:\s*reduce)?\s*\)|\(\s*prefers-color-scheme\s*:\s*dark\s*\)|\(\s*prefers-contrast\s*:\s*[a-z]+\s*\)|\(\s*forced-colors\s*:\s*active\s*\)|\(\s*display-mode\s*:\s*[a-z-]+\s*\)|\(\s*dynamic-range\s*:\s*high\s*\)/gi, '(max-width: 0px)');
        };
        var wrapped = function matchMedia(query) { return nativeMatchMedia.call(window, fixQuery(query)); };
        wrapped.__brFix = true;
        wrapped.__brNative = nativeMatchMedia;
        try { window.matchMedia = wrapped; } catch (eMM) {}
    })();
    // Object.assign onto an element (a helper that makes a node from a tag and properties): what the old engine keeps
    // read-only goes through the attribute (a button's type; today that property sets it), and void elements ignore
    // innerText (today they take it, here it throws DOM Exception 7). Other failures stay failures.
    if (Object.assign && !Object.assign.__brDom) (function () {
        var nativeAssign = Object.assign, hasOwn = Object.prototype.hasOwnProperty;
        var put = function (el, k, v) {
            try { el[k] = v; } catch (e) {
                if (k === 'type' && /^button$/i.test(el.tagName)) el.setAttribute('type', v);
                else if (k !== 'innerText') throw e;
            }
        };
        // (keys assigned to the target of the transpiler's Proxy stand-in reach its proxies: Pinia builds a store as
        // reactive({...}) and then assigns its actions and state to toRaw(store), store.getCartProduct was undefined)
        var resync = function (target) {
            var px = target && target.__br_px;
            if (px) for (var i = 0; i < px.length; i++) { try { px[i].__br_resync(); } catch (e) {} }
        };
        Object.assign = function assign(target) {
            try { var out = nativeAssign.apply(Object, arguments); resync(target); return out; } catch (e) {
                if (target === null || typeof target !== 'object' || target.nodeType !== 1) throw e;
                for (var i = 1; i < arguments.length; i++) {
                    var s = arguments[i];
                    if (s === null || s === undefined) continue;
                    for (var k in s) if (hasOwn.call(s, k)) put(target, k, s[k]);
                }
                return target;
            }
        };
        Object.assign.__brDom = true;
    })();
    if (!window.reportError) window.reportError = function (e) { if (con.error) con.error(e); };
    if (!window.ResizeObserver) window.ResizeObserver = function () {}; // provided by the polyfill before this file normally
    if (!window.IdleDeadline) window.IdleDeadline = function () {};
    if (!window.Notification) { window.Notification = function () {}; window.Notification.permission = 'denied'; window.Notification.requestPermission = function () { return window.Promise ? window.Promise.resolve('denied') : null; }; }
    if (!window.BroadcastChannel) { window.BroadcastChannel = function (name) { this.name = name; }; window.BroadcastChannel.prototype.postMessage = function () {}; window.BroadcastChannel.prototype.close = function () {}; window.BroadcastChannel.prototype.addEventListener = function () {}; window.BroadcastChannel.prototype.removeEventListener = function () {}; }
    if (!window.Worker) { window.Worker = function () { throw new Error('Web Workers are not supported'); }; }
    if (!window.WebSocket && window.MozWebSocket) window.WebSocket = window.MozWebSocket;
    if (!window.visualViewport) window.visualViewport = { width: window.innerWidth, height: window.innerHeight, scale: 1, offsetLeft: 0, offsetTop: 0, pageLeft: 0, pageTop: 0, addEventListener: function () {}, removeEventListener: function () {} };
    if (!window.screen.orientation) try { window.screen.orientation = { type: window.innerWidth > window.innerHeight ? 'landscape-primary' : 'portrait-primary', angle: 0, addEventListener: function () {}, removeEventListener: function () {} }; } catch (e6) {}
    if (!('devicePixelRatio' in window)) window.devicePixelRatio = 1;
    if (!window.CSS) window.CSS = {};
    if (!window.CSS.supports) window.CSS.supports = function (p, v) { if (v === undefined) { var m = /^\(?\s*([a-z-]+)\s*:\s*(.*?)\s*\)?$/i.exec(p || ''); if (!m) return false; p = m[1]; v = m[2]; } var s = document.createElement('div').style; try { s.setProperty(p, v); return s.getPropertyValue(p) !== ''; } catch (e) { return false; } };
    if (!window.CSS.escape) window.CSS.escape = function (s) { return String(s).replace(/([^\w-])/g, '\\$1'); };
    if (!window.CSS.registerProperty) window.CSS.registerProperty = function () {};
    if (!window.CSSStyleSheet.prototype.replaceSync) { window.CSSStyleSheet.prototype.replaceSync = function () {}; window.CSSStyleSheet.prototype.replace = function () { return window.Promise ? window.Promise.resolve(this) : null; }; }
    try { if (!('adoptedStyleSheets' in document)) document.adoptedStyleSheets = []; } catch (e7) {}

    // ---- Interface objects as functions. Most of them are objects in the old engine (typeof Event === 'object'):
    // Babel's class helpers refuse them as superclasses ("Super expression must either be null or a function") and
    // feature tests that check typeof fail. Each becomes a function of the same name with the same prototype and
    // constants; `new` makes the native object (a subclass's instance gets the subclass's prototype). The event
    // constructors the old engine refuses (MouseEvent, KeyboardEvent, UIEvent, TouchEvent) and the node constructors
    // (Text, Comment, DocumentFragment, Range, File) are built from the document's factory methods.
    (function () {
        var gopn = Object.getOwnPropertyNames, getProto = Object.getPrototypeOf, SKIP = { prototype: 1, length: 1, name: 1, arguments: 1, caller: 1 };
        var construct = function (Native, a) {
            switch (a.length) {
                case 0: return new Native();
                case 1: return new Native(a[0]);
                case 2: return new Native(a[0], a[1]);
                case 3: return new Native(a[0], a[1], a[2]);
                default: return new Native(a[0], a[1], a[2], a[3]);
            }
        };
        var wrap = function (name, build) {
            var Native = window[name];
            if (!Native || typeof Native === 'function' || !Native.prototype) return;
            var W = null;
            var make = function (self, args) {
                var obj = build ? build(args) : construct(Native, args);
                // (a subclass constructing: its prototype on the native object)
                if (self && typeof self === 'object' && self !== window && W && self instanceof W && getProto(self) !== W.prototype && obj && typeof obj === 'object') {
                    try { obj.__proto__ = getProto(self); } catch (e) {}
                }
                return obj;
            };
            // (a function with the interface's name: code prints and compares constructor names)
            try { W = Function('make', 'return function ' + name + '() { return make(this, arguments); };')(make); } catch (e0) { W = function () { return make(this, arguments); }; }
            var keys = [];
            try { keys = gopn(Native); } catch (e1) { for (var k in Native) keys.push(k); }
            try { var pk = gopn(Native.prototype); for (var p = 0; p < pk.length; p++) if (/^[A-Z][A-Z0-9_]*$/.test(pk[p])) keys.push(pk[p]); } catch (e2) {}
            for (var i = 0; i < keys.length; i++) {
                if (SKIP[keys[i]] || W.hasOwnProperty(keys[i])) continue;
                try { W[keys[i]] = Native[keys[i]] !== undefined ? Native[keys[i]] : Native.prototype[keys[i]]; } catch (e3) {}
            }
            W.prototype = Native.prototype;
            try { Object.defineProperty(Native.prototype, 'constructor', { value: W, writable: true, configurable: true, enumerable: false }); } catch (e4) { try { Native.prototype.constructor = W; } catch (e5) {} }
            W.__brNative = Native;
            try { window[name] = W; } catch (e6) {}
        };
        var flag = function (init, key) { return !!(init && init[key]); };
        var num = function (init, key) { return init && typeof init[key] === 'number' ? init[key] : 0; };
        wrap('Event');
        wrap('UIEvent', function (a) { var init = a[1] || {}, e = document.createEvent('UIEvents'); e.initUIEvent(String(a[0]), flag(init, 'bubbles'), flag(init, 'cancelable'), init.view || window, num(init, 'detail')); return e; });
        wrap('MouseEvent', function (a) {
            var init = a[1] || {}, e = document.createEvent('MouseEvents');
            e.initMouseEvent(String(a[0]), flag(init, 'bubbles'), flag(init, 'cancelable'), init.view || window, num(init, 'detail'), num(init, 'screenX'), num(init, 'screenY'),
                             num(init, 'clientX'), num(init, 'clientY'), flag(init, 'ctrlKey'), flag(init, 'altKey'), flag(init, 'shiftKey'), flag(init, 'metaKey'), num(init, 'button'), init.relatedTarget || null);
            return e;
        });
        wrap('KeyboardEvent', function (a) {
            var init = a[1] || {}, e = document.createEvent('KeyboardEvent');
            e.initKeyboardEvent(String(a[0]), flag(init, 'bubbles'), flag(init, 'cancelable'), init.view || window, init.keyIdentifier || '', num(init, 'location'),
                                flag(init, 'ctrlKey'), flag(init, 'altKey'), flag(init, 'shiftKey'), flag(init, 'metaKey'), false);
            // (key, code and keyCode as given: the page shims read them back, see shims-extra.js KeyboardEvent.key)
            var extra = { key: init.key, code: init.code, repeat: !!init.repeat, isComposing: !!init.isComposing };
            for (var x in extra) if (extra[x] !== undefined) try { Object.defineProperty(e, x, { value: extra[x], configurable: true }); } catch (err) {}
            return e;
        });
        wrap('TouchEvent', function (a) { var init = a[1] || {}, e = document.createEvent('UIEvents'); e.initUIEvent(String(a[0]), flag(init, 'bubbles'), flag(init, 'cancelable'), init.view || window, 0);
            e.touches = init.touches || []; e.targetTouches = init.targetTouches || []; e.changedTouches = init.changedTouches || []; return e; });
        var events = ['ErrorEvent', 'PopStateEvent', 'HashChangeEvent', 'AnimationEvent', 'TransitionEvent', 'MessageEvent', 'ProgressEvent', 'CloseEvent', 'StorageEvent', 'WheelEvent',
                      'CompositionEvent', 'TextEvent', 'BeforeUnloadEvent', 'PageTransitionEvent', 'WebKitAnimationEvent', 'WebKitTransitionEvent', 'OverflowEvent', 'DeviceOrientationEvent', 'DeviceMotionEvent'];
        for (var ev = 0; ev < events.length; ev++) wrap(events[ev]);
        var things = ['WebSocket', 'Image', 'Audio', 'Option', 'DOMParser', 'XMLSerializer', 'FileReader', 'MutationObserver', 'WebKitMutationObserver', 'EventSource', 'MessageChannel',
                      'SharedWorker', 'XPathEvaluator', 'XSLTProcessor', 'ArrayBuffer', 'DataView', 'Node', 'Element', 'Document', 'CharacterData', 'Attr', 'NodeList', 'HTMLCollection',
                      'SVGElement', 'CSSStyleSheet', 'CSSRule', 'CanvasRenderingContext2D', 'WebGLRenderingContext', 'Storage', 'Selection', 'DOMImplementation', 'TreeWalker', 'NodeIterator'];
        for (var t = 0; t < things.length; t++) wrap(things[t]);
        if (window.WebKitMutationObserver && window.MutationObserver && window.MutationObserver.__brNative === window.WebKitMutationObserver.__brNative) window.WebKitMutationObserver = window.MutationObserver;
        wrap('Text', function (a) { return document.createTextNode(a.length ? String(a[0]) : ''); });
        wrap('Comment', function (a) { return document.createComment(a.length ? String(a[0]) : ''); });
        wrap('DocumentFragment', function () { return document.createDocumentFragment(); });
        wrap('Range', function () { return document.createRange(); });
        // new File(parts, name, options): a Blob with the name and date, and File's prototype
        wrap('File', function (a) {
            var opts = a[2] || {}, b = new window.Blob(a[0] || [], opts.type ? { type: opts.type } : {});
            try { b.__proto__ = window.File.prototype; } catch (e) {}
            try { Object.defineProperty(b, 'name', { value: String(a[1]), configurable: true }); } catch (e2) { b.name = String(a[1]); }
            try { Object.defineProperty(b, 'lastModified', { value: typeof opts.lastModified === 'number' ? opts.lastModified : Date.now(), configurable: true }); } catch (e3) {}
            try { Object.defineProperty(b, '__brName', { value: String(a[1]), configurable: true }); } catch (e4) {}
            return b;
        });
    })();
})(window, document);
