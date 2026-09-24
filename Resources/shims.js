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
    // navigator.clipboard is provided by shims-extra.js (writes go to the app)
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
        var SEP = { cs: [' ', ','], sk: [' ', ','], pl: [' ', ','], de: ['.', ','], fr: [' ', ','], it: ['.', ','], es: ['.', ','], ru: [' ', ','], hu: [' ', ','], nl: ['.', ','], pt: ['.', ','], sv: [' ', ','], da: ['.', ','], fi: [' ', ','], nb: [' ', ','], tr: ['.', ','], uk: [' ', ','], en: [',', '.'] };
        var CURRENCY = { CZK: ['Kč', 1], EUR: ['€', 1], USD: ['$', 0], GBP: ['£', 0], PLN: ['zł', 1], HUF: ['Ft', 1], CHF: ['CHF', 0], JPY: ['¥', 0], SEK: ['kr', 1], NOK: ['kr', 1], DKK: ['kr', 1], RUB: ['₽', 1], UAH: ['₴', 1], CNY: ['CN¥', 0], INR: ['₹', 0], BRL: ['R$', 0], CAD: ['CA$', 0], AUD: ['A$', 0] };
        var COMPACT = { cs: ['tis.', 'mil.', 'mld.', 'bil.'], sk: ['tis.', 'mil.', 'mld.', 'bil.'], pl: ['tys.', 'mln', 'mld', 'bln'], de: ['Tsd.', 'Mio.', 'Mrd.', 'Bio.'], en: ['K', 'M', 'B', 'T'] };
        var NumberFormat = function NumberFormat(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; };
        NumberFormat.prototype.formatToParts = function (n) {
            var o = this.opts, lg = lang(this.locale), sep = SEP[lg] || SEP.en, v = Number(n), parts = [];
            if (isNaN(v)) return [{ type: 'nan', value: 'NaN' }];
            if (!isFinite(v)) return [{ type: v < 0 ? 'minusSign' : 'plusSign', value: v < 0 ? '-' : '' }, { type: 'infinity', value: '∞' }];
            var style = o.style || 'decimal', currency = o.currency ? String(o.currency).toUpperCase() : null;
            var scaled = style === 'percent' ? v * 100 : v, unitSuffix = '';
            if (o.notation === 'compact') {
                var names = COMPACT[lg] || COMPACT.en, abs = Math.abs(scaled), idx = -1;
                if (abs >= 1e12) idx = 3; else if (abs >= 1e9) idx = 2; else if (abs >= 1e6) idx = 1; else if (abs >= 1e3) idx = 0;
                if (idx >= 0) { scaled = scaled / Math.pow(1000, idx + 1); unitSuffix = (lg === 'en' ? '' : ' ') + names[idx]; }
            }
            var minF = o.minimumFractionDigits, maxF = o.maximumFractionDigits;
            if (maxF === undefined) maxF = style === 'currency' ? (currency === 'JPY' || currency === 'HUF' ? 0 : 2) : style === 'percent' ? 0 : o.notation === 'compact' ? (Math.abs(scaled) < 100 ? 1 : 0) : 3;
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
            if (cur && !curAfter) parts.push({ type: 'currency', value: cur }, { type: 'literal', value: lg === 'en' ? '' : ' ' });
            for (var g = 0; g < groups.length; g++) { if (g) parts.push({ type: 'group', value: sep[0] }); parts.push({ type: 'integer', value: groups[g] }); }
            if (frac) parts.push({ type: 'decimal', value: sep[1] }, { type: 'fraction', value: frac });
            if (unitSuffix) parts.push({ type: 'compact', value: unitSuffix });
            if (style === 'percent') parts.push({ type: 'literal', value: lg === 'en' ? '' : ' ' }, { type: 'percentSign', value: '%' });
            if (style === 'unit' && o.unit) parts.push({ type: 'literal', value: ' ' }, { type: 'unit', value: UNIT_SHORT[o.unit] || o.unit });
            if (cur && curAfter) parts.push({ type: 'literal', value: ' ' }, { type: 'currency', value: cur });
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
        var DateTimeFormat = function DateTimeFormat(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; this.data = localeData(this.locale); };
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
                if (wantTime) lit(o.dateStyle && o.timeStyle ? data.dateTimeSep : ' ');
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
        var LIST = { cs: [' a ', ' nebo '], sk: [' a ', ' alebo '], de: [' und ', ' oder '], pl: [' i ', ' lub '], fr: [' et ', ' ou '], es: [' y ', ' o '], en: [' and ', ' or '] };
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
        var Collator = function Collator(locale, opts) { this.locale = canon(locale); this.opts = opts || {}; var self = this; this.compare = function (a, b) { return self.compareStrings(a, b); }; };
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
