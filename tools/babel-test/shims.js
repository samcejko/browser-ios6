/* shims.js - small browser API shims for the iOS 6 WebKit, loaded after core-js, regenerator, fetch,
 * IntersectionObserver and ResizeObserver polyfills. ES5 only. */
(function (window, document) {
    'use strict';
    var Ep = window.Element && window.Element.prototype;

    // requestAnimationFrame (only the webkit prefixed one exists)
    if (!window.requestAnimationFrame) {
        window.requestAnimationFrame = window.webkitRequestAnimationFrame || function (cb) { return window.setTimeout(function () { cb(Date.now()); }, 16); };
        window.cancelAnimationFrame = window.webkitCancelAnimationFrame || window.webkitCancelRequestAnimationFrame || function (id) { window.clearTimeout(id); };
    }
    if (!window.MutationObserver && window.WebKitMutationObserver) window.MutationObserver = window.WebKitMutationObserver;
    if (!window.requestIdleCallback) {
        window.requestIdleCallback = function (cb) { return window.setTimeout(function () { var start = Date.now(); cb({ didTimeout: false, timeRemaining: function () { return Math.max(0, 50 - (Date.now() - start)); } }); }, 1); };
        window.cancelIdleCallback = function (id) { window.clearTimeout(id); };
    }

    // performance
    if (!window.performance) window.performance = {};
    var perf = window.performance;
    if (!perf.now) { var t0 = Date.now(); perf.now = function () { return Date.now() - t0; }; }
    if (!perf.mark) perf.mark = function () {};
    if (!perf.measure) perf.measure = function () {};
    if (!perf.getEntriesByType) perf.getEntriesByType = function () { return []; };
    if (!perf.getEntriesByName) perf.getEntriesByName = function () { return []; };
    if (!perf.getEntries) perf.getEntries = function () { return []; };
    if (!perf.clearMarks) perf.clearMarks = function () {};
    if (!perf.clearMeasures) perf.clearMeasures = function () {};
    if (!perf.timing) perf.timing = { navigationStart: t0 || Date.now() };
    if (!perf.timeOrigin) perf.timeOrigin = Date.now();
    if (!window.PerformanceObserver) {
        window.PerformanceObserver = function () {};
        window.PerformanceObserver.prototype.observe = function () {};
        window.PerformanceObserver.prototype.disconnect = function () {};
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
        function toNodes(args) {
            var frag = document.createDocumentFragment();
            for (var i = 0; i < args.length; i++) { var a = args[i]; frag.appendChild(a instanceof Node ? a : document.createTextNode(String(a))); }
            return frag;
        }
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

    // document.currentScript (parser-inserted scripts only)
    if (!('currentScript' in document)) {
        try {
            Object.defineProperty(document, 'currentScript', { get: function () { var s = document.getElementsByTagName('script'); return s.length ? s[s.length - 1] : null; } });
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
        window.EventTarget = function () { this.__listeners = {}; };
        window.EventTarget.prototype.addEventListener = function (t, f) { (this.__listeners[t] = this.__listeners[t] || []).push(f); };
        window.EventTarget.prototype.removeEventListener = function (t, f) { var l = this.__listeners[t] || []; var i = l.indexOf(f); if (i >= 0) l.splice(i, 1); };
        window.EventTarget.prototype.dispatchEvent = function (e) { var l = (this.__listeners[e.type] || []).slice(); for (var i = 0; i < l.length; i++) l[i].call(this, e); return !e.defaultPrevented; };
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
    if (!navigator.connection) navigator.connection = { effectiveType: '3g', saveData: false, addEventListener: function () {} };
    if (!navigator.clipboard) navigator.clipboard = { writeText: function () { return window.Promise ? window.Promise.reject(new Error('unsupported')) : null; }, readText: function () { return window.Promise ? window.Promise.reject(new Error('unsupported')) : null; } };
    if (!navigator.serviceWorker) navigator.serviceWorker = { register: function () { return window.Promise ? window.Promise.reject(new Error('unsupported')) : null; }, getRegistrations: function () { return window.Promise ? window.Promise.resolve([]) : null; }, addEventListener: function () {}, controller: null, ready: window.Promise ? new window.Promise(function () {}) : null };
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

    // Intl: minimal stand-ins so feature detection does not throw
    if (!window.Intl) {
        var Intl = window.Intl = {};
        Intl.NumberFormat = function (locale, opts) { this.opts = opts || {}; };
        Intl.NumberFormat.prototype.format = function (n) {
            var o = this.opts, v = Number(n);
            var digits = o.maximumFractionDigits !== undefined ? o.maximumFractionDigits : (o.style === 'currency' ? 2 : 3);
            var s = v.toFixed(Math.min(digits, 20)).replace(/\.?0+$/, '');
            if (o.minimumFractionDigits) { var parts = s.split('.'); var frac = parts[1] || ''; while (frac.length < o.minimumFractionDigits) frac += '0'; s = parts[0] + (frac ? '.' + frac : ''); }
            s = s.replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
            if (o.style === 'currency') s += ' ' + (o.currency || '');
            if (o.style === 'percent') s = (v * 100).toFixed(0) + ' %';
            return s;
        };
        Intl.NumberFormat.prototype.formatToParts = function (n) { return [{ type: 'integer', value: this.format(n) }]; };
        Intl.NumberFormat.prototype.resolvedOptions = function () { return { locale: 'en', numberingSystem: 'latn' }; };
        Intl.NumberFormat.supportedLocalesOf = function () { return []; };
        Intl.DateTimeFormat = function (locale, opts) { this.opts = opts || {}; };
        Intl.DateTimeFormat.prototype.format = function (d) { d = d instanceof Date ? d : new Date(d || Date.now()); var o = this.opts; if (o.timeStyle || o.hour) return d.toLocaleString(); if (o.dateStyle || o.year || o.month || o.day) return d.toLocaleDateString(); return d.toLocaleDateString(); };
        Intl.DateTimeFormat.prototype.formatToParts = function (d) { return [{ type: 'literal', value: this.format(d) }]; };
        Intl.DateTimeFormat.prototype.resolvedOptions = function () { return { locale: 'en', timeZone: 'UTC', calendar: 'gregory', numberingSystem: 'latn' }; };
        Intl.DateTimeFormat.supportedLocalesOf = function () { return []; };
        Intl.PluralRules = function () {};
        Intl.PluralRules.prototype.select = function (n) { return n === 1 ? 'one' : 'other'; };
        Intl.PluralRules.supportedLocalesOf = function () { return []; };
        Intl.RelativeTimeFormat = function () {};
        Intl.RelativeTimeFormat.prototype.format = function (v, unit) { return (v < 0 ? Math.abs(v) + ' ' + unit + ' ago' : 'in ' + v + ' ' + unit); };
        Intl.Collator = function () {};
        Intl.Collator.prototype.compare = function (a, b) { return String(a).localeCompare(String(b)); };
        Intl.ListFormat = function () {};
        Intl.ListFormat.prototype.format = function (l) { return Array.prototype.join.call(l, ', '); };
        Intl.getCanonicalLocales = function (l) { return typeof l === 'string' ? [l] : (l || []); };
        Intl.supportedValuesOf = function () { return []; };
    }

    // IndexedDB is missing on iOS 6: expose a stub that fails cleanly (many libraries feature-detect it)
    if (!window.indexedDB) {
        window.indexedDB = null;
    }

    // customElements: registry stub so definitions do not throw (rendering of custom elements is not emulated)
    if (!window.customElements) {
        var registry = {};
        window.customElements = {
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

    if (!window.structuredClone) window.structuredClone = function (v) { return v === undefined ? v : JSON.parse(JSON.stringify(v)); };
    if (!window.reportError) window.reportError = function (e) { if (con.error) con.error(e); };
    if (!window.HTMLDialogElement) window.HTMLDialogElement = function () {};
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
})(window, document);
