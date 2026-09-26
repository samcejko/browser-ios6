// The first part of the page's polyfill bundle (before core-js): things the engine keeps as roots of its garbage
// collection, so that a page holding them stays in memory after it was left - its window, every object of its scripts,
// its document (27 000 objects of ours on example.com, 200 000 more on each visit of novinky.cz) - until iOS closed the
// app after a few pages.
(function () {
    var releases = [], gone = false;
    var release = function (e) {
        if (gone || e && e.type === 'pagehide' && e.persisted) return;    // (kept to come back to)
        gone = true;
        for (var i = 0; i < releases.length; i++) { try { releases[i](); } catch (x) {} }
    };

    // MutationObserver: the engine holds its callback and the page's window with strong references for as long as it
    // lives, and it lives while anything reaches it - the page, which that root keeps; disconnecting is not enough while
    // the page still holds the observer. So pages get stand-in observers that hold the engine's ones; when the page goes
    // away, those are disconnected and let go, nothing reaches them any more, and the roots go with them.
    // (The stand-ins also take the options of the current standard: attributeFilter/-OldValue imply attributes, and
    // characterDataOldValue implies characterData; this engine threw.)
    (function () {
        var Native = window.MutationObserver || window.WebKitMutationObserver;
        if (!Native || Native.__brBoxed) return;
        var live = [];
        var state = function (o) {
            var s = o && o.__brMO;
            if (!s) throw new TypeError('Illegal invocation');
            return s;
        };
        var MO = function MutationObserver(callback) {
            if (!(this instanceof MO)) throw new TypeError("Failed to construct 'MutationObserver': Please use the 'new' operator.");
            if (typeof callback !== 'function') throw new TypeError("Failed to construct 'MutationObserver': The callback provided as parameter 1 is not a function.");
            var s = { cb: callback, self: this, native: null };
            try { Object.defineProperty(this, '__brMO', { value: s, configurable: true }); } catch (e) { this.__brMO = s; }
        };
        MO.prototype.observe = function (target, options) {
            var s = state(this), o = options;
            if (gone) return;
            if (o && typeof o === 'object' &&
                (o.attributes === undefined && (o.attributeOldValue !== undefined || o.attributeFilter !== undefined) ||
                 o.characterData === undefined && o.characterDataOldValue !== undefined)) {
                var c = {};
                for (var k in o) c[k] = o[k];
                if (c.attributes === undefined && (c.attributeOldValue !== undefined || c.attributeFilter !== undefined)) c.attributes = true;
                if (c.characterData === undefined && c.characterDataOldValue !== undefined) c.characterData = true;
                o = c;
            }
            if (!s.native) {
                s.native = new Native(function (records) { return s.cb.call(s.self, records, s.self); });
                live.push(s);
            }
            s.native.observe(target, o);
        };
        MO.prototype.disconnect = function () {
            var s = state(this);
            if (!s.native) return;
            s.native.disconnect();
            s.native = null;    // (the next observe makes a new one)
            var i = live.indexOf(s);
            if (i >= 0) live.splice(i, 1);
        };
        MO.prototype.takeRecords = function () {
            var s = state(this);
            return s.native ? s.native.takeRecords() : [];
        };
        MO.prototype.constructor = MO;
        MO.toString = function () { return 'function MutationObserver() {\n    [native code]\n}'; };
        MO.__brBoxed = true;
        MO.__brNative = Native;
        try { window.MutationObserver = MO; } catch (e1) {}
        if (window.WebKitMutationObserver) { try { window.WebKitMutationObserver = MO; } catch (e2) {} }
        releases.push(function () {
            for (var i = 0; i < live.length; i++) {
                var s = live[i];
                if (s.native) { try { s.native.disconnect(); } catch (x) {} s.native = null; }
            }
            live = [];
        });
    })();

    // matchMedia listeners are such roots too (until the document is destroyed - never, while they keep it): they are
    // removed when the page goes away.
    (function () {
        var proto = null;
        try { proto = window.matchMedia && Object.getPrototypeOf(window.matchMedia('all')); } catch (e) {}
        var add = proto && proto.addListener, remove = proto && proto.removeListener;
        if (typeof add !== 'function' || typeof remove !== 'function' || add.__brBoxed) return;
        var heard = [];     // list, listener, list, listener, ...
        var find = function (list, fn) {
            for (var i = 0; i < heard.length; i += 2) if (heard[i] === list && heard[i + 1] === fn) return i;
            return -1;
        };
        proto.addListener = function (fn) {
            if (gone) return;
            if (typeof fn === 'function' && find(this, fn) < 0) heard.push(this, fn);
            return add.apply(this, arguments);
        };
        proto.removeListener = function (fn) {
            var i = find(this, fn);
            if (i >= 0) heard.splice(i, 2);
            return remove.apply(this, arguments);
        };
        proto.addListener.__brBoxed = true;
        releases.push(function () {
            for (var i = 0; i < heard.length; i += 2) { try { remove.call(heard[i], heard[i + 1]); } catch (x) {} }
            heard = [];
        });
    })();

    // A CustomEvent's detail is such a root while the event lives, so a page that keeps an event keeps itself. Custom
    // events are plain events here, with the detail as their own property (and the prototype of CustomEvent).
    (function () {
        var Native = window.CustomEvent, NP = Native && Native.prototype;
        var owner = document;
        while (owner && !Object.prototype.hasOwnProperty.call(owner, 'createEvent')) owner = Object.getPrototypeOf(owner);
        var create = owner && owner.createEvent;
        if (!NP || typeof create !== 'function' || create.__brBoxed) return;
        var initEvent = null;
        try { initEvent = create.call(document, 'Event').initEvent; } catch (e) {}
        if (typeof initEvent !== 'function') return;
        var P = Object.create(NP);
        var detail = function (e, d) {
            try { Object.defineProperty(e, 'detail', { value: d, writable: true, enumerable: true, configurable: true }); } catch (x) { e.detail = d; }
        };
        P.initCustomEvent = function (type, bubbles, cancelable, d) {
            initEvent.call(this, type, bubbles, cancelable);
            detail(this, d === undefined ? null : d);
        };
        var make = function (doc, proto) {
            var e = create.call(doc, 'Event');
            e.__proto__ = proto;
            detail(e, null);
            return e;
        };
        owner.createEvent = function (kind) {
            if (typeof kind === 'string' && kind.toLowerCase() === 'customevent') return make(this, P);
            return create.apply(this, arguments);
        };
        owner.createEvent.__brBoxed = true;
        var CE = function CustomEvent(type, init) {
            if (!arguments.length) throw new TypeError("Failed to construct 'CustomEvent': 1 argument required, but only 0 present.");
            // (a subclass's prototype stays: ES5 classes call this with their own instance)
            var e = make(document, this instanceof CE ? Object.getPrototypeOf(this) : P);
            P.initCustomEvent.call(e, String(type), !!(init && init.bubbles), !!(init && init.cancelable), init ? init.detail : null);
            return e;
        };
        CE.prototype = P;
        P.constructor = CE;
        try { window.CustomEvent = CE; } catch (e3) {}
    })();

    window.addEventListener('pagehide', release, false);
    window.addEventListener('unload', release, false);
})();
