/* shims-extra.js - larger browser API emulations for the iOS 6 WebKit, loaded after shims.js:
 * new-tab handling for window.open / target=_blank, pointer events, page visibility, fullscreen,
 * streams, shadow DOM emulated in the light DOM, custom element upgrades, <dialog> registration,
 * WebRTC / speech / payment / credential stubs that fail cleanly, crypto.subtle digests, canvas
 * helpers, responsive image properties. ES5 only. */
(function (window, document) {
    'use strict';
    var Ep = window.Element && window.Element.prototype;
    var Np = window.Node && window.Node.prototype;
    var P = window.Promise;
    function noop() {}
    function resolved(v) { return P ? P.resolve(v) : null; }
    function domException(name, message) {
        var e = new Error(message || name);
        e.name = name;
        e.code = name === 'NotSupportedError' ? 9 : name === 'AbortError' ? 20 : name === 'NotFoundError' ? 8 : 0;
        return e;
    }
    function rejectWith(name, message) { return function () { return P ? P.reject(domException(name, message)) : null; }; }
    function fire(target, type, detail) {
        try {
            var e = document.createEvent('Event');
            e.initEvent(type, true, false);
            if (detail) for (var k in detail) e[k] = detail[k];
            target.dispatchEvent(e);
        } catch (e2) {}
    }
    function defineAttrProp(proto, name, attr) {
        if (!proto || name in proto) return;
        try {
            Object.defineProperty(proto, name, {
                get: function () { return this.getAttribute(attr || name) || ''; },
                set: function (v) { this.setAttribute(attr || name, v); },
                configurable: true
            });
        } catch (e) {}
    }
    function defineBoolAttrProp(proto, name) {
        if (!proto || name in proto) return;
        try {
            Object.defineProperty(proto, name, {
                get: function () { return this.hasAttribute(name) && this.getAttribute(name) !== 'false'; },
                set: function (v) { if (v) this.setAttribute(name, 'true'); else this.removeAttribute(name); },
                configurable: true
            });
        } catch (e) {}
    }
    function addStyle(css) {
        var s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
    }
    function onReady(fn) {
        if (document.readyState === 'complete' || document.readyState === 'interactive') setTimeout(fn, 0);
        else document.addEventListener('DOMContentLoaded', fn, false);
    }
    // adds or removes one of the state classes cssfix substitutes for pseudo-classes the engine lacks
    function setStateClass(el, cls, on) {
        if (!el || el.nodeType !== 1) return;
        try {
            var cur = ' ' + (el.className && typeof el.className === 'string' ? el.className : '') + ' ';
            var has = cur.indexOf(' ' + cls + ' ') >= 0;
            if (on && !has) el.className = (el.className ? el.className + ' ' : '') + cls;
            else if (!on && has) el.className = cur.replace(' ' + cls + ' ', ' ').replace(/^\s+|\s+$/g, '');
        } catch (e) {}
    }
    // One observer for everything that reacts to new DOM nodes
    var addedCallbacks = [], settledCallbacks = [], settleTimer = null;
    function observeAdded(fn) { addedCallbacks.push(fn); }
    function onSettled(fn) { settledCallbacks.push(fn); }
    if (window.MutationObserver) {
        var mo = new MutationObserver(function (records) {
            for (var r = 0; r < records.length; r++) {
                var added = records[r].addedNodes;
                for (var i = 0; i < added.length; i++) {
                    if (added[i].nodeType !== 1) continue;
                    for (var c = 0; c < addedCallbacks.length; c++) try { addedCallbacks[c](added[i]); } catch (e) {}
                }
                var removed = records[r].removedNodes;
                for (var j = 0; j < removed.length; j++) if (removed[j].nodeType === 1 && removed[j].__brUpgraded) disconnectTree(removed[j]);
            }
            if (settledCallbacks.length && !settleTimer) settleTimer = setTimeout(function () { settleTimer = null; for (var s = 0; s < settledCallbacks.length; s++) try { settledCallbacks[s](); } catch (e) {} }, 150);
        });
        var startObserving = function () { try { mo.observe(document.documentElement || document, { childList: true, subtree: true }); } catch (e) {} };
        if (document.documentElement) startObserving(); else document.addEventListener('DOMContentLoaded', startObserving, false);
    }

    // ---- New tabs: window.open and target=_blank links go to the app (brtab: scheme handled natively)
    function sendToApp(scheme, payload) {
        try {
            var f = document.createElement('iframe');
            f.style.display = 'none';
            f.src = scheme + ':' + encodeURIComponent(payload);
            (document.body || document.documentElement).appendChild(f);
            setTimeout(function () { if (f.parentNode) f.parentNode.removeChild(f); }, 100);
            return true;
        } catch (e) { return false; }
    }
    function absoluteURL(url) {
        try { var a = document.createElement('a'); a.href = String(url); return a.href; } catch (e) { return String(url); }
    }
    function openInNewTab(url) {
        url = absoluteURL(url);
        if (!/^https?:/i.test(url)) return false;
        return sendToApp('brtab', url);
    }
    function frameExists(name) { try { return !!window.frames[name]; } catch (e) { return false; } }
    // Popup blocking: window.open only counts within a moment of a tap, click or key press
    var lastGesture = 0, blockedPopups = 0;
    function noteGesture() { lastGesture = Date.now(); }
    var gestureEvents = ['touchend', 'click', 'keydown', 'mouseup', 'submit'];
    for (var ge = 0; ge < gestureEvents.length; ge++) document.addEventListener(gestureEvents[ge], noteGesture, true);
    window.open = function (url, name, features) {
        if (name === '_self' || name === '_top' || name === '_parent') { if (url) window.location.href = url; return window; }
        if (name && frameExists(name)) { try { window.frames[name].location.href = url; } catch (e) {} return window.frames[name]; }
        if (Date.now() - lastGesture > 2000) {
            if (blockedPopups++ < 3) sendToApp('brlog', 'Popup blocked: ' + String(url || '').slice(0, 200));
            return null;
        }
        if (!url || url === 'about:blank' || String(url).charAt(0) === '#') url = '';
        var fake = { closed: false, focus: noop, blur: noop, postMessage: noop, opener: window, name: name || '', addEventListener: noop, removeEventListener: noop,
                     document: { write: noop, writeln: noop, close: noop, open: noop, body: null, title: '' } };
        fake.close = function () { fake.closed = true; };
        var loc = { assign: function (v) { loc.href = v; }, replace: function (v) { loc.href = v; }, toString: function () { return loc.__h || ''; } };
        try {
            Object.defineProperty(loc, 'href', { get: function () { return loc.__h || ''; }, set: function (v) { loc.__h = String(v); openInNewTab(v); } });
            Object.defineProperty(fake, 'location', { get: function () { return loc; }, set: function (v) { loc.href = String(v); } });
        } catch (e) { fake.location = loc; }
        if (url) openInNewTab(url);
        return fake;
    };
    document.addEventListener('click', function (e) {
        if (e.defaultPrevented || e.button > 0 || e.metaKey || e.ctrlKey) return;
        var a = e.target;
        while (a && a.nodeType === 1 && a.tagName !== 'A' && a.tagName !== 'AREA') a = a.parentNode;
        if (!a || a.nodeType !== 1) return;
        var target = (a.getAttribute('target') || '').toLowerCase();
        var href = a.getAttribute('href');
        if (!href || href.charAt(0) === '#' || /^javascript:/i.test(href)) return;
        if (target === '_blank' || (target && target !== '_self' && target !== '_top' && target !== '_parent' && !frameExists(target))) {
            if (openInNewTab(a.href)) e.preventDefault();
        }
    }, false);
    // Load timing for the app's log: when the DOM was ready, when the page finished, and the longest stretch
    // during which the engine was too busy to run a 1 s timer (JavaScript or layout work).
    var brT0 = Date.now(), lastTick = brT0, maxGap = 0, maxGapAt = 0;
    var tickTimer = setInterval(function () { var now = Date.now(), gap = now - lastTick - 1000; if (gap > maxGap) { maxGap = gap; maxGapAt = lastTick - brT0; } lastTick = now; }, 1000);
    document.addEventListener('DOMContentLoaded', function () { sendToApp('brlog', 'timing: DOMContentLoaded after ' + (Date.now() - brT0) + ' ms, busy gap so far ' + maxGap + ' ms'); }, false);
    window.addEventListener('load', function () {
        sendToApp('brlog', 'timing: load after ' + (Date.now() - brT0) + ' ms, longest busy gap ' + maxGap + ' ms at ' + maxGapAt + ' ms, scripts ' + document.scripts.length + ', errors ' + reportedErrors + ', nodes ' + document.getElementsByTagName('*').length);
        setTimeout(function () { clearInterval(tickTimer); }, 30000);
    }, false);
    // Uncaught errors of the page reach the app's log (brlog: scheme) so that broken sites can be diagnosed over SSH
    var reportedErrors = 0;
    window.addEventListener('error', function (e) {
        if (reportedErrors >= 5) return;
        reportedErrors++;
        var src = (e.filename || '').split('/').slice(-1)[0];
        sendToApp('brlog', 'JS error: ' + (e.message || 'error') + ' @ ' + src + ':' + (e.lineno || 0) + ' page ' + location.hostname);
    }, false);
    // Web Share goes to the app's share sheet
    if (!navigator.share) {
        navigator.share = function (data) {
            data = data || {};
            var ok = sendToApp('brshare', JSON.stringify({ title: data.title || '', text: data.text || '', url: data.url ? absoluteURL(data.url) : '' }));
            return ok ? resolved() : rejectWith('AbortError', 'share failed')();
        };
        navigator.canShare = function (data) { return !!(data && (data.url || data.text || data.title)); };
    }
    // Clipboard writes go to the system pasteboard through the app; window.print() opens the print dialog
    try {
        navigator.clipboard = {
            writeText: function (text) { return sendToApp('brcopy', String(text)) ? resolved() : rejectWith('NotAllowedError', 'copy failed')(); },
            write: function () { return rejectWith('NotAllowedError', 'only text can be copied')(); },
            readText: function () { return rejectWith('NotAllowedError', 'reading the clipboard is not allowed')(); },
            read: function () { return rejectWith('NotAllowedError', 'reading the clipboard is not allowed')(); }
        };
        window.print = function () { sendToApp('brprint', '1'); };
    } catch (e) {}   // a desktop browser (the smoke test) has a read-only navigator.clipboard
    try {
        var execCommandOrig = document.execCommand;
        document.execCommand = function (cmd) {
            var r = false;
            try { r = execCommandOrig.apply(document, arguments); } catch (e) {}
            if (String(cmd).toLowerCase() === 'copy') {
                var t = String(window.getSelection()), a = document.activeElement;
                if (!t && a && (a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && typeof a.selectionStart === 'number') t = String(a.value || '').substring(a.selectionStart, a.selectionEnd);
                if (t) { sendToApp('brcopy', t); r = true; }
            }
            return r;
        };
    } catch (e) {}

    // ---- Pointer events: touches and mouse events are mirrored as pointer events
    if (!window.PointerEvent) {
        var nextPointerId = 2, activeTouches = {}, activeTouchCount = 0, lastTouchTime = 0;
        var makePointerEvent = function makePointerEvent(type, src, touch, pointerType, id, isPrimary) {
            var e = document.createEvent('MouseEvents');
            var bubbles = type !== 'pointerenter' && type !== 'pointerleave';
            var cancelable = type !== 'pointercancel' && type !== 'pointerenter' && type !== 'pointerleave';
            e.initMouseEvent(type, bubbles, cancelable, window, 0,
                touch ? touch.screenX : (src.screenX || 0), touch ? touch.screenY : (src.screenY || 0),
                touch ? touch.clientX : (src.clientX || 0), touch ? touch.clientY : (src.clientY || 0),
                !!src.ctrlKey, !!src.altKey, !!src.shiftKey, !!src.metaKey, src.button || 0, src.relatedTarget || null);
            e.pointerId = id;
            e.pointerType = pointerType;
            e.isPrimary = isPrimary;
            e.width = e.height = pointerType === 'touch' ? 20 : 1;
            e.pressure = (type === 'pointerdown' || (type === 'pointermove' && (pointerType === 'touch' || src.buttons))) ? 0.5 : 0;
            e.tangentialPressure = 0;
            e.tiltX = e.tiltY = e.twist = 0;
            e.buttons = (type === 'pointerup' || type === 'pointercancel') ? 0 : (src.buttons !== undefined ? src.buttons : (type === 'pointermove' && pointerType === 'mouse' ? 0 : 1));
            e.getCoalescedEvents = function () { return [e]; };
            e.getPredictedEvents = function () { return []; };
            return e;
        };
        var touchHandler = function touchHandler(type) {
            return function (ev) {
                lastTouchTime = Date.now();
                var touches = ev.changedTouches;
                for (var i = 0; i < touches.length; i++) {
                    var t = touches[i], key = 't' + t.identifier;
                    if (!activeTouches[key]) { activeTouches[key] = { id: nextPointerId++, primary: activeTouchCount === 0 }; activeTouchCount++; }
                    var info = activeTouches[key];
                    var target = t.target && t.target.nodeType === 1 ? t.target : (t.target && t.target.parentNode) || ev.target;
                    var pe = makePointerEvent(type, ev, t, 'touch', info.id, info.primary);
                    try { target.dispatchEvent(pe); } catch (e) {}
                    if (pe.defaultPrevented && ev.cancelable) ev.preventDefault();
                    if (type === 'pointerup' || type === 'pointercancel') { delete activeTouches[key]; activeTouchCount = Math.max(0, activeTouchCount - 1); }
                }
            };
        };
        document.addEventListener('touchstart', touchHandler('pointerdown'), true);
        document.addEventListener('touchmove', touchHandler('pointermove'), true);
        document.addEventListener('touchend', touchHandler('pointerup'), true);
        document.addEventListener('touchcancel', touchHandler('pointercancel'), true);
        var mouseMap = { mousedown: 'pointerdown', mousemove: 'pointermove', mouseup: 'pointerup', mouseover: 'pointerover', mouseout: 'pointerout' };
        for (var mname in mouseMap) (function (mtype, ptype) {
            document.addEventListener(mtype, function (ev) {
                if (Date.now() - lastTouchTime < 1500) return;   // mouse events synthesized from a tap
                var pe = makePointerEvent(ptype, ev, null, 'mouse', 1, true);
                try { ev.target.dispatchEvent(pe); } catch (e) {}
                if (pe.defaultPrevented && ev.cancelable) ev.preventDefault();
            }, true);
        })(mname, mouseMap[mname]);
        window.PointerEvent = function PointerEvent(type, init) {
            init = init || {};
            return makePointerEvent(type, init, null, init.pointerType || 'mouse', init.pointerId || 1, init.isPrimary !== false);
        };
        if (Ep) {
            Ep.setPointerCapture = noop;
            Ep.releasePointerCapture = noop;
            Ep.hasPointerCapture = function () { return false; };
        }
        if (!('maxTouchPoints' in navigator)) try { navigator.maxTouchPoints = 'ontouchstart' in window ? 5 : 0; } catch (e) {}
        var pointerNames = ['pointerdown', 'pointerup', 'pointermove', 'pointerover', 'pointerout', 'pointerenter', 'pointerleave', 'pointercancel', 'gotpointercapture', 'lostpointercapture'];
        var defineHandlerProps = function defineHandlerProps(obj) {
            if (!obj || ('onpointerdown' in obj)) return;
            for (var i = 0; i < pointerNames.length; i++) (function (type) {
                try {
                    Object.defineProperty(obj, 'on' + type, {
                        get: function () { return this['__on' + type] || null; },
                        set: function (fn) {
                            var old = this['__on' + type];
                            if (old) this.removeEventListener(type, old, false);
                            this['__on' + type] = typeof fn === 'function' ? fn : null;
                            if (fn) this.addEventListener(type, fn, false);
                        },
                        configurable: true
                    });
                } catch (e) {}
            })(pointerNames[i]);
        };
        defineHandlerProps(window);
        defineHandlerProps(document);
        defineHandlerProps(Ep);
    }
    // the app shows its own menu on a long press over links and images
    try { document.documentElement.style.webkitTouchCallout = 'none'; } catch (e) {}

    // ---- Page visibility
    if (!('hidden' in document) && !('webkitHidden' in document)) {
        var pageHidden = false;
        try {
            Object.defineProperty(document, 'hidden', { get: function () { return pageHidden; }, configurable: true });
            Object.defineProperty(document, 'visibilityState', { get: function () { return pageHidden ? 'hidden' : 'visible'; }, configurable: true });
            Object.defineProperty(document, 'webkitHidden', { get: function () { return pageHidden; }, configurable: true });
            Object.defineProperty(document, 'webkitVisibilityState', { get: function () { return pageHidden ? 'hidden' : 'visible'; }, configurable: true });
        } catch (e) {}
        document.onvisibilitychange = null;
        window.addEventListener('pagehide', function () { pageHidden = true; fire(document, 'visibilitychange'); }, false);
        window.addEventListener('pageshow', function () { pageHidden = false; fire(document, 'visibilitychange'); }, false);
    }

    // ---- Fullscreen: videos use the native player, other elements are pinned to the viewport
    if (!('fullscreenEnabled' in document) && !('webkitFullscreenEnabled' in document)) {
        var fsElement = null;
        try {
            Object.defineProperty(document, 'fullscreenEnabled', { get: function () { return true; }, configurable: true });
            Object.defineProperty(document, 'webkitFullscreenEnabled', { get: function () { return true; }, configurable: true });
            Object.defineProperty(document, 'fullscreenElement', { get: function () { return fsElement; }, configurable: true });
            Object.defineProperty(document, 'webkitFullscreenElement', { get: function () { return fsElement; }, configurable: true });
            Object.defineProperty(document, 'webkitCurrentFullScreenElement', { get: function () { return fsElement; }, configurable: true });
            Object.defineProperty(document, 'fullscreen', { get: function () { return !!fsElement; }, configurable: true });
            Object.defineProperty(document, 'webkitIsFullScreen', { get: function () { return !!fsElement; }, configurable: true });
        } catch (e) {}
        document.onfullscreenchange = null;
        document.onfullscreenerror = null;
        var leaveFullscreen = function leaveFullscreen() {
            var el = fsElement;
            fsElement = null;
            if (!el) return resolved();
            setStateClass(el, 'br-fullscreen', false);
            if (el.tagName === 'VIDEO' && el.webkitExitFullscreen) { try { el.webkitExitFullscreen(); } catch (e) {} }
            else {
                el.style.cssText = el.__brFsStyle || '';
                if (el.__brFsScroll !== undefined) try { window.scrollTo(0, el.__brFsScroll); } catch (e2) {}
                el.__brFsStyle = undefined;
            }
            fire(document, 'fullscreenchange');
            fire(document, 'webkitfullscreenchange');
            fire(el, 'fullscreenchange');
            return resolved();
        };
        document.exitFullscreen = document.webkitExitFullscreen = document.webkitCancelFullScreen = leaveFullscreen;
        if (Ep) Ep.requestFullscreen = Ep.webkitRequestFullscreen = Ep.webkitRequestFullScreen = function () {
            var el = this;
            if (fsElement && fsElement !== el) leaveFullscreen();
            fsElement = el;
            setStateClass(el, 'br-fullscreen', true);
            if (el.tagName === 'VIDEO' && el.webkitEnterFullscreen) {
                try { el.webkitEnterFullscreen(); } catch (e) {}
                el.addEventListener('webkitendfullscreen', function onEnd() { el.removeEventListener('webkitendfullscreen', onEnd, false); if (fsElement === el) leaveFullscreen(); }, false);
            } else {
                el.__brFsStyle = el.style.cssText;
                el.__brFsScroll = window.pageYOffset;
                el.style.cssText += ';position:fixed !important;top:0 !important;left:0 !important;width:100% !important;height:100% !important;max-width:none !important;max-height:none !important;margin:0 !important;z-index:2147483647 !important;background:#000';
                try { window.scrollTo(0, 0); } catch (e3) {}
            }
            fire(document, 'fullscreenchange');
            fire(document, 'webkitfullscreenchange');
            fire(el, 'fullscreenchange');
            return resolved();
        };
        document.addEventListener('keydown', function (e) { if (e.keyCode === 27 && fsElement) leaveFullscreen(); }, false);
    }

    // ---- Gamepad, pointer lock, VR
    if (!navigator.getGamepads) navigator.getGamepads = navigator.webkitGetGamepads = function () { return []; };
    if (!window.Gamepad) window.Gamepad = function Gamepad() {};
    if (!window.GamepadEvent) window.GamepadEvent = function GamepadEvent() {};
    if (Ep && !Ep.requestPointerLock) {
        Ep.requestPointerLock = Ep.webkitRequestPointerLock = function () { setTimeout(function () { fire(document, 'pointerlockerror'); }, 0); };
        document.exitPointerLock = document.webkitExitPointerLock = noop;
        try { Object.defineProperty(document, 'pointerLockElement', { get: function () { return null; }, configurable: true }); } catch (e) {}
    }
    if (!navigator.getVRDisplays) navigator.getVRDisplays = function () { return resolved([]); };
    if (!navigator.xr) navigator.xr = { isSessionSupported: function () { return resolved(false); }, requestSession: rejectWith('NotSupportedError', 'WebXR is not available'), addEventListener: noop, removeEventListener: noop };

    // ---- Web components: shadow roots live in the light DOM, custom elements are upgraded by prototype swap
    if (Ep && !Ep.attachShadow) {
        window.ShadowRoot = window.ShadowRoot || function ShadowRoot() {};
        window.HTMLSlotElement = window.HTMLSlotElement || function HTMLSlotElement() {};
        Ep.attachShadow = function (init) {
            if (this.shadowRoot) return this.shadowRoot;
            var host = this;
            var inline = /^(span|a|b|i|em|strong|label|button|small|code)$/i.test(host.tagName);
            var root = document.createElement(inline ? 'span' : 'div');
            root.setAttribute('data-shadow-root', '');
            root.host = host;
            root.mode = (init && init.mode) || 'open';
            root.delegatesFocus = !!(init && init.delegatesFocus);
            root.adoptedStyleSheets = [];
            root.getElementById = function (id) { return root.querySelector('[id="' + String(id).replace(/"/g, '\\"') + '"]'); };
            root.elementFromPoint = function (x, y) { return document.elementFromPoint(x, y); };
            root.elementsFromPoint = function (x, y) { var el = document.elementFromPoint(x, y); return el ? [el] : []; };
            root.getSelection = function () { return document.getSelection(); };
            try { Object.defineProperty(root, 'activeElement', { get: function () { return document.activeElement; } }); } catch (e) {}
            host.appendChild(root);
            try { Object.defineProperty(host, 'shadowRoot', { value: root, configurable: true, writable: true }); } catch (e2) { host.shadowRoot = root; }
            return root;
        };
        addStyle('[data-shadow-root]{display:inherit}');
    }
    if (Np && !Np.getRootNode) Np.getRootNode = function () { var n = this; while (n.parentNode) n = n.parentNode; return n; };
    if (Ep && !Ep.checkVisibility) Ep.checkVisibility = function (opts) {
        // rendered at all (display:none anywhere up the tree gives no boxes), optionally visibility and opacity too
        if (!this.getClientRects().length) return false;
        var cs = getComputedStyle(this);
        if (opts && (opts.checkVisibilityCSS || opts.visibilityProperty) && cs.visibility !== 'visible') return false;
        if (opts && (opts.checkOpacity || opts.opacityProperty)) { for (var n = this; n && n.nodeType === 1; n = n.parentNode) if (parseFloat(getComputedStyle(n).opacity) === 0) return false; }
        return true;
    };
    if (Np && !('isConnected' in Np)) try { Object.defineProperty(Np, 'isConnected', { get: function () { return document.documentElement.contains(this); } }); } catch (e) {}
    if (window.HTMLLinkElement && !('import' in document.createElement('link'))) {
        try { Object.defineProperty(window.HTMLLinkElement.prototype, 'import', { get: function () { return null; }, configurable: true }); } catch (e) {}
    }

    var registry = {}, waiters = {};
    function disconnectTree(root) {
        var list = [root].concat(Array.prototype.slice.call(root.querySelectorAll ? root.querySelectorAll('*') : []));
        for (var i = 0; i < list.length; i++) if (list[i].__brUpgraded && list[i].disconnectedCallback) try { list[i].disconnectedCallback(); } catch (e) {}
    }
    function upgradeElement(el) {
        var name = el.tagName ? el.tagName.toLowerCase() : '';
        var isAttr = el.getAttribute && el.getAttribute('is');
        var ctor = registry[name] || (isAttr && registry[isAttr.toLowerCase()]);
        if (!ctor || el.__brUpgraded) return;
        el.__brUpgraded = true;
        try { if (Object.setPrototypeOf) Object.setPrototypeOf(el, ctor.prototype); else el.__proto__ = ctor.prototype; } catch (e) {}
        try { ctor.call(el); } catch (e2) {}   // ES5 constructors initialise fields; classes cannot be called and are skipped
        try {
            var observed = ctor.observedAttributes || [];
            for (var i = 0; i < observed.length; i++) if (el.hasAttribute(observed[i]) && el.attributeChangedCallback) el.attributeChangedCallback(observed[i], null, el.getAttribute(observed[i]), null);
        } catch (e3) {}
        try { if (el.connectedCallback && document.documentElement.contains(el)) el.connectedCallback(); } catch (e4) {}
    }
    function upgradeTree(root) {
        if (!root || (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11)) return;
        if (root.nodeType === 1) upgradeElement(root);
        var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (var i = 0; i < all.length; i++) {
            var t = all[i].tagName.toLowerCase();
            if (t.indexOf('-') >= 0 || all[i].hasAttribute('is')) upgradeElement(all[i]);
        }
    }
    if (!window.customElements || window.customElements.__brStub) {
        var registryAPI = {
            __brStub: false,
            define: function (name, ctor) {
                name = String(name).toLowerCase();
                if (registry[name]) throw domException('NotSupportedError', 'custom element already defined: ' + name);
                registry[name] = ctor;
                upgradeTree(document);
                if (waiters[name]) { var w = waiters[name]; delete waiters[name]; for (var i = 0; i < w.length; i++) w[i](ctor); }
            },
            get: function (name) { return registry[String(name).toLowerCase()]; },
            getName: function (ctor) { for (var k in registry) if (registry[k] === ctor) return k; return null; },
            whenDefined: function (name) {
                name = String(name).toLowerCase();
                if (registry[name]) return resolved(registry[name]);
                if (!P) return null;
                return new P(function (res) { (waiters[name] = waiters[name] || []).push(res); });
            },
            upgrade: function (root) { upgradeTree(root); }
        };
        try { window.customElements = registryAPI; } catch (e) { try { Object.defineProperty(window, 'customElements', { value: registryAPI, configurable: true }); } catch (e2) {} }
        observeAdded(function (el) { if (Object.keys(registry).length) upgradeTree(el); });
        window.CustomElementRegistry = function CustomElementRegistry() {};
        // ES5 subclasses call HTMLElement.call(this): make the base constructor callable
        (function () {
            var NativeHTMLElement = window.HTMLElement;
            if (!NativeHTMLElement) return;
            var callable = false;
            try { NativeHTMLElement.call(document.createElement('div')); callable = true; } catch (e) {}
            if (callable) return;
            var Wrapped = function HTMLElement() { return this; };
            Wrapped.prototype = NativeHTMLElement.prototype;
            try { Object.defineProperty(Wrapped, 'name', { value: 'HTMLElement' }); } catch (e2) {}
            window.HTMLElement = Wrapped;
        })();
    }

    // ---- <dialog> (dialog-polyfill in the bundle, registered automatically)
    if (window.dialogPolyfill && !('showModal' in document.createElement('dialog'))) {
        var dp = window.dialogPolyfill;
        addStyle('dialog{position:absolute;left:0;right:0;width:-webkit-fit-content;width:fit-content;height:-webkit-fit-content;height:fit-content;margin:auto;border:solid;padding:1em;background:white;color:black;display:block}' +
                 'dialog:not([open]){display:none}dialog+.backdrop{position:fixed;top:0;right:0;bottom:0;left:0;background:rgba(0,0,0,0.1)}' +
                 '._dialog_overlay{position:fixed;top:0;right:0;bottom:0;left:0}dialog.fixed{position:fixed;top:50%;-webkit-transform:translate(0,-50%);transform:translate(0,-50%)}');
        // :modal (cssfix rewrites it to .br-modal) follows showModal()/close()
        var registerDialog = function (el) {
            try { dp.registerDialog(el); } catch (e) { return; }
            if (el.__brModalWrapped || typeof el.showModal !== 'function') return;
            el.__brModalWrapped = true;
            var origShowModal = el.showModal, origClose = el.close;
            el.showModal = function () { var r = origShowModal.apply(this, arguments); setStateClass(this, 'br-modal', true); return r; };
            el.close = function () { setStateClass(this, 'br-modal', false); return origClose.apply(this, arguments); };
        };
        var registerDialogs = function registerDialogs(root) {
            if (root.nodeType === 1 && root.tagName === 'DIALOG') registerDialog(root);
            var list = root.querySelectorAll ? root.querySelectorAll('dialog') : [];
            for (var i = 0; i < list.length; i++) registerDialog(list[i]);
        };
        var origCreateElement = document.createElement;
        document.createElement = function (name) {
            var el = origCreateElement.apply(document, arguments);
            if (String(name).toLowerCase() === 'dialog') registerDialog(el);
            return el;
        };
        onReady(function () { registerDialogs(document); });
        observeAdded(registerDialogs);
        if (!window.HTMLDialogElement) window.HTMLDialogElement = function HTMLDialogElement() {};
    }

    // ---- Responsive images: picturefill does the work, the DOM properties make feature checks pass
    var IMGp = window.HTMLImageElement && window.HTMLImageElement.prototype;
    if (!window.HTMLPictureElement) window.HTMLPictureElement = function HTMLPictureElement() {};
    if (IMGp) {
        defineAttrProp(IMGp, 'srcset');
        defineAttrProp(IMGp, 'sizes');
        defineAttrProp(IMGp, 'loading');
        defineAttrProp(IMGp, 'decoding');
        if (!('currentSrc' in IMGp)) try { Object.defineProperty(IMGp, 'currentSrc', { get: function () { return this.src; }, configurable: true }); } catch (e) {}
        if (!IMGp.decode) IMGp.decode = function () {
            var img = this;
            if (!P) return null;
            return new P(function (res, rej) {
                if (img.complete) return res();
                img.addEventListener('load', function () { res(); }, false);
                img.addEventListener('error', function () { rej(domException('EncodingError', 'The image could not be decoded')); }, false);
            });
        };
    }
    if (window.HTMLSourceElement) { defineAttrProp(window.HTMLSourceElement.prototype, 'srcset'); defineAttrProp(window.HTMLSourceElement.prototype, 'sizes'); }
    function runResponsiveImages() {
        try { if (window.picturefill) window.picturefill(); } catch (e) {}
        try { if (window.objectFitImages) window.objectFitImages(null, { watchMQ: false }); } catch (e2) {}
    }
    onReady(runResponsiveImages);
    onSettled(runResponsiveImages);

    // ---- Streams (single-process, promise based; fetch responses expose a body stream over the buffered bytes)
    if (!window.ReadableStream && P) {
        var ReadableStream = function ReadableStream(source) {
            var self = this;
            self.locked = false;
            self.__queue = [];
            self.__closed = false;
            self.__error = null;
            self.__waiters = [];
            self.__source = source || {};
            self.__controller = {
                desiredSize: 1,
                enqueue: function (chunk) { if (self.__closed) throw new TypeError('The stream is closed'); self.__queue.push(chunk); self.__flush(); },
                close: function () { self.__closed = true; self.__flush(); },
                error: function (e) { self.__error = e || new Error('stream error'); self.__closed = true; self.__flush(); }
            };
            try {
                if (self.__source.start) { var r = self.__source.start(self.__controller); if (r && r.then) r.then(null, self.__controller.error); }
            } catch (e) { self.__controller.error(e); }
        };
        ReadableStream.prototype.__flush = function () {
            while (this.__waiters.length && (this.__queue.length || this.__closed)) {
                var w = this.__waiters.shift();
                if (this.__queue.length) w.resolve({ value: this.__queue.shift(), done: false });
                else if (this.__error) w.reject(this.__error);
                else w.resolve({ value: undefined, done: true });
            }
        };
        ReadableStream.prototype.__pull = function () {
            var self = this;
            if (self.__closed || !self.__source.pull || self.__pulling) return;
            self.__pulling = true;
            try {
                var r = self.__source.pull(self.__controller);
                if (r && r.then) r.then(function () { self.__pulling = false; if (self.__waiters.length) self.__pull(); }, function (e) { self.__pulling = false; self.__controller.error(e); });
                else { self.__pulling = false; if (self.__waiters.length && !self.__queue.length) setTimeout(function () { self.__pull(); }, 0); }
            } catch (e) { self.__pulling = false; self.__controller.error(e); }
        };
        ReadableStream.prototype.getReader = function () {
            var self = this;
            if (self.locked) throw new TypeError('The stream is locked');
            self.locked = true;
            return {
                read: function () {
                    return new P(function (resolve, reject) {
                        self.__waiters.push({ resolve: resolve, reject: reject });
                        self.__flush();
                        if (self.__waiters.length) self.__pull();
                    });
                },
                cancel: function (reason) { self.locked = false; return self.cancel(reason); },
                releaseLock: function () { self.locked = false; },
                closed: new P(function (resolve) { self.__onClosed = resolve; })
            };
        };
        ReadableStream.prototype.cancel = function (reason) {
            this.__closed = true;
            this.__queue = [];
            try { if (this.__source.cancel) this.__source.cancel(reason); } catch (e) {}
            this.__flush();
            if (this.__onClosed) this.__onClosed();
            return resolved();
        };
        ReadableStream.prototype.tee = function () { return [this, this]; };
        ReadableStream.prototype.pipeTo = function (dest) {
            var reader = this.getReader(), writer = dest.getWriter();
            function step() { return reader.read().then(function (r) { if (r.done) return writer.close(); return P.resolve(writer.write(r.value)).then(step); }); }
            return step();
        };
        ReadableStream.prototype.pipeThrough = function (pair) { this.pipeTo(pair.writable); return pair.readable; };
        window.ReadableStream = ReadableStream;
        window.ReadableStreamDefaultReader = function ReadableStreamDefaultReader() {};
        var WritableStream = function WritableStream(sink) {
            this.locked = false;
            this.__sink = sink || {};
            try { if (this.__sink.start) this.__sink.start({ error: noop }); } catch (e) {}
        };
        WritableStream.prototype.getWriter = function () {
            var self = this;
            self.locked = true;
            return {
                write: function (chunk) { try { var r = self.__sink.write && self.__sink.write(chunk, { error: noop }); return r && r.then ? r : resolved(); } catch (e) { return P.reject(e); } },
                close: function () { try { var r = self.__sink.close && self.__sink.close(); return r && r.then ? r : resolved(); } catch (e) { return P.reject(e); } },
                abort: function (reason) { try { if (self.__sink.abort) self.__sink.abort(reason); } catch (e) {} return resolved(); },
                releaseLock: function () { self.locked = false; },
                ready: resolved(), closed: resolved(), desiredSize: 1
            };
        };
        WritableStream.prototype.abort = function () { return resolved(); };
        WritableStream.prototype.close = function () { return resolved(); };
        window.WritableStream = WritableStream;
        window.WritableStreamDefaultWriter = function WritableStreamDefaultWriter() {};
        var TransformStream = function TransformStream(transformer) {
            transformer = transformer || {};
            var readableController = null;
            this.readable = new ReadableStream({ start: function (c) { readableController = c; } });
            var tc = { enqueue: function (chunk) { readableController.enqueue(chunk); }, error: function (e) { readableController.error(e); }, terminate: function () { readableController.close(); }, desiredSize: 1 };
            this.writable = new WritableStream({
                write: function (chunk) { if (transformer.transform) return transformer.transform(chunk, tc); tc.enqueue(chunk); },
                close: function () { var r = transformer.flush ? transformer.flush(tc) : null; return P.resolve(r).then(function () { readableController.close(); }); },
                abort: function (reason) { readableController.error(reason); }
            });
        };
        window.TransformStream = TransformStream;
        window.ByteLengthQueuingStrategy = function ByteLengthQueuingStrategy(o) { this.highWaterMark = o && o.highWaterMark; this.size = function (c) { return c.byteLength; }; };
        window.CountQueuingStrategy = function CountQueuingStrategy(o) { this.highWaterMark = o && o.highWaterMark; this.size = function () { return 1; }; };
        window.TextDecoderStream = function TextDecoderStream(label) {
            var dec = new TextDecoder(label);
            var t = new TransformStream({ transform: function (chunk, c) { c.enqueue(dec.decode(chunk)); } });
            this.readable = t.readable; this.writable = t.writable; this.encoding = dec.encoding;
        };
        window.TextEncoderStream = function TextEncoderStream() {
            var enc = new TextEncoder();
            var t = new TransformStream({ transform: function (chunk, c) { c.enqueue(enc.encode(String(chunk))); } });
            this.readable = t.readable; this.writable = t.writable; this.encoding = 'utf-8';
        };
        if (window.Response && window.Response.prototype && !('body' in window.Response.prototype)) {
            try {
                Object.defineProperty(window.Response.prototype, 'body', { get: function () {
                    var self = this;
                    if (self.__brBody) return self.__brBody;
                    if (!self.arrayBuffer) return null;
                    self.__brBody = new ReadableStream({ start: function (c) {
                        var p;
                        try { p = self.arrayBuffer(); } catch (e) { c.error(e); return; }
                        p.then(function (buf) { c.enqueue(new Uint8Array(buf)); c.close(); }, function (e) { c.error(e); });
                    } });
                    return self.__brBody;
                }, configurable: true });
            } catch (e) {}
        }
    }

    // ---- WebRTC, media capture and recording: present, but every attempt fails cleanly
    if (!window.RTCPeerConnection && !window.webkitRTCPeerConnection) {
        var rtcUnsupported = rejectWith('NotSupportedError', 'WebRTC is not available on this device');
        var RTCPeerConnection = function RTCPeerConnection(config) {
            this.localDescription = null; this.remoteDescription = null; this.currentLocalDescription = null; this.currentRemoteDescription = null;
            this.signalingState = 'stable'; this.iceConnectionState = 'new'; this.iceGatheringState = 'new'; this.connectionState = 'new';
            this.canTrickleIceCandidates = null; this.sctp = null; this.__config = config || {};
            this.__l = {};
        };
        RTCPeerConnection.prototype = {
            createOffer: rtcUnsupported, createAnswer: rtcUnsupported, setLocalDescription: rtcUnsupported, setRemoteDescription: rtcUnsupported, addIceCandidate: rtcUnsupported,
            createDataChannel: function (label) { return { label: label, readyState: 'closed', bufferedAmount: 0, ordered: true, binaryType: 'blob', send: function () { throw domException('InvalidStateError', 'RTCDataChannel is closed'); }, close: noop, addEventListener: noop, removeEventListener: noop, dispatchEvent: function () { return true; } }; },
            addTrack: function (track) { return { track: track, replaceTrack: rtcUnsupported, getParameters: function () { return {}; }, setParameters: rtcUnsupported, getStats: function () { return resolved(new Map()); } }; },
            removeTrack: noop, addTransceiver: function () { return {}; }, getSenders: function () { return []; }, getReceivers: function () { return []; }, getTransceivers: function () { return []; },
            addStream: noop, removeStream: noop, getLocalStreams: function () { return []; }, getRemoteStreams: function () { return []; },
            getStats: function () { return resolved(new Map()); }, getConfiguration: function () { return this.__config; }, setConfiguration: noop, restartIce: noop, close: noop,
            addEventListener: function (t, f) { (this.__l[t] = this.__l[t] || []).push(f); }, removeEventListener: function (t, f) { var l = this.__l[t] || []; var i = l.indexOf(f); if (i >= 0) l.splice(i, 1); }, dispatchEvent: function () { return true; }
        };
        RTCPeerConnection.generateCertificate = rtcUnsupported;
        window.RTCPeerConnection = window.webkitRTCPeerConnection = window.mozRTCPeerConnection = RTCPeerConnection;
        window.RTCSessionDescription = function RTCSessionDescription(init) { this.type = init && init.type; this.sdp = (init && init.sdp) || ''; this.toJSON = function () { return { type: this.type, sdp: this.sdp }; }; };
        window.RTCIceCandidate = function RTCIceCandidate(init) { init = init || {}; this.candidate = init.candidate || ''; this.sdpMid = init.sdpMid || null; this.sdpMLineIndex = init.sdpMLineIndex === undefined ? null : init.sdpMLineIndex; this.toJSON = function () { return { candidate: this.candidate, sdpMid: this.sdpMid, sdpMLineIndex: this.sdpMLineIndex }; }; };
        var rtcNames = ['RTCDataChannel', 'RTCIceGatherer', 'RTCIceTransport', 'RTCDtlsTransport', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCSctpTransport', 'RTCCertificate', 'RTCPeerConnectionIceEvent', 'RTCDataChannelEvent', 'RTCTrackEvent', 'RTCStatsReport', 'RTCError'];
        for (var rn = 0; rn < rtcNames.length; rn++) if (!window[rtcNames[rn]]) window[rtcNames[rn]] = (function (n) { var f = function () {}; try { Object.defineProperty(f, 'name', { value: n }); } catch (e) {} return f; })(rtcNames[rn]);
        window.RTCIceGatherer.prototype.getLocalCandidates = function () { return []; };
    }
    if (!window.MediaStream) {
        window.MediaStream = window.webkitMediaStream = function MediaStream() { this.id = 'ms-' + Math.random().toString(36).slice(2); this.active = false; };
        window.MediaStream.prototype = { getTracks: function () { return []; }, getAudioTracks: function () { return []; }, getVideoTracks: function () { return []; }, getTrackById: function () { return null; }, addTrack: noop, removeTrack: noop, clone: function () { return new window.MediaStream(); }, addEventListener: noop, removeEventListener: noop, dispatchEvent: function () { return true; } };
        window.MediaStreamTrack = function MediaStreamTrack() { this.readyState = 'ended'; this.enabled = false; this.muted = true; this.kind = ''; this.label = ''; this.id = ''; };
        window.MediaStreamTrack.prototype = { stop: noop, clone: function () { return new window.MediaStreamTrack(); }, getSettings: function () { return {}; }, getConstraints: function () { return {}; }, getCapabilities: function () { return {}; }, applyConstraints: function () { return resolved(); }, addEventListener: noop, removeEventListener: noop };
    }
    if (!window.MediaRecorder) {
        window.MediaRecorder = function MediaRecorder() { throw domException('NotSupportedError', 'MediaRecorder is not available on this device'); };
        window.MediaRecorder.isTypeSupported = function () { return false; };
    }
    if (navigator.mediaDevices) {
        if (!navigator.mediaDevices.getDisplayMedia) navigator.mediaDevices.getDisplayMedia = rejectWith('NotAllowedError', 'Screen capture is not available');
        if (!navigator.mediaDevices.getSupportedConstraints) navigator.mediaDevices.getSupportedConstraints = function () { return {}; };
        if (!navigator.mediaDevices.addEventListener) { navigator.mediaDevices.addEventListener = noop; navigator.mediaDevices.removeEventListener = noop; }
    }
    if (!navigator.getUserMedia) {
        navigator.getUserMedia = navigator.webkitGetUserMedia = function (constraints, ok, err) { setTimeout(function () { if (err) err(domException('NotAllowedError', 'Camera and microphone are not available')); }, 0); };
    }
    if (!window.ImageCapture) window.ImageCapture = function ImageCapture() { throw domException('NotSupportedError', 'ImageCapture is not available'); };

    // ---- Speech
    if (!window.speechSynthesis) {
        window.speechSynthesis = { speak: function (u) { setTimeout(function () { if (u && u.onerror) u.onerror({ error: 'synthesis-unavailable', utterance: u }); }, 0); }, cancel: noop, pause: noop, resume: noop, getVoices: function () { return []; },
                                   speaking: false, pending: false, paused: false, onvoiceschanged: null, addEventListener: noop, removeEventListener: noop, dispatchEvent: function () { return true; } };
        window.SpeechSynthesisUtterance = function SpeechSynthesisUtterance(text) { this.text = text || ''; this.lang = ''; this.voice = null; this.volume = 1; this.rate = 1; this.pitch = 1; this.onstart = this.onend = this.onerror = this.onpause = this.onresume = this.onmark = this.onboundary = null; this.addEventListener = noop; this.removeEventListener = noop; };
        window.SpeechSynthesisVoice = function SpeechSynthesisVoice() {};
        window.SpeechSynthesisEvent = function SpeechSynthesisEvent() {};
    }
    if (!window.SpeechRecognition && !window.webkitSpeechRecognition) {
        var SpeechRecognition = function SpeechRecognition() { this.continuous = false; this.interimResults = false; this.lang = ''; this.maxAlternatives = 1; this.onresult = this.onerror = this.onend = this.onstart = this.onnomatch = null; };
        SpeechRecognition.prototype.start = function () {
            var self = this;
            setTimeout(function () { if (self.onstart) self.onstart({}); if (self.onerror) self.onerror({ error: 'not-allowed', message: 'Speech recognition is not available' }); if (self.onend) self.onend({}); }, 0);
        };
        SpeechRecognition.prototype.stop = SpeechRecognition.prototype.abort = noop;
        SpeechRecognition.prototype.addEventListener = function (t, f) { this['on' + t] = f; };
        SpeechRecognition.prototype.removeEventListener = function (t) { this['on' + t] = null; };
        window.SpeechRecognition = window.webkitSpeechRecognition = SpeechRecognition;
        window.SpeechGrammarList = window.webkitSpeechGrammarList = function SpeechGrammarList() { this.length = 0; this.addFromString = noop; this.addFromURI = noop; };
        window.SpeechRecognitionEvent = window.webkitSpeechRecognitionEvent = function SpeechRecognitionEvent() {};
    }

    // ---- crypto.subtle: real SHA-1 / SHA-256 digests, everything else unavailable
    function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
    function rotl(x, n) { return (x << n) | (x >>> (32 - n)); }
    function padMessage(bytes) {
        var l = bytes.length, padLen = ((l + 9 + 63) >> 6) << 6, msg = new Uint8Array(padLen);
        msg.set(bytes);
        msg[l] = 0x80;
        var bits = l * 8, hi = Math.floor(bits / 4294967296), lo = bits >>> 0;
        msg[padLen - 8] = (hi >>> 24) & 255; msg[padLen - 7] = (hi >>> 16) & 255; msg[padLen - 6] = (hi >>> 8) & 255; msg[padLen - 5] = hi & 255;
        msg[padLen - 4] = (lo >>> 24) & 255; msg[padLen - 3] = (lo >>> 16) & 255; msg[padLen - 2] = (lo >>> 8) & 255; msg[padLen - 1] = lo & 255;
        return msg;
    }
    function readWords(msg, off, w, n) { for (var i = 0; i < n; i++) w[i] = (msg[off + i * 4] << 24) | (msg[off + i * 4 + 1] << 16) | (msg[off + i * 4 + 2] << 8) | msg[off + i * 4 + 3]; }
    function wordsToBytes(H) { var out = new Uint8Array(H.length * 4); for (var i = 0; i < H.length; i++) { out[i * 4] = H[i] >>> 24; out[i * 4 + 1] = (H[i] >>> 16) & 255; out[i * 4 + 2] = (H[i] >>> 8) & 255; out[i * 4 + 3] = H[i] & 255; } return out; }
    var K256 = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
                0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
                0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
                0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
    function sha256(bytes) {
        var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
        var msg = padMessage(bytes), w = new Array(64), i;
        for (var off = 0; off < msg.length; off += 64) {
            readWords(msg, off, w, 16);
            for (i = 16; i < 64; i++) {
                var s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3), s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
                w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
            }
            var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
            for (i = 0; i < 64; i++) {
                var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25), ch = (e & f) ^ (~e & g), t1 = (h + S1 + ch + K256[i] + w[i]) | 0;
                var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22), maj = (a & b) ^ (a & c) ^ (b & c), t2 = (S0 + maj) | 0;
                h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
            }
            H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
            H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
        }
        return wordsToBytes(H);
    }
    function sha1(bytes) {
        var H = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
        var msg = padMessage(bytes), w = new Array(80), i;
        for (var off = 0; off < msg.length; off += 64) {
            readWords(msg, off, w, 16);
            for (i = 16; i < 80; i++) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
            var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4];
            for (i = 0; i < 80; i++) {
                var f, k;
                if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
                else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
                else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
                else { f = b ^ c ^ d; k = 0xCA62C1D6; }
                var t = (rotl(a, 5) + f + e + k + w[i]) | 0;
                e = d; d = c; c = rotl(b, 30); b = a; a = t;
            }
            H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0; H[4] = (H[4] + e) | 0;
        }
        return wordsToBytes(H);
    }
    function toBytes(data) {
        if (data instanceof ArrayBuffer) return new Uint8Array(data);
        if (data && data.buffer instanceof ArrayBuffer) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
        if (typeof data === 'string') return new TextEncoder().encode(data);
        return new Uint8Array(0);
    }
    // Blob URLs: core-js replaces URL and the old engine only has webkitURL.createObjectURL
    if (window.URL && !window.URL.createObjectURL && window.webkitURL && window.webkitURL.createObjectURL) {
        var nativeURLObject = window.webkitURL;
        window.URL.createObjectURL = function (blob) { return nativeURLObject.createObjectURL(blob); };
        window.URL.revokeObjectURL = function (url) { return nativeURLObject.revokeObjectURL(url); };
    }
    if (window.crypto && !window.crypto.subtle && !window.crypto.webkitSubtle) {
        var cryptoUnsupported = rejectWith('NotSupportedError', 'This operation is not available in this browser');
        var subtle = {
            digest: function (algorithm, data) {
                if (!P) return null;
                var name = String(typeof algorithm === 'string' ? algorithm : (algorithm && algorithm.name) || '').toUpperCase().replace('-', '');
                try {
                    var bytes = toBytes(data);
                    if (name === 'SHA256') return P.resolve(sha256(bytes).buffer);
                    if (name === 'SHA1') return P.resolve(sha1(bytes).buffer);
                } catch (e) { return P.reject(e); }
                return cryptoUnsupported();
            },
            encrypt: cryptoUnsupported, decrypt: cryptoUnsupported, sign: cryptoUnsupported, verify: cryptoUnsupported, generateKey: cryptoUnsupported,
            deriveKey: cryptoUnsupported, deriveBits: cryptoUnsupported, importKey: cryptoUnsupported, exportKey: cryptoUnsupported, wrapKey: cryptoUnsupported, unwrapKey: cryptoUnsupported
        };
        // Expandos on the Crypto wrapper vanish when the old engine garbage-collects and recreates the wrapper,
        // so the property lives on the prototype (and the wrapper is pinned below just in case).
        try { Object.defineProperty(Object.getPrototypeOf(window.crypto), 'subtle', { get: function () { return subtle; }, configurable: true }); } catch (e4) {}
        if (!window.crypto.subtle) try { Object.defineProperty(window.crypto, 'subtle', { value: subtle, configurable: true }); } catch (e) {}
        if (!window.crypto.subtle) {
            // the native Crypto object refuses new properties: replace it with a wrapper
            var nativeCrypto = window.crypto;
            var cryptoWrapper = {
                subtle: subtle,
                getRandomValues: function (arr) { if (nativeCrypto.getRandomValues) return nativeCrypto.getRandomValues(arr); for (var i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256); return arr; },
                randomUUID: nativeCrypto.randomUUID ? function () { return nativeCrypto.randomUUID(); } : function () { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }); }
            };
            try { Object.defineProperty(window, 'crypto', { value: cryptoWrapper, configurable: true, writable: true }); } catch (e2) { try { window.crypto = cryptoWrapper; } catch (e3) {} }
        }
        window.SubtleCrypto = function SubtleCrypto() {};
        window.CryptoKey = function CryptoKey() {};
        window.Crypto = window.Crypto || function Crypto() {};
    }

    // ---- Credentials, authentication, payments
    if (!navigator.credentials) {
        var credUnsupported = rejectWith('NotSupportedError', 'Credential management is not available');
        navigator.credentials = { get: credUnsupported, create: credUnsupported, store: credUnsupported, preventSilentAccess: function () { return resolved(); } };
        window.Credential = function Credential() {};
        window.PasswordCredential = function PasswordCredential(init) { init = init || {}; this.type = 'password'; this.id = init.id || ''; this.password = init.password || ''; this.name = init.name || ''; this.iconURL = init.iconURL || ''; };
        window.FederatedCredential = function FederatedCredential(init) { init = init || {}; this.type = 'federated'; this.id = init.id || ''; this.provider = init.provider || ''; this.name = init.name || ''; };
        window.CredentialsContainer = function CredentialsContainer() {};
    }
    if (!window.PublicKeyCredential) {
        window.PublicKeyCredential = function PublicKeyCredential() {};
        window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return resolved(false); };
        window.PublicKeyCredential.isConditionalMediationAvailable = function () { return resolved(false); };
        window.AuthenticatorResponse = function AuthenticatorResponse() {};
    }
    if (!window.PaymentRequest) {
        window.PaymentRequest = function PaymentRequest(methods, details) {
            this.id = (details && details.id) || 'pr-' + Math.random().toString(36).slice(2);
            this.shippingAddress = null; this.shippingOption = null; this.shippingType = null;
            this.onshippingaddresschange = this.onshippingoptionchange = this.onpaymentmethodchange = null;
        };
        window.PaymentRequest.prototype = {
            canMakePayment: function () { return resolved(false); },
            hasEnrolledInstrument: function () { return resolved(false); },
            show: rejectWith('NotSupportedError', 'Web Payments are not available in this browser'),
            abort: function () { return resolved(); },
            addEventListener: noop, removeEventListener: noop, dispatchEvent: function () { return true; }
        };
        window.PaymentResponse = function PaymentResponse() {};
        window.PaymentAddress = function PaymentAddress() {};
    }

    // ---- Media: Web Audio alias, DRM, tracks, subtitles
    if (!window.AudioContext && window.webkitAudioContext) {
        window.AudioContext = window.webkitAudioContext;
        if (!window.OfflineAudioContext && window.webkitOfflineAudioContext) window.OfflineAudioContext = window.webkitOfflineAudioContext;
    }
    if (window.AudioContext && !window.AudioContext.prototype.createGain && window.AudioContext.prototype.createGainNode) {
        var ACp = window.AudioContext.prototype;
        ACp.createGain = ACp.createGainNode;
        ACp.createDelay = ACp.createDelayNode;
        ACp.createScriptProcessor = ACp.createJavaScriptNode;
    }
    if (window.AudioContext && window.AudioContext.prototype && !window.AudioContext.prototype.resume) {
        window.AudioContext.prototype.resume = function () { return resolved(); };
        window.AudioContext.prototype.suspend = function () { return resolved(); };
        window.AudioContext.prototype.close = function () { return resolved(); };
    }
    if (!navigator.requestMediaKeySystemAccess) navigator.requestMediaKeySystemAccess = rejectWith('NotSupportedError', 'Encrypted media is not available');
    if (!window.MediaKeys) { window.MediaKeys = function MediaKeys() {}; window.MediaKeySystemAccess = function MediaKeySystemAccess() {}; }
    var MEp = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
    if (MEp) {
        var trackList = function trackList() { return { length: 0, getTrackById: function () { return null; }, addEventListener: noop, removeEventListener: noop, onchange: null, onaddtrack: null, onremovetrack: null }; };
        if (!('audioTracks' in MEp)) try { Object.defineProperty(MEp, 'audioTracks', { get: function () { return this.__brAudioTracks || (this.__brAudioTracks = trackList()); }, configurable: true }); } catch (e) {}
        if (!('videoTracks' in MEp)) try { Object.defineProperty(MEp, 'videoTracks', { get: function () { return this.__brVideoTracks || (this.__brVideoTracks = trackList()); }, configurable: true }); } catch (e2) {}
        if (!MEp.setSinkId) MEp.setSinkId = rejectWith('NotSupportedError', 'Audio output selection is not available');
        if (!MEp.captureStream) MEp.captureStream = MEp.mozCaptureStream = function () { return new window.MediaStream(); };
        if (!('playsInline' in MEp)) defineBoolAttrProp(MEp, 'playsInline');
        if (!MEp.setMediaKeys) MEp.setMediaKeys = rejectWith('NotSupportedError', 'Encrypted media is not available');
        // play() returns a promise in modern browsers; many players rely on that
        var origPlay = MEp.play;
        if (origPlay) {
            try {
                var probe = document.createElement('audio');
                if (!(probe.play() && typeof probe.play().then === 'function')) {
                    MEp.play = function () { var r; try { r = origPlay.apply(this, arguments); } catch (e) { return P ? P.reject(e) : undefined; } return (r && r.then) ? r : resolved(); };
                }
            } catch (e3) {}
        }
    }
    if (!window.HTMLTrackElement) window.HTMLTrackElement = function HTMLTrackElement() {};
    if (!window.TextTrack) { window.TextTrack = function TextTrack() {}; window.TextTrackCue = window.VTTCue = function VTTCue(start, end, text) { this.startTime = start; this.endTime = end; this.text = text; }; }
    if (!window.MediaSession && !navigator.mediaSession) navigator.mediaSession = { metadata: null, playbackState: 'none', setActionHandler: noop, setPositionState: noop };
    if (!window.MediaMetadata) window.MediaMetadata = function MediaMetadata(init) { init = init || {}; this.title = init.title || ''; this.artist = init.artist || ''; this.album = init.album || ''; this.artwork = init.artwork || []; };
    if (!window.Audio) window.Audio = function Audio(src) { var a = document.createElement('audio'); if (src) a.src = src; return a; };

    // ---- Canvas helpers
    var C2D = window.CanvasRenderingContext2D && window.CanvasRenderingContext2D.prototype;
    if (C2D) {
        if (!C2D.ellipse) C2D.ellipse = function (x, y, rx, ry, rotation, start, end, ccw) {
            this.save();
            this.translate(x, y);
            this.rotate(rotation || 0);
            this.scale(rx, ry);
            this.arc(0, 0, 1, start, end, !!ccw);
            this.restore();
        };
        if (!C2D.setLineDash) {
            if ('webkitLineDash' in C2D) {
                C2D.setLineDash = function (segments) { this.webkitLineDash = segments; };
                C2D.getLineDash = function () { return this.webkitLineDash || []; };
                try { Object.defineProperty(C2D, 'lineDashOffset', { get: function () { return this.webkitLineDashOffset; }, set: function (v) { this.webkitLineDashOffset = v; }, configurable: true }); } catch (e) {}
            } else {
                C2D.setLineDash = noop;
                C2D.getLineDash = function () { return []; };
            }
        }
        if (!C2D.drawFocusIfNeeded) C2D.drawFocusIfNeeded = noop;
        if (!C2D.isPointInStroke) C2D.isPointInStroke = function () { return false; };
        if (!C2D.addHitRegion) { C2D.addHitRegion = noop; C2D.removeHitRegion = noop; C2D.clearHitRegions = noop; }
        if (!C2D.resetTransform) C2D.resetTransform = function () { this.setTransform(1, 0, 0, 1, 0, 0); };
        if (!('imageSmoothingEnabled' in C2D) && ('webkitImageSmoothingEnabled' in C2D)) {
            try { Object.defineProperty(C2D, 'imageSmoothingEnabled', { get: function () { return this.webkitImageSmoothingEnabled; }, set: function (v) { this.webkitImageSmoothingEnabled = v; }, configurable: true }); } catch (e) {}
        }
        if (!('filter' in C2D)) try { Object.defineProperty(C2D, 'filter', { get: function () { return this.__brFilter || 'none'; }, set: function (v) { this.__brFilter = v; }, configurable: true }); } catch (e2) {}
        if (!window.Path2D) {
            var Path2D = function Path2D(init) {
                this.__ops = [];
                if (init instanceof Path2D) this.__ops = init.__ops.slice();
            };
            var pathMethods = ['moveTo', 'lineTo', 'bezierCurveTo', 'quadraticCurveTo', 'arc', 'arcTo', 'ellipse', 'rect', 'closePath'];
            for (var pm = 0; pm < pathMethods.length; pm++) (function (m) { Path2D.prototype[m] = function () { this.__ops.push([m, Array.prototype.slice.call(arguments)]); }; })(pathMethods[pm]);
            Path2D.prototype.addPath = function (p) { if (p && p.__ops) this.__ops = this.__ops.concat(p.__ops); };
            Path2D.prototype.__replay = function (ctx) { ctx.beginPath(); for (var i = 0; i < this.__ops.length; i++) ctx[this.__ops[i][0]].apply(ctx, this.__ops[i][1]); };
            var wrapPathOp = function (name) {
                var orig = C2D[name];
                if (!orig) return;
                C2D[name] = function (a, b, c, d) {
                    if (a instanceof Path2D) { a.__replay(this); return name === 'isPointInPath' ? orig.call(this, b, c, d) : orig.call(this, b); }
                    return orig.apply(this, arguments);
                };
            };
            wrapPathOp('fill'); wrapPathOp('stroke'); wrapPathOp('clip'); wrapPathOp('isPointInPath');
            window.Path2D = Path2D;
        }
    }
    var HCp = window.HTMLCanvasElement && window.HTMLCanvasElement.prototype;
    if (HCp && !HCp.toBlob) HCp.toBlob = function (callback, type, quality) {
        var canvas = this;
        setTimeout(function () {
            var dataURL = canvas.toDataURL(type, quality);
            var parts = dataURL.split(','), mime = /data:([^;]+)/.exec(parts[0]), bin = atob(parts[1]), arr = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
            callback(new Blob([arr], { type: mime ? mime[1] : 'image/png' }));
        }, 0);
    };
    if (HCp && !HCp.captureStream) HCp.captureStream = function () { return new window.MediaStream(); };
    if (HCp && !HCp.transferControlToOffscreen) HCp.transferControlToOffscreen = function () { return this; };
    if (!window.OffscreenCanvas) {
        window.OffscreenCanvas = function OffscreenCanvas(width, height) {
            var c = document.createElement('canvas');
            c.width = width; c.height = height;
            c.convertToBlob = function (opts) { return new P(function (res) { c.toBlob(res, opts && opts.type, opts && opts.quality); }); };
            c.transferToImageBitmap = function () { return c; };
            return c;
        };
    }
    // aspect-ratio: cssfix stores the ratio in "counter-reset: br-aspect W br-aspect-h H"; media elements and
    // empty boxes with such a rule get their height from their width (and again when the viewport changes)
    var aspectTimer = null, aspectElements = [], containerElements = [], markerHooks = [];
    var onMarkers = function (fn) { markerHooks.push(fn); };   // fn(list of {el, cr}) after every marker scan
    var applyAspectRatios = function () {
        try {
            var all = document.getElementsByTagName('*'), found = [], containers = [], marked = [];
            for (var i = 0; i < all.length && i < 4000; i++) {
                var el = all[i];
                var cr = getComputedStyle(el).counterReset || '';
                if (cr.indexOf('br-') < 0) { if (el.__brAspect) { el.style.height = ''; el.__brAspect = false; } continue; }
                marked.push({ el: el, cr: cr });
                if (cr.indexOf('br-c') >= 0) {   // container-type / container-name markers (see the manifest block)
                    var names = [], cn = /br-cn-([\w-]+)/g, cm;
                    while ((cm = cn.exec(cr)) !== null) names.push(cm[1]);
                    if (cr.indexOf('br-container') >= 0 || names.length) containers.push({ el: el, names: names });
                }
                if (cr.indexOf('br-aspect') < 0) { if (el.__brAspect) { el.style.height = ''; el.__brAspect = false; } continue; }
                // the engine serialises the counters in its own order, so the two are read independently
                var mw = /br-aspect\s+(\d+)/.exec(cr), mhh = /br-aspect-h\s+(\d+)/.exec(cr);
                if (!mw || !mhh) continue;
                var m = [null, mw[1], mhh[1]];
                var tag = el.tagName;
                var replaced = tag === 'IMG' || tag === 'VIDEO' || tag === 'IFRAME' || tag === 'CANVAS' || tag === 'EMBED' || tag === 'OBJECT' || tag === 'SVG';
                if (!replaced && (el.children.length || (el.textContent || '').replace(/\s+/g, '').length)) continue;   // boxes with content keep their own height
                var w = el.offsetWidth;
                if (!w) continue;
                var h = Math.round(w * parseInt(m[2], 10) / parseInt(m[1], 10));
                if (Math.abs(el.offsetHeight - h) > 1) { el.style.height = h + 'px'; el.__brAspect = true; }
                found.push(el);
            }
            aspectElements = found;
            containerElements = containers;
            if (window.__brApplyContainerQueries) window.__brApplyContainerQueries(containers);
            for (var mh = 0; mh < markerHooks.length; mh++) try { markerHooks[mh](marked); } catch (e2) {}
        } catch (e) {}
    };
    var scheduleAspect = function () { if (aspectTimer) return; aspectTimer = setTimeout(function () { aspectTimer = null; applyAspectRatios(); }, 200); };
    onReady(scheduleAspect);
    onSettled(scheduleAspect);
    window.addEventListener('resize', scheduleAspect, false);
    window.addEventListener('load', scheduleAspect, false);
    // Form controls and replaced elements styled with display:flex (Google's search box) become 2009 boxes after
    // the CSS rewrite, which draws their text outside the control: they go back to block / inline-block.
    var unboxControls = function () {
        try {
            var controls = document.querySelectorAll('textarea, input, select, button, img, video, canvas, iframe');
            for (var i = 0; i < controls.length; i++) {
                var c = controls[i];
                if (c.__brUnboxed) continue;
                var disp = getComputedStyle(c).display;
                if (disp === '-webkit-box') { c.style.display = 'block'; c.__brUnboxed = true; }
                else if (disp === '-webkit-inline-box') { c.style.display = 'inline-block'; c.__brUnboxed = true; }
            }
        } catch (e) {}
    };
    onReady(unboxControls);
    onSettled(unboxControls);
    // ---- Pseudo-classes as classes: cssfix rewrites :focus-within, :placeholder-shown, :user-invalid/:user-valid,
    // :blank, :target-within, :playing/:paused/:muted and :local-link to .br-* classes that are kept up to date here.
    (function () {
        var focusChain = [];
        var setChain = function (el, on) { for (var n = el; n && n.nodeType === 1; n = n.parentNode) setStateClass(n, 'br-focus-within', on); };
        var onFocus = function (e) {
            var t = e.target;
            if (!t || t.nodeType !== 1) return;
            for (var i = 0; i < focusChain.length; i++) setStateClass(focusChain[i], 'br-focus-within', false);
            focusChain = [];
            for (var n = t; n && n.nodeType === 1; n = n.parentNode) { setStateClass(n, 'br-focus-within', true); focusChain.push(n); }
        };
        var onBlur = function () {
            setTimeout(function () {
                var active = document.activeElement;
                if (active && active !== document.body && active !== document.documentElement) return;   // focus moved elsewhere: onFocus handled it
                for (var i = 0; i < focusChain.length; i++) setStateClass(focusChain[i], 'br-focus-within', false);
                focusChain = [];
            }, 0);
        };
        document.addEventListener('focus', onFocus, true);
        document.addEventListener('blur', onBlur, true);
        // text fields: placeholder-shown / blank, user-invalid / user-valid after the user has touched the field
        var isField = function (el) { return el && el.nodeType === 1 && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT'); };
        var updateField = function (el, touched) {
            if (!isField(el)) return;
            var empty = el.tagName === 'SELECT' ? false : !el.value;
            setStateClass(el, 'br-blank', empty);
            setStateClass(el, 'br-placeholder-shown', empty && !!el.getAttribute('placeholder'));
            if (touched) el.__brTouched = true;
            if (el.__brTouched && typeof el.checkValidity === 'function') {
                var valid = true;
                try { valid = el.checkValidity(); } catch (e) {}
                setStateClass(el, 'br-user-invalid', !valid);
                setStateClass(el, 'br-user-valid', valid && !!el.value);
            }
        };
        var scanFields = function () {
            try { var all = document.querySelectorAll('input, textarea'); for (var i = 0; i < all.length; i++) updateField(all[i], false); } catch (e) {}
        };
        document.addEventListener('input', function (e) { updateField(e.target, false); }, true);
        document.addEventListener('change', function (e) { updateField(e.target, true); }, true);
        document.addEventListener('blur', function (e) { if (isField(e.target) && e.target.value) updateField(e.target, true); }, true);
        document.addEventListener('invalid', function (e) { updateField(e.target, true); }, true);
        document.addEventListener('reset', function () { setTimeout(scanFields, 0); }, true);
        onReady(scanFields);
        onSettled(scanFields);
        setInterval(scanFields, 1500);   // programmatic value changes
        // media
        var mediaState = function (e) {
            var m = e.target;
            if (!m || (m.tagName !== 'VIDEO' && m.tagName !== 'AUDIO')) return;
            setStateClass(m, 'br-playing', !m.paused && !m.ended);
            setStateClass(m, 'br-paused', m.paused || m.ended);
            setStateClass(m, 'br-muted', !!m.muted || m.volume === 0);
            setStateClass(m, 'br-seeking', !!m.seeking);
            if (e.type === 'waiting') m.__brBuffering = true; else if (e.type === 'playing' || e.type === 'canplay' || e.type === 'pause' || e.type === 'ended') m.__brBuffering = false;
            if (e.type === 'stalled') m.__brStalled = true; else if (e.type === 'progress' || e.type === 'playing' || e.type === 'canplay') m.__brStalled = false;
            setStateClass(m, 'br-buffering', !!m.__brBuffering);
            setStateClass(m, 'br-stalled', !!m.__brStalled);
        };
        var mediaEvents = ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'emptied', 'seeking', 'seeked', 'waiting', 'canplay', 'stalled', 'progress'];
        for (var me = 0; me < mediaEvents.length; me++) document.addEventListener(mediaEvents[me], mediaState, true);
        // :target-within
        var targetChain = [];
        var updateTarget = function () {
            for (var i = 0; i < targetChain.length; i++) setStateClass(targetChain[i], 'br-target-within', false);
            targetChain = [];
            var id = location.hash ? decodeURIComponent(location.hash.slice(1)) : '';
            if (!id) return;
            var t = null;
            try { t = document.getElementById(id); } catch (e) {}
            for (var n = t; n && n.nodeType === 1; n = n.parentNode) { setStateClass(n, 'br-target-within', true); targetChain.push(n); }
        };
        window.addEventListener('hashchange', updateTarget, false);
        onReady(updateTarget);
        // :local-link: links to the current site
        var markLocalLinks = function (root) {
            try {
                var links = (root && root.querySelectorAll ? root : document).querySelectorAll('a[href]');
                for (var i = 0; i < links.length; i++) {
                    var a = links[i];
                    if (a.__brLocalChecked) continue;
                    a.__brLocalChecked = true;
                    if (a.host === location.host && a.protocol === location.protocol) setStateClass(a, 'br-local-link', true);
                }
            } catch (e) {}
        };
        onReady(function () { markLocalLinks(document); });
        onSettled(function () { markLocalLinks(document); });
    })();
    // ---- :has() and @container: the CSS rewriter turned them into .br-has-<h> / .br-cq-<h> classes and left the
    // entries in a manifest the app serves per page; the classes are kept up to date here.
    (function () {
        var manifest = null, lastText = '', applyTimer = null, fetching = false, fetchTimer = null, fetches = 0;
        var manifestURL = function () { return window.__brManifestURL || ('https://ios6-browser.invalid/manifest?doc=' + encodeURIComponent(location.href.split('#')[0])); };   // the override is for tests
        var trim = function (s) { return String(s).replace(/^\s+|\s+$/g, ''); };
        var splitTop = function (s, sep) {
            var parts = [], depth = 0, start = 0, q = null;
            for (var i = 0; i < s.length; i++) {
                var c = s.charAt(i);
                if (q) { if (c === q) q = null; continue; }
                if (c === '"' || c === "'") q = c; else if (c === '(' || c === '[') depth++; else if (c === ')' || c === ']') depth--;
                else if (depth === 0 && c === sep) { parts.push(s.slice(start, i)); start = i + 1; }
            }
            parts.push(s.slice(start));
            return parts;
        };
        // ---- :has(): does `el` have what the relative selector list asks for?
        var hasMatch = function (el, inner) {
            var parts = splitTop(inner, ','), parent = el.parentNode || document;
            el.setAttribute('data-br-scope', '1');
            var found = false;
            try {
                for (var i = 0; i < parts.length && !found; i++) {
                    var p = trim(parts[i]);
                    if (!p) continue;
                    var sel = '[data-br-scope]' + (/^[>+~]/.test(p) ? ' ' + p : ' ' + p);
                    try { found = !!parent.querySelector(sel); } catch (e) { found = false; }
                }
            } finally { el.removeAttribute('data-br-scope'); }
            return found;
        };
        var applyHas = function () {
            if (!manifest || !manifest.has || !manifest.has.length) return;
            for (var i = 0; i < manifest.has.length; i++) {
                var entry = manifest.has[i], candidates;
                try { candidates = document.querySelectorAll(entry.target); } catch (e) { continue; }
                for (var k = 0; k < candidates.length && k < 3000; k++) setStateClass(candidates[k], 'br-has-' + entry.h, hasMatch(candidates[k], entry.inner));
            }
        };
        // ---- @container: size conditions evaluated against the marked container elements
        var lengthPx = function (tok, el) {
            var m = /^(-?[\d.]+)([a-z%]*)$/i.exec(tok);
            if (!m) return null;
            var n = parseFloat(m[1]), u = m[2].toLowerCase();
            switch (u) {
                case '': case 'px': return n;
                case 'em': return n * (parseFloat(getComputedStyle(el).fontSize) || 16);
                case 'rem': return n * (parseFloat(getComputedStyle(document.documentElement).fontSize) || 16);
                case 'vw': return n * window.innerWidth / 100;
                case 'vh': return n * window.innerHeight / 100;
                case 'vmin': return n * Math.min(window.innerWidth, window.innerHeight) / 100;
                case 'vmax': return n * Math.max(window.innerWidth, window.innerHeight) / 100;
                case 'pt': return n * 4 / 3;
                case 'cm': return n * 96 / 2.54;
                case 'mm': return n * 96 / 25.4;
                case 'in': return n * 96;
            }
            return null;
        };
        var featureValue = function (name, el, size) {
            switch (name) {
                case 'width': case 'inline-size': return size.w;
                case 'height': case 'block-size': return size.h;
                case 'aspect-ratio': return size.h ? size.w / size.h : 0;
                case 'orientation': return size.w >= size.h ? 'landscape' : 'portrait';
            }
            return undefined;
        };
        var ratioValue = function (tok) { var m = /^([\d.]+)\s*\/\s*([\d.]+)$/.exec(tok); return m ? parseFloat(m[1]) / (parseFloat(m[2]) || 1) : parseFloat(tok); };
        var compare = function (a, op, b) {
            switch (op) { case '<': return a < b; case '<=': return a <= b; case '>': return a > b; case '>=': return a >= b; default: return a === b; }
        };
        var evalFeature = function (expr, el, size) {
            expr = trim(expr);
            if (/^(style|scroll-state)\(/i.test(expr)) return false;
            var colon = expr.indexOf(':');
            var m;
            if (colon > 0 && !/[<>=]/.test(expr)) {
                var name = trim(expr.slice(0, colon)).toLowerCase(), val = trim(expr.slice(colon + 1)).toLowerCase();
                var minmax = /^(min|max)-(.+)$/.exec(name), base = minmax ? minmax[2] : name;
                var fv = featureValue(base, el, size);
                if (fv === undefined) return false;
                if (base === 'orientation') return fv === val;
                var target = base === 'aspect-ratio' ? ratioValue(val) : lengthPx(val, el);
                if (target === null || isNaN(target)) return false;
                return minmax ? (minmax[1] === 'min' ? fv >= target : fv <= target) : fv === target;
            }
            // range syntax: "width >= 400px", "400px < width <= 800px", "orientation = portrait"
            m = /^([\w-]+|[\d.]+[a-z%]*(?:\s*\/\s*[\d.]+)?)\s*(<=|>=|<|>|=)\s*([\w-]+|[\d.]+[a-z%]*(?:\s*\/\s*[\d.]+)?)(?:\s*(<=|>=|<|>|=)\s*([\d.]+[a-z%]*(?:\s*\/\s*[\d.]+)?))?$/.exec(expr);
            if (!m) return false;
            var leftIsFeature = featureValue(m[1].toLowerCase(), el, size) !== undefined;
            var feature = leftIsFeature ? m[1].toLowerCase() : m[3].toLowerCase();
            var fval = featureValue(feature, el, size);
            if (fval === undefined) return false;
            var conv = function (tok) { return feature === 'aspect-ratio' ? ratioValue(tok) : feature === 'orientation' ? tok.toLowerCase() : lengthPx(tok, el); };
            if (leftIsFeature) return compare(fval, m[2], conv(m[3])) && (!m[4] || compare(fval, m[4], conv(m[5])));
            // "400px < width <= 800px": the first comparison is written from the value's side
            var flip = { '<': '>', '<=': '>=', '>': '<', '>=': '<=', '=': '=' };
            return compare(fval, flip[m[2]], conv(m[1])) && (!m[4] || compare(fval, m[4], conv(m[5])));
        };
        var evalCond = function (cond, el, size) {
            cond = trim(cond);
            if (!cond) return false;
            while (cond.charAt(0) === '(' && (function () { var d = 0; for (var i = 0; i < cond.length; i++) { var c = cond.charAt(i); if (c === '(') d++; else if (c === ')') { d--; if (d === 0) return i === cond.length - 1; } } return false; })()) cond = trim(cond.slice(1, -1));
            if (/^not\s/i.test(cond)) return !evalCond(cond.slice(4), el, size);
            var terms = [], ops = [], depth = 0, start = 0;
            for (var i = 0; i < cond.length; i++) {
                var c = cond.charAt(i);
                if (c === '(') depth++; else if (c === ')') depth--;
                else if (depth === 0) {
                    var m = /^\s+(and|or)\s+/i.exec(cond.slice(i));
                    if (m) { terms.push(cond.slice(start, i)); ops.push(m[1].toLowerCase()); i += m[0].length - 1; start = i + 1; }
                }
            }
            terms.push(cond.slice(start));
            if (terms.length === 1) return evalFeature(cond, el, size);
            var result = evalCond(terms[0], el, size);
            for (var k = 1; k < terms.length; k++) { var v = evalCond(terms[k], el, size); result = ops[k - 1] === 'or' ? (result || v) : (result && v); }
            return result;
        };
        var containerSize = function (el) {
            var cs = getComputedStyle(el);
            var w = el.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
            var h = el.clientHeight - (parseFloat(cs.paddingTop) || 0) - (parseFloat(cs.paddingBottom) || 0);
            return { w: w > 0 ? w : 0, h: h > 0 ? h : 0 };
        };
        var applyContainers = function (containers) {
            if (!manifest || !manifest.cq || !manifest.cq.length || !containers) return;
            for (var i = 0; i < containers.length; i++) {
                var c = containers[i], size = null;
                for (var k = 0; k < manifest.cq.length; k++) {
                    var q = manifest.cq[k];
                    if (q.name && c.names.indexOf(q.name) < 0) { setStateClass(c.el, 'br-cq-' + q.h, false); continue; }
                    if (!size) size = containerSize(c.el);
                    var on = false;
                    try { on = evalCond(q.cond, c.el, size); } catch (e) { on = false; }
                    setStateClass(c.el, 'br-cq-' + q.h, on);
                }
            }
        };
        window.__brApplyContainerQueries = applyContainers;
        var apply = function () {
            applyTimer = null;
            if (!manifest) return;
            try { applyHas(); } catch (e) {}
            try { if (manifest.cq.length) applyAspectRatios(); } catch (e2) {}   // the marker scan calls applyContainers
        };
        var schedule = function () { if (!applyTimer) applyTimer = setTimeout(apply, 120); };
        var load = function () {
            if (fetching || !window.XMLHttpRequest || fetches > 40) return;
            fetching = true;
            fetches++;
            try {
                var x = new XMLHttpRequest();
                x.open('GET', manifestURL(), true);
                x.onreadystatechange = function () {
                    if (x.readyState !== 4) return;
                    fetching = false;
                    if (x.status !== 200 || !x.responseText || x.responseText === lastText) return;
                    lastText = x.responseText;
                    try { manifest = JSON.parse(x.responseText); } catch (e) { manifest = null; }
                    if (manifest && !manifest.has) manifest.has = [];
                    if (manifest && !manifest.cq) manifest.cq = [];
                    schedule();
                };
                x.send(null);
            } catch (e) { fetching = false; }
        };
        var scheduleLoad = function () { if (!fetchTimer) fetchTimer = setTimeout(function () { fetchTimer = null; load(); }, 300); };
        onReady(scheduleLoad);
        window.addEventListener('load', scheduleLoad, false);
        onSettled(function () { scheduleLoad(); if (manifest) schedule(); });
        window.addEventListener('resize', function () { if (manifest && manifest.cq.length) schedule(); }, false);
        var reevaluate = function () { if (manifest && manifest.has.length) schedule(); };
        document.addEventListener('input', reevaluate, true);
        document.addEventListener('change', reevaluate, true);
        document.addEventListener('click', reevaluate, true);
        document.addEventListener('focus', reevaluate, true);
        document.addEventListener('blur', reevaluate, true);
        window.__brManifestReload = load;
    })();
    // ---- Scroll snap, smooth scrolling and balanced text, driven by the rewriter's counter-reset markers
    // (br-snap-x/y, br-snap-m, br-snap-pad, br-snap-align on the items, br-smooth, br-balance)
    (function () {
        var raf = function (fn) { return setTimeout(fn, 16); };   // a timer keeps running where requestAnimationFrame would stall
        var ease = function (t) { return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t; };
        // animate the scroll position of `target` (window or element) to x/y over `ms`
        var animateScroll = function (target, x, y, ms) {
            var isWin = target === window;
            var sx = isWin ? window.pageXOffset : target.scrollLeft, sy = isWin ? window.pageYOffset : target.scrollTop;
            if (x === null || x === undefined) x = sx;
            if (y === null || y === undefined) y = sy;
            if (Math.abs(x - sx) < 1 && Math.abs(y - sy) < 1) { return; }
            var start = Date.now(), token = {};
            target.__brScrollAnim = token;
            var step = function () {
                if (target.__brScrollAnim !== token) return;
                var t = Math.min(1, (Date.now() - start) / ms), k = ease(t);
                var nx = sx + (x - sx) * k, ny = sy + (y - sy) * k;
                if (isWin) window.scrollTo(nx, ny); else { target.scrollLeft = nx; target.scrollTop = ny; }
                if (t < 1) raf(step); else target.__brScrollAnim = null;
            };
            raf(step);
        };
        var smoothWanted = function (arg, target) {
            var b = arg && typeof arg === 'object' ? arg.behavior : undefined;
            if (b === 'smooth') return true;
            if (b === 'instant' || b === 'auto') return false;
            return false;
        };
        // window.scrollTo / scrollBy / scroll with { behavior: 'smooth' }
        var origWinScrollTo = window.scrollTo, origWinScrollBy = window.scrollBy;
        window.scrollTo = window.scroll = function (x, y) {
            if (x && typeof x === 'object') {
                var tx = x.left !== undefined ? x.left : window.pageXOffset, ty = x.top !== undefined ? x.top : window.pageYOffset;
                if (smoothWanted(x)) { animateScroll(window, tx, ty, 350); return; }
                return origWinScrollTo.call(window, tx, ty);
            }
            return origWinScrollTo.apply(window, arguments);
        };
        window.scrollBy = function (x, y) {
            if (x && typeof x === 'object') {
                var dx = x.left || 0, dy = x.top || 0;
                if (smoothWanted(x)) { animateScroll(window, window.pageXOffset + dx, window.pageYOffset + dy, 350); return; }
                return origWinScrollBy.call(window, dx, dy);
            }
            return origWinScrollBy.apply(window, arguments);
        };
        if (Ep) {
            var origElScrollTo = Ep.scrollTo, origElScrollBy = Ep.scrollBy, origScrollIntoView = Ep.scrollIntoView;
            Ep.scrollTo = Ep.scroll = function (x, y) {
                if (x && typeof x === 'object' && smoothWanted(x)) { animateScroll(this, x.left !== undefined ? x.left : this.scrollLeft, x.top !== undefined ? x.top : this.scrollTop, 350); return; }
                return origElScrollTo.apply(this, arguments);
            };
            Ep.scrollBy = function (x, y) {
                if (x && typeof x === 'object' && smoothWanted(x)) { animateScroll(this, this.scrollLeft + (x.left || 0), this.scrollTop + (x.top || 0), 350); return; }
                return origElScrollBy.apply(this, arguments);
            };
            Ep.scrollIntoView = function (arg) {
                if (arg && typeof arg === 'object' && smoothWanted(arg)) {
                    // only the window scrolls smoothly; inside another scroll container the engine jumps as before
                    var r = this.getBoundingClientRect(), block = arg.block || 'start', inline = arg.inline || 'nearest';
                    var y = window.pageYOffset + r.top - (block === 'center' ? (window.innerHeight - r.height) / 2 : block === 'end' ? window.innerHeight - r.height : block === 'nearest' ? (r.top >= 0 && r.bottom <= window.innerHeight ? r.top : r.top < 0 ? 0 : window.innerHeight - r.height) : 0);
                    var x = inline === 'nearest' ? window.pageXOffset : window.pageXOffset + r.left - (inline === 'center' ? (window.innerWidth - r.width) / 2 : inline === 'end' ? window.innerWidth - r.width : 0);
                    animateScroll(window, x, Math.max(0, y), 350);
                    return;
                }
                return origScrollIntoView.apply(this, arguments);
            };
        }
        // CSS scroll-behavior: smooth on the root: in-page anchor links glide
        var rootSmooth = false;
        document.addEventListener('click', function (e) {
            if (!rootSmooth || e.defaultPrevented || e.button) return;
            var a = e.target;
            while (a && a.nodeType === 1 && a.tagName !== 'A') a = a.parentNode;
            if (!a || a.nodeType !== 1) return;
            var href = a.getAttribute('href') || '';
            if (href.charAt(0) !== '#' || href.length < 2) return;
            var target = null;
            try { target = document.getElementById(decodeURIComponent(href.slice(1))); } catch (e2) {}
            if (!target) return;
            e.preventDefault();
            var r = target.getBoundingClientRect();
            animateScroll(window, window.pageXOffset, Math.max(0, window.pageYOffset + r.top), 400);
            try { if (window.history && history.pushState) history.pushState(null, '', href); } catch (e3) {}
        }, false);
        // scroll snap containers
        var snapContainers = [];
        var alignOf = function (child) {
            if (child.__brSnapAlign === undefined) {
                var cr = getComputedStyle(child).counterReset || '', m = /br-snap-align\s+(\d)/.exec(cr), mm = /br-snap-margin\s+(-?\d+)/.exec(cr);
                child.__brSnapAlign = m ? parseInt(m[1], 10) : 0;
                child.__brSnapMargin = mm ? parseInt(mm[1], 10) : 0;   // scroll-margin: the item's own outset from the snap position
            }
            return child.__brSnapAlign;
        };
        var snapNow = function (c) {
            var el = c.el;
            if (el.__brTouching || el.__brScrollAnim) return;
            var kids = el.children, bestX = null, bestY = null, bestDX = Infinity, bestDY = Infinity;
            var cw = el.clientWidth, ch = el.clientHeight, sx = el.scrollLeft, sy = el.scrollTop;
            var maxX = el.scrollWidth - cw, maxY = el.scrollHeight - ch;
            for (var i = 0; i < kids.length; i++) {
                var k = kids[i], a = alignOf(k);
                if (!a) continue;
                if (c.x) {
                    var tx = a === 2 ? k.offsetLeft - (cw - k.offsetWidth) / 2 : a === 3 ? k.offsetLeft + k.offsetWidth - cw : k.offsetLeft - c.pad - (k.__brSnapMargin || 0);
                    tx = Math.max(0, Math.min(maxX, tx));
                    var dx = Math.abs(tx - sx);
                    if (dx < bestDX) { bestDX = dx; bestX = tx; }
                }
                if (c.y) {
                    var ty = a === 2 ? k.offsetTop - (ch - k.offsetHeight) / 2 : a === 3 ? k.offsetTop + k.offsetHeight - ch : k.offsetTop - c.pad - (k.__brSnapMargin || 0);
                    ty = Math.max(0, Math.min(maxY, ty));
                    var dy = Math.abs(ty - sy);
                    if (dy < bestDY) { bestDY = dy; bestY = ty; }
                }
            }
            // proximity snapping only pulls when the nearest stop is within a quarter of the viewport
            if (bestX !== null && (bestDX < 1 || (!c.mandatory && bestDX > cw / 4))) bestX = null;
            if (bestY !== null && (bestDY < 1 || (!c.mandatory && bestDY > ch / 4))) bestY = null;
            if (bestX === null && bestY === null) return;
            animateScroll(el, bestX === null ? sx : bestX, bestY === null ? sy : bestY, 200);
        };
        var attachSnap = function (c) {
            var el = c.el;
            if (el.__brSnapAttached) return;
            el.__brSnapAttached = true;
            var timer = null;
            el.addEventListener('scroll', function () { if (el.__brScrollAnim) return; if (timer) clearTimeout(timer); timer = setTimeout(function () { timer = null; var cur = el.__brSnapConfig; if (cur) snapNow(cur); }, 120); }, false);
            el.addEventListener('touchstart', function () { el.__brTouching = true; }, false);
            el.addEventListener('touchend', function () { el.__brTouching = false; }, false);
            el.addEventListener('touchcancel', function () { el.__brTouching = false; }, false);
        };
        // balanced headings: the smallest max-width that keeps the line count (binary search, applied inline)
        var balance = function (el) {
            if (el.__brBalancing) return;
            var text = el.textContent || '';
            if (text.length > 400) return;
            var cs = getComputedStyle(el);
            if (cs.display === 'inline' || cs.whiteSpace === 'nowrap') return;
            el.__brBalancing = true;
            try {
                var prev = el.style.maxWidth;
                el.style.maxWidth = '';
                var full = el.clientWidth, lineH = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2 || 20;
                var height = el.offsetHeight, lines = Math.round(height / lineH);
                if (lines < 2 || full < 80) { el.style.maxWidth = ''; return; }
                if (el.__brBalanceKey === full + ':' + text.length) { el.style.maxWidth = prev; return; }
                var lo = Math.floor(full / lines), hi = full, best = full;
                for (var it = 0; it < 8 && hi - lo > 4; it++) {
                    var mid = Math.floor((lo + hi) / 2);
                    el.style.maxWidth = mid + 'px';
                    if (el.offsetHeight <= height + 1) { best = mid; hi = mid; } else lo = mid;
                }
                el.style.maxWidth = best + 'px';
                el.__brBalanceKey = full + ':' + text.length;
            } catch (e) {} finally { el.__brBalancing = false; }
        };
        onMarkers(function (marked) {
            rootSmooth = false;
            snapContainers = [];
            for (var i = 0; i < marked.length; i++) {
                var el = marked[i].el, cr = marked[i].cr;
                if (cr.indexOf('br-smooth') >= 0 && (el === document.documentElement || el === document.body)) rootSmooth = true;
                if (cr.indexOf('br-snap-x') >= 0 || cr.indexOf('br-snap-y') >= 0) {
                    var pad = /br-snap-pad\s+(-?\d+)/.exec(cr);
                    var c = { el: el, x: cr.indexOf('br-snap-x') >= 0, y: cr.indexOf('br-snap-y') >= 0, mandatory: cr.indexOf('br-snap-m') >= 0, pad: pad ? parseInt(pad[1], 10) : 0 };
                    el.__brSnapConfig = c;
                    snapContainers.push(c);
                    attachSnap(c);
                }
                if (cr.indexOf('br-balance') >= 0) balance(el);
            }
        });
    })();
    // ---- Scroll-driven animations (markers br-tl-scroll / br-tl-view / br-tl-named-<name>, br-tl-inline/root/self,
    // ranges br-ar-s / br-ar-e, timeline sources br-stl-<name> / br-vtl-<name>): the animation is paused and
    // seeked with a negative animation-delay as the scroll position changes.
    (function () {
        var raf = function (fn) { return setTimeout(fn, 16); };   // rAF stalls in hidden pages; a timer always runs
        var RANGE = ['cover', 'contain', 'entry', 'exit', 'entry-crossing', 'exit-crossing'];
        var driven = [];
        var clamp01 = function (x) { return x < 0 ? 0 : x > 1 ? 1 : x; };
        var scrollerOf = function (el, inline) {
            for (var n = el.parentNode; n && n.nodeType === 1 && n !== document.documentElement; n = n.parentNode) {
                var cs = getComputedStyle(n), ov = inline ? cs.overflowX : cs.overflowY;
                if ((ov === 'auto' || ov === 'scroll') && (inline ? n.scrollWidth > n.clientWidth : n.scrollHeight > n.clientHeight)) return n;
            }
            return null;   // the viewport
        };
        var durationOf = function (el) {
            var cs = getComputedStyle(el), d = parseFloat(cs.webkitAnimationDuration || cs.animationDuration || '0');
            if (!(d > 0)) { el.style.webkitAnimationDuration = '1s'; el.style.animationDuration = '1s'; d = 1; }
            return d;
        };
        var progressFor = function (d) {
            var inline = d.inline, scroller = d.source === 'root' ? null : d.source || scrollerOf(d.subject || d.el, inline);
            if (d.kind === 'scroll') {
                var max, pos;
                if (!scroller) { max = inline ? document.documentElement.scrollWidth - window.innerWidth : document.documentElement.scrollHeight - window.innerHeight; pos = inline ? window.pageXOffset : window.pageYOffset; }
                else { max = inline ? scroller.scrollWidth - scroller.clientWidth : scroller.scrollHeight - scroller.clientHeight; pos = inline ? scroller.scrollLeft : scroller.scrollTop; }
                if (max <= 0) return 0;
                var sp = pos / max, s0 = d.rsPct, s1 = d.rePct;
                return s1 === s0 ? 0 : clamp01((sp - s0) / (s1 - s0));
            }
            var subject = d.subject || d.el, rect = subject.getBoundingClientRect(), vTop, vSize;
            if (!scroller) { vTop = 0; vSize = inline ? window.innerWidth : window.innerHeight; }
            else { var sr = scroller.getBoundingClientRect(); vTop = inline ? sr.left : sr.top; vSize = inline ? scroller.clientWidth : scroller.clientHeight; }
            var top = (inline ? rect.left : rect.top) - vTop, size = inline ? rect.width : rect.height;
            // the subject's start edge relative to the scrollport start, at 0 % and 100 % of each named range
            var edge = function (name, pct) {
                var a, b;
                switch (name) {
                    case 'entry': case 'entry-crossing': a = vSize; b = vSize - size; break;
                    case 'exit': case 'exit-crossing': a = 0; b = -size; break;
                    case 'contain': a = vSize - size; b = 0; break;
                    default: a = vSize; b = -size;
                }
                return a + (b - a) * pct;
            };
            var t0 = edge(d.rsName, d.rsPct), t1 = edge(d.reName, d.rePct);
            return t0 === t1 ? 0 : clamp01((t0 - top) / (t0 - t1));
        };
        var apply = function () {
            for (var i = 0; i < driven.length; i++) {
                var d = driven[i], p = progressFor(d);
                var delay = (-(p * d.duration * 0.999)).toFixed(4) + 's';
                if (d.lastDelay !== delay) { d.lastDelay = delay; d.el.style.webkitAnimationDelay = delay; d.el.style.animationDelay = delay; }
            }
        };
        var scheduled = false;
        var onScroll = function () { if (scheduled || !driven.length) return; scheduled = true; raf(function () { scheduled = false; apply(); }); };
        onMarkers(function (marked) {
            var sources = {}, i, cr, el, m;
            for (i = 0; i < marked.length; i++) {
                cr = marked[i].cr; el = marked[i].el;
                var re = /br-(stl|vtl)-([\w-]+)/g;
                while ((m = re.exec(cr)) !== null) sources[m[1] + ':' + m[2]] = { el: el, inline: cr.indexOf('br-tl-src-inline') >= 0 };
            }
            driven = [];
            for (i = 0; i < marked.length; i++) {
                cr = marked[i].cr; el = marked[i].el;
                m = /br-tl-(scroll|view|named-([\w-]+))/.exec(cr);
                if (!m) continue;
                var d = { el: el, kind: m[1] === 'view' ? 'view' : 'scroll', inline: cr.indexOf('br-tl-inline') >= 0, source: cr.indexOf('br-tl-root') >= 0 ? 'root' : cr.indexOf('br-tl-self') >= 0 ? el : null, subject: null,
                          rsName: 'cover', rsPct: 0, reName: 'cover', rePct: 1, lastDelay: null };
                if (m[2]) {
                    var vt = sources['vtl:' + m[2]], st = sources['stl:' + m[2]];
                    if (vt) { d.kind = 'view'; d.subject = vt.el; d.inline = vt.inline; }
                    else if (st) { d.kind = 'scroll'; d.source = st.el === document.documentElement || st.el === document.body ? 'root' : st.el; d.inline = st.inline; }
                    else continue;
                }
                var rs = /br-ar-s\s+(\d+)/.exec(cr), rEnd = /br-ar-e\s+(\d+)/.exec(cr);
                if (rs) { d.rsName = RANGE[Math.floor(parseInt(rs[1], 10) / 1000)] || 'cover'; d.rsPct = (parseInt(rs[1], 10) % 1000) / 100; }
                if (rEnd) { d.reName = RANGE[Math.floor(parseInt(rEnd[1], 10) / 1000)] || 'cover'; d.rePct = (parseInt(rEnd[1], 10) % 1000) / 100; }
                if (d.kind === 'scroll' && rs && rs[1].indexOf('0') !== 0 && d.rsName !== 'cover') { d.rsPct = 0; }   // named ranges mean nothing for scroll timelines
                d.duration = durationOf(el);
                el.style.webkitAnimationPlayState = 'paused'; el.style.animationPlayState = 'paused';
                el.style.webkitAnimationFillMode = 'both'; el.style.animationFillMode = 'both';
                driven.push(d);
            }
            apply();
        });
        window.addEventListener('scroll', onScroll, true);
        window.addEventListener('resize', onScroll, false);
        window.addEventListener('load', onScroll, false);
        window.__brScrollDriven = { list: function () { return driven; }, apply: apply, progress: progressFor };
    })();
    // ---- Popover API: [popover] elements, showPopover()/hidePopover()/togglePopover(), popovertarget buttons,
    // light dismiss for auto popovers, ToggleEvent; cssfix rewrites :popover-open to .br-popover-open
    if (Ep && !('popover' in Ep)) (function () {
        var open = [];
        addStyle('[popover]:not(.br-popover-open){display:none !important}' +
                 '[popover].br-popover-open{position:fixed;top:0;right:0;bottom:0;left:0;width:-webkit-fit-content;width:fit-content;height:-webkit-fit-content;height:fit-content;' +
                 'margin:auto;border:solid;padding:0.25em;overflow:auto;color:black;background:white;z-index:2147483646}');
        var ToggleEvent = function ToggleEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, type === 'beforetoggle'); e.oldState = init && init.oldState || ''; e.newState = init && init.newState || ''; return e; };
        try { ToggleEvent.prototype = Object.create(window.Event.prototype); ToggleEvent.prototype.oldState = ''; ToggleEvent.prototype.newState = ''; } catch (e0) {}
        if (!window.ToggleEvent) window.ToggleEvent = ToggleEvent;
        var isOpen = function (el) { return open.indexOf(el) >= 0; };
        var hide = function (el, viaDismiss) {
            var i = open.indexOf(el);
            if (i < 0) return;
            var before = new ToggleEvent('beforetoggle', { oldState: 'open', newState: 'closed' });
            el.dispatchEvent(before);
            open.splice(i, 1);
            setStateClass(el, 'br-popover-open', false);
            setTimeout(function () { el.dispatchEvent(new ToggleEvent('toggle', { oldState: 'open', newState: 'closed' })); }, 0);
        };
        var show = function (el) {
            if (isOpen(el) || !el.hasAttribute('popover')) return;
            var before = new ToggleEvent('beforetoggle', { oldState: 'closed', newState: 'open' });
            if (!el.dispatchEvent(before)) return;   // preventDefault keeps it closed
            var mode = (el.getAttribute('popover') || 'auto').toLowerCase();
            if (mode !== 'manual') {   // an auto popover closes the other auto popovers (nested ones stay)
                for (var i = open.length - 1; i >= 0; i--) if ((open[i].getAttribute('popover') || 'auto').toLowerCase() !== 'manual' && !open[i].contains(el)) hide(open[i]);
            }
            open.push(el);
            setStateClass(el, 'br-popover-open', true);
            setTimeout(function () { el.dispatchEvent(new ToggleEvent('toggle', { oldState: 'closed', newState: 'open' })); }, 0);
        };
        Ep.showPopover = function () { show(this); };
        Ep.hidePopover = function () { hide(this); };
        Ep.togglePopover = function (force) { var want = force === undefined ? !isOpen(this) : !!force; if (want) show(this); else hide(this); return want; };
        try {
            Object.defineProperty(Ep, 'popover', { get: function () { if (!this.hasAttribute('popover')) return null; var v = (this.getAttribute('popover') || '').toLowerCase(); return v === 'manual' ? 'manual' : 'auto'; }, set: function (v) { if (v === null || v === undefined) this.removeAttribute('popover'); else this.setAttribute('popover', v); }, configurable: true });
            var targetProp = function (proto) {
                Object.defineProperty(proto, 'popoverTargetElement', { get: function () { var id = this.getAttribute('popovertarget'); return id ? document.getElementById(id) : null; }, set: function (el) { if (el && el.id) this.setAttribute('popovertarget', el.id); else this.removeAttribute('popovertarget'); }, configurable: true });
                Object.defineProperty(proto, 'popoverTargetAction', { get: function () { var a = (this.getAttribute('popovertargetaction') || '').toLowerCase(); return a === 'show' || a === 'hide' ? a : 'toggle'; }, set: function (v) { this.setAttribute('popovertargetaction', v); }, configurable: true });
            };
            if (window.HTMLButtonElement) targetProp(window.HTMLButtonElement.prototype);
            if (window.HTMLInputElement) targetProp(window.HTMLInputElement.prototype);
        } catch (e1) {}
        document.addEventListener('click', function (e) {
            var t = e.target;
            while (t && t.nodeType === 1 && !t.hasAttribute('popovertarget')) t = t.parentNode;
            if (t && t.nodeType === 1) {
                var target = document.getElementById(t.getAttribute('popovertarget') || '');
                if (target && target.hasAttribute('popover')) {
                    var action = (t.getAttribute('popovertargetaction') || 'toggle').toLowerCase();
                    if (action === 'show') show(target); else if (action === 'hide') hide(target); else { if (isOpen(target)) hide(target); else show(target); }
                    e.__brPopoverHandled = true;
                    return;
                }
            }
            // light dismiss: a click outside every open auto popover closes them
            for (var i = open.length - 1; i >= 0; i--) {
                var p = open[i];
                if ((p.getAttribute('popover') || 'auto').toLowerCase() === 'manual') continue;
                var inside = false, n = e.target;
                while (n) { if (n === p) { inside = true; break; } n = n.parentNode; }
                if (!inside) hide(p, true);
            }
        }, false);
        document.addEventListener('keydown', function (e) { if (e.keyCode === 27) for (var i = open.length - 1; i >= 0; i--) if ((open[i].getAttribute('popover') || 'auto').toLowerCase() !== 'manual') hide(open[i], true); }, false);
    })();
    // The engine knows WebGL only under its experimental name; pages ask for 'webgl' (and 'webgl2', which does not exist here)
    if (HCp && HCp.getContext && !HCp.__brGLAlias) {
        HCp.__brGLAlias = true;
        var origGL = HCp.getContext;
        HCp.getContext = function (type, attrs) {
            var ctx = origGL.apply(this, arguments);
            if (!ctx && type === 'webgl') { try { ctx = origGL.call(this, 'experimental-webgl', attrs); } catch (e) {} }
            return ctx;
        };
    }
    // canvas.getContext('bitmaprenderer'): a thin wrapper over the 2D context
    if (HCp && !window.ImageBitmapRenderingContext) {
        var BitmapContext = function ImageBitmapRenderingContext(canvas) { this.canvas = canvas; };
        BitmapContext.prototype.transferFromImageBitmap = function (bitmap) {
            var ctx = this.canvas.getContext('2d');
            if (!ctx) return;
            ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
            if (bitmap) try { ctx.drawImage(bitmap, 0, 0); } catch (e) {}
        };
        window.ImageBitmapRenderingContext = BitmapContext;
        var origGetContext = HCp.getContext;
        HCp.getContext = function (type) {
            if (type === 'bitmaprenderer') return this.__brBitmapContext || (this.__brBitmapContext = new BitmapContext(this));
            return origGetContext.apply(this, arguments);
        };
    }
    if (!window.createImageBitmap) {
        window.ImageBitmap = function ImageBitmap() {};
        window.createImageBitmap = function (source, sx, sy, sw, sh) {
            if (!P) return null;
            return new P(function (resolve, reject) {
                function finish(img) {
                    if (typeof sx === 'number' && typeof sw === 'number') {
                        var c = document.createElement('canvas');
                        c.width = sw; c.height = sh;
                        c.getContext('2d').drawImage(img, sx, sy, sw, sh, 0, 0, sw, sh);
                        img = c;
                    }
                    img.close = noop;
                    resolve(img);
                }
                if (source instanceof Blob) {
                    var url = URL.createObjectURL(source), img = new Image();
                    img.onload = function () { URL.revokeObjectURL(url); finish(img); };
                    img.onerror = function () { URL.revokeObjectURL(url); reject(domException('InvalidStateError', 'The image could not be decoded')); };
                    img.src = url;
                } else if (window.ImageData && source instanceof ImageData) {
                    var c = document.createElement('canvas');
                    c.width = source.width; c.height = source.height;
                    c.getContext('2d').putImageData(source, 0, 0);
                    finish(c);
                } else if (source && (source.tagName === 'IMG' || source.tagName === 'CANVAS' || source.tagName === 'VIDEO')) {
                    if (source.tagName === 'IMG' && !source.complete) { source.addEventListener('load', function () { finish(source); }, false); source.addEventListener('error', function () { reject(domException('InvalidStateError', 'The image could not be decoded')); }, false); }
                    else finish(source);
                } else {
                    reject(domException('InvalidStateError', 'Unsupported image source'));
                }
            });
        };
    }

    // ---- IndexedDB: the WebSQL-backed shim (150 KB) is fetched on first use only
    if (!window.indexedDB && window.openDatabase) {
        var idbLoaded = false, idbLoading = false;
        var idbNames = ['indexedDB', 'IDBKeyRange', 'IDBFactory', 'IDBDatabase', 'IDBObjectStore', 'IDBIndex', 'IDBTransaction', 'IDBRequest', 'IDBOpenDBRequest', 'IDBCursor', 'IDBCursorWithValue', 'IDBVersionChangeEvent'];
        var loadIndexedDB = function () {
            if (idbLoaded || idbLoading) return;
            idbLoading = true;
            for (var i = 0; i < idbNames.length; i++) try { delete window[idbNames[i]]; } catch (e) {}
            try {
                var tag = document.querySelector('script[src*="ios6-browser.invalid/polyfills"]');
                var url = tag ? tag.src.replace(/polyfills(-[0-9a-f]+)?\.js.*$/, 'indexeddbshim$1.js') : 'https://ios6-browser.invalid/indexeddbshim.js';
                var x = new XMLHttpRequest();
                x.open('GET', url, false);
                x.send(null);
                if (x.status === 200 && x.responseText) {
                    (0, eval)(x.responseText);
                    if (window.shimIndexedDB && window.shimIndexedDB.__useShim) window.shimIndexedDB.__useShim();
                }
            } catch (e2) { if (window.console && console.error) console.error('IndexedDB shim failed: ' + e2.message); }
            idbLoaded = true;
            idbLoading = false;
        };
        for (var idbn = 0; idbn < idbNames.length; idbn++) (function (name) {
            try {
                Object.defineProperty(window, name, {
                    configurable: true, enumerable: true,
                    get: function () { loadIndexedDB(); return window[name]; },
                    set: function (v) { try { delete window[name]; } catch (e) {} window[name] = v; }
                });
            } catch (e3) {}
        })(idbNames[idbn]);
    }

    // ---- Workers, storage, files
    if (!window.SharedWorker) window.SharedWorker = function SharedWorker() { throw domException('NotSupportedError', 'SharedWorker is not available'); };
    if (!window.Worklet) window.Worklet = function Worklet() {};
    if (!window.requestFileSystem && !window.webkitRequestFileSystem) {
        window.requestFileSystem = window.webkitRequestFileSystem = function (type, size, ok, err) { setTimeout(function () { if (err) err(domException('SecurityError', 'The file system is not available')); }, 0); };
        window.resolveLocalFileSystemURL = window.webkitResolveLocalFileSystemURL = function (url, ok, err) { setTimeout(function () { if (err) err(domException('NotFoundError', 'not found')); }, 0); };
        window.TEMPORARY = 0; window.PERSISTENT = 1;
    }
    if (navigator.storage && !navigator.storage.persist) { navigator.storage.persist = function () { return resolved(false); }; navigator.storage.persisted = function () { return resolved(false); }; navigator.storage.getDirectory = rejectWith('NotSupportedError', 'no origin private file system'); }
    if (!navigator.locks) navigator.locks = { request: function (name, opts, cb) { if (typeof opts === 'function') cb = opts; var lock = { name: name, mode: 'exclusive' }; return P ? P.resolve().then(function () { return cb(lock); }) : cb(lock); }, query: function () { return resolved({ held: [], pending: [] }); } };
    if (!window.PushManager) { window.PushManager = function PushManager() {}; window.PushManager.supportedContentEncodings = []; window.PushSubscription = function PushSubscription() {}; }
    if (!navigator.registerProtocolHandler) navigator.registerProtocolHandler = noop;
    if (!navigator.registerContentHandler) navigator.registerContentHandler = noop;
    if (!navigator.unregisterProtocolHandler) navigator.unregisterProtocolHandler = noop;
    if (!navigator.setAppBadge) { navigator.setAppBadge = function () { return resolved(); }; navigator.clearAppBadge = function () { return resolved(); }; }
    if (!navigator.wakeLock) navigator.wakeLock = { request: rejectWith('NotAllowedError', 'Wake lock is not available') };
    if (!navigator.vibrate) navigator.vibrate = function () { return false; };
    if (!navigator.getBattery) navigator.getBattery = function () { return resolved({ charging: true, chargingTime: 0, dischargingTime: Infinity, level: 1, addEventListener: noop, removeEventListener: noop, onchargingchange: null, onlevelchange: null }); };
    if (!navigator.permissions) navigator.permissions = { query: function (desc) { var name = desc && desc.name; var state = (name === 'geolocation') ? 'prompt' : 'denied'; return resolved({ state: state, status: state, name: name, onchange: null, addEventListener: noop, removeEventListener: noop }); } };
    if (!navigator.userAgentData) navigator.userAgentData = { brands: [{ brand: 'Safari', version: '6' }], mobile: true, platform: 'iOS', getHighEntropyValues: function () { return resolved({ platform: 'iOS', platformVersion: '6.1', architecture: 'arm', model: '', uaFullVersion: '6.0' }); }, toJSON: function () { return { brands: this.brands, mobile: true, platform: 'iOS' }; } };
    if (!navigator.hardwareConcurrency) try { navigator.hardwareConcurrency = 2; } catch (e) {}
    if (!('deviceMemory' in navigator)) try { navigator.deviceMemory = 0.5; } catch (e) {}
    if (!navigator.scheduling) navigator.scheduling = { isInputPending: function () { return false; } };
    if (!window.scheduler) window.scheduler = { postTask: function (cb, opts) { var delay = opts && opts.delay || 0; return new P(function (res, rej) { setTimeout(function () { try { res(cb()); } catch (e) { rej(e); } }, delay); }); }, yield: function () { return new P(function (res) { setTimeout(res, 0); }); } };
    if (!navigator.cookieEnabled) try { navigator.cookieEnabled = true; } catch (e) {}
    if (!window.cookieStore) window.cookieStore = {
        get: function (name) { var m = document.cookie.match(new RegExp('(?:^|; )' + String(typeof name === 'object' ? name.name : name).replace(/([.*+?^${}()|[\]\\])/g, '\\$1') + '=([^;]*)')); return resolved(m ? { name: typeof name === 'object' ? name.name : name, value: decodeURIComponent(m[1]) } : null); },
        getAll: function () { var out = [], parts = document.cookie ? document.cookie.split('; ') : []; for (var i = 0; i < parts.length; i++) { var eq = parts[i].indexOf('='); out.push({ name: parts[i].slice(0, eq), value: decodeURIComponent(parts[i].slice(eq + 1)) }); } return resolved(out); },
        set: function (name, value) { var o = typeof name === 'object' ? name : { name: name, value: value }; var s = o.name + '=' + encodeURIComponent(o.value) + '; path=' + (o.path || '/'); if (o.expires) s += '; expires=' + new Date(o.expires).toUTCString(); if (o.domain) s += '; domain=' + o.domain; document.cookie = s; return resolved(); },
        'delete': function (name) { var n = typeof name === 'object' ? name.name : name; document.cookie = n + '=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT'; return resolved(); },
        addEventListener: noop, removeEventListener: noop
    };

    // ---- Editing, interaction, security attributes
    defineBoolAttrProp(Ep, 'spellcheck');
    defineBoolAttrProp(Ep, 'inert');
    defineAttrProp(Ep, 'enterKeyHint', 'enterkeyhint');
    defineAttrProp(Ep, 'inputMode', 'inputmode');
    defineAttrProp(Ep, 'autocapitalize');
    if (window.HTMLScriptElement) { defineAttrProp(window.HTMLScriptElement.prototype, 'integrity'); defineAttrProp(window.HTMLScriptElement.prototype, 'referrerPolicy', 'referrerpolicy'); }
    if (window.HTMLLinkElement) { defineAttrProp(window.HTMLLinkElement.prototype, 'integrity'); defineAttrProp(window.HTMLLinkElement.prototype, 'as'); defineAttrProp(window.HTMLLinkElement.prototype, 'referrerPolicy', 'referrerpolicy'); }
    if (window.HTMLIFrameElement) { defineAttrProp(window.HTMLIFrameElement.prototype, 'allow'); defineAttrProp(window.HTMLIFrameElement.prototype, 'loading'); defineAttrProp(window.HTMLIFrameElement.prototype, 'referrerPolicy', 'referrerpolicy'); }
    if (window.HTMLAnchorElement) { defineAttrProp(window.HTMLAnchorElement.prototype, 'download'); defineAttrProp(window.HTMLAnchorElement.prototype, 'referrerPolicy', 'referrerpolicy'); }
    if (!window.ClipboardEvent) window.ClipboardEvent = function ClipboardEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, !!(init && init.bubbles), !!(init && init.cancelable)); e.clipboardData = (init && init.clipboardData) || null; return e; };
    if (!window.DataTransfer) {
        window.DataTransfer = function DataTransfer() { this.__data = {}; this.dropEffect = 'none'; this.effectAllowed = 'none'; this.files = []; this.items = []; this.types = []; };
        window.DataTransfer.prototype = {
            setData: function (type, value) { this.__data[type] = String(value); if (this.types.indexOf(type) < 0) this.types.push(type); },
            getData: function (type) { return this.__data[type] || ''; },
            clearData: function (type) { if (type) { delete this.__data[type]; } else { this.__data = {}; this.types = []; } },
            setDragImage: noop
        };
    }
    if (!window.DragEvent) window.DragEvent = function DragEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, !!(init && init.bubbles), !!(init && init.cancelable)); e.dataTransfer = (init && init.dataTransfer) || new window.DataTransfer(); return e; };
    if (!window.InputEvent) window.InputEvent = function InputEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, !!(init && init.bubbles), !!(init && init.cancelable)); e.data = (init && init.data) || null; e.inputType = (init && init.inputType) || ''; e.isComposing = false; return e; };
    if (!window.FocusEvent) window.FocusEvent = function FocusEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, !!(init && init.bubbles), !!(init && init.cancelable)); e.relatedTarget = (init && init.relatedTarget) || null; return e; };
    if (!window.SecurityPolicyViolationEvent) window.SecurityPolicyViolationEvent = function SecurityPolicyViolationEvent() {};
    if (!window.ResizeObserverEntry) window.ResizeObserverEntry = function ResizeObserverEntry() {};
    if (!window.Sanitizer) window.Sanitizer = function Sanitizer() { this.sanitize = function (frag) { return frag; }; this.sanitizeFor = function (el, html) { var e = document.createElement(el); e.innerHTML = html; return e; }; };
    if (Ep && !Ep.setHTML) Ep.setHTML = function (html) { this.innerHTML = html; };
    if (!window.trustedTypes) window.trustedTypes = { createPolicy: function (name, rules) { rules = rules || {}; return { name: name, createHTML: function (s) { return rules.createHTML ? rules.createHTML(s) : s; }, createScript: function (s) { return rules.createScript ? rules.createScript(s) : s; }, createScriptURL: function (s) { return rules.createScriptURL ? rules.createScriptURL(s) : s; } }; }, isHTML: function () { return false; }, isScript: function () { return false; }, isScriptURL: function () { return false; }, emptyHTML: '', emptyScript: '', getAttributeType: function () { return null; }, getPropertyType: function () { return null; }, defaultPolicy: null };

    // ---- Elements the old parser does not know get real constructors, prototypes and behaviour
    var HEp = window.HTMLElement && window.HTMLElement.prototype;
    var protoSwapWorks = false;
    try {
        var probeEl = document.createElement('x-probe');
        var probeProto = Object.create(Object.getPrototypeOf(probeEl));
        probeProto.__brProbe = 1;
        probeEl.__proto__ = probeProto;
        protoSwapWorks = probeEl.__brProbe === 1;
    } catch (e) {}
    if (HEp && protoSwapWorks) {
        var upgrades = {};   // tag -> prototype
        var createElementBefore = document.createElement;
        var defineElementClass = function (tag, className, define) {
            // only elements this engine does not know get a synthetic class
            try { if (!window.HTMLUnknownElement || !(createElementBefore.call(document, tag) instanceof window.HTMLUnknownElement)) return; } catch (e0) { return; }
            var proto = Object.create(HEp);
            if (className) {
                var Ctor = function () { throw new TypeError('Illegal constructor'); };
                try { Object.defineProperty(Ctor, 'name', { value: className }); } catch (e) {}
                Ctor.prototype = proto;
                proto.constructor = Ctor;
                if (!window[className] || typeof window[className] === 'function' && !window[className].prototype.__brReal) window[className] = Ctor;
                proto.__brReal = true;
            }
            if (define) define(proto);
            upgrades[tag] = proto;
        };
        var attrProp = function (proto, name, attr) { defineAttrProp(proto, name, attr || name.toLowerCase()); };
        var numProp = function (proto, name, fallback, after) {
            try {
                Object.defineProperty(proto, name, {
                    get: function () { var v = parseFloat(this.getAttribute(name)); return isNaN(v) ? (typeof fallback === 'function' ? fallback.call(this) : fallback) : v; },
                    set: function (v) { this.setAttribute(name, String(v)); if (after) after.call(this); },
                    configurable: true
                });
            } catch (e) {}
        };
        var paintBar = function (el) {
            var value = parseFloat(el.getAttribute('value')), min = parseFloat(el.getAttribute('min')), max = parseFloat(el.getAttribute('max'));
            if (isNaN(min)) min = 0;
            if (isNaN(max)) max = 1;
            if (max <= min) max = min + 1;
            if (isNaN(value)) { el.style.backgroundImage = 'none'; return; }
            var pct = Math.max(0, Math.min(100, (value - min) / (max - min) * 100));
            var color = el.tagName === 'METER' ? (pct < 34 ? '#e2493b' : pct < 67 ? '#e7b416' : '#2dc937') : '#4a90e2';
            el.style.backgroundImage = '-webkit-linear-gradient(left, ' + color + ' ' + pct + '%, transparent ' + pct + '%)';
        };
        addStyle('main{display:block}picture{display:inline}' +
                 'progress,meter{display:inline-block;width:10em;height:1em;vertical-align:-0.2em;background-color:#e6e6e6;border:1px solid #bbb;border-radius:3px;overflow:hidden;-webkit-box-sizing:border-box;box-sizing:border-box;background-repeat:no-repeat}' +
                 'datalist{display:none}time,data{display:inline}menu{display:block;list-style:none;margin:0;padding:0}');
        defineElementClass('main', null, null);
        defineElementClass('time', 'HTMLTimeElement', function (p) { attrProp(p, 'dateTime', 'datetime'); });
        defineElementClass('data', 'HTMLDataElement', function (p) { attrProp(p, 'value'); });
        defineElementClass('picture', 'HTMLPictureElement', null);
        defineElementClass('progress', 'HTMLProgressElement', function (p) {
            numProp(p, 'value', NaN, function () { paintBar(this); });
            numProp(p, 'max', 1, function () { paintBar(this); });
            try { Object.defineProperty(p, 'position', { get: function () { var v = this.value; return isNaN(v) ? -1 : Math.max(0, Math.min(1, v / (this.max || 1))); }, configurable: true }); } catch (e) {}
            try { Object.defineProperty(p, 'labels', { get: function () { return []; }, configurable: true }); } catch (e2) {}
        });
        defineElementClass('meter', 'HTMLMeterElement', function (p) {
            var names = ['value', 'min', 'max', 'low', 'high', 'optimum'];
            for (var i = 0; i < names.length; i++) numProp(p, names[i], names[i] === 'max' ? 1 : 0, function () { paintBar(this); });
            try { Object.defineProperty(p, 'labels', { get: function () { return []; }, configurable: true }); } catch (e) {}
        });
        defineElementClass('datalist', 'HTMLDataListElement', function (p) {
            try { Object.defineProperty(p, 'options', { get: function () { return this.getElementsByTagName('option'); }, configurable: true }); } catch (e) {}
        });
        var defineMenuProps = function (p) {
            try {
                Object.defineProperty(p, 'type', {
                    get: function () {
                        var t = (this.getAttribute('type') || '').toLowerCase();
                        if (t === 'context' || t === 'toolbar') return t;
                        // a menu without a type inherits "context" from an enclosing context menu
                        var parent = this.parentNode;
                        while (parent && parent.nodeType === 1) {
                            if (parent.tagName === 'MENU') return parent.type;
                            parent = parent.parentNode;
                        }
                        return 'toolbar';
                    },
                    set: function (v) { this.setAttribute('type', String(v)); },
                    configurable: true
                });
            } catch (e) {}
            attrProp(p, 'label');
        };
        defineElementClass('menuitem', 'HTMLMenuItemElement', function (p) { attrProp(p, 'label'); attrProp(p, 'icon'); attrProp(p, 'type'); defineBoolAttrProp(p, 'disabled'); defineBoolAttrProp(p, 'checked'); defineBoolAttrProp(p, 'default'); });
        if (window.HTMLMenuElement && window.HTMLMenuElement.prototype && !('type' in document.createElement('menu'))) defineMenuProps(window.HTMLMenuElement.prototype);
        else defineElementClass('menu', 'HTMLMenuElement', defineMenuProps);
        defineElementClass('track', 'HTMLTrackElement', function (p) {
            attrProp(p, 'kind'); attrProp(p, 'src'); attrProp(p, 'srclang'); attrProp(p, 'label');
            defineBoolAttrProp(p, 'default');
            try { Object.defineProperty(p, 'track', { get: function () { return this.__brTrack || (this.__brTrack = { kind: this.kind || 'subtitles', label: this.label, language: this.srclang, mode: 'disabled', cues: null, activeCues: null, addCue: noop, removeCue: noop, addEventListener: noop, removeEventListener: noop }); }, configurable: true }); } catch (e) {}
            try { Object.defineProperty(p, 'readyState', { get: function () { return 0; }, configurable: true }); } catch (e2) {}
        });
        if (window.dialogPolyfill) defineElementClass('dialog', 'HTMLDialogElement', null);
        var upgradeKnownElement = function (el) {
            var proto = upgrades[el.tagName ? el.tagName.toLowerCase() : ''];
            if (!proto || Object.getPrototypeOf(el) === proto) return;
            try { el.__proto__ = proto; } catch (e) {}
            if (el.tagName === 'PROGRESS' || el.tagName === 'METER') paintBar(el);
        };
        var upgradeKnownTree = function (root) {
            if (root.nodeType === 1) upgradeKnownElement(root);
            if (!root.querySelectorAll) return;
            var list = root.querySelectorAll(Object.keys(upgrades).join(','));
            for (var i = 0; i < list.length; i++) upgradeKnownElement(list[i]);
        };
        if (Object.keys(upgrades).length) {
            document.createElement = function (name) {
                var el = createElementBefore.apply(document, arguments);
                if (typeof name === 'string' && upgrades[name.toLowerCase()]) upgradeKnownElement(el);
                return el;
            };
            onReady(function () { upgradeKnownTree(document); });
            observeAdded(upgradeKnownTree);
        }
        if (window.MutationObserver) {
            var barObserver = new MutationObserver(function (records) {
                for (var r = 0; r < records.length; r++) { var t = records[r].target; if (t && (t.tagName === 'PROGRESS' || t.tagName === 'METER')) paintBar(t); }
            });
            onReady(function () { try { barObserver.observe(document.documentElement, { attributes: true, subtree: true, attributeFilter: ['value', 'max', 'min'] }); } catch (e) {} });
        }
        // <input list="..."> and <fieldset>.elements
        if (window.HTMLInputElement) {
            var IPp = window.HTMLInputElement.prototype;
            if (!('list' in IPp)) try { Object.defineProperty(IPp, 'list', { get: function () { var id = this.getAttribute('list'); return id ? document.getElementById(id) : null; }, configurable: true }); } catch (e) {}
            defineBoolAttrProp(IPp, 'webkitdirectory');
            defineBoolAttrProp(IPp, 'directory');
            if (!window.Directory) window.Directory = function Directory() { this.name = ''; this.path = ''; };
        }
        if (window.HTMLFieldSetElement && !('elements' in window.HTMLFieldSetElement.prototype)) {
            try { Object.defineProperty(window.HTMLFieldSetElement.prototype, 'elements', { get: function () { return this.querySelectorAll('input,select,textarea,button,fieldset,object,output'); }, configurable: true }); } catch (e) {}
        }
    }
    // custom elements v0 on top of the v1 shim
    if (!document.registerElement) {
        document.registerElement = function (name, options) {
            options = options || {};
            var proto = options.prototype || HEp;
            var Ctor = function () { return document.createElement(name); };
            Ctor.prototype = proto;
            var wrapped = function () {};
            wrapped.prototype = proto;
            wrapped.observedAttributes = [];
            var v0 = function () {
                var el = this;
                try { if (proto.createdCallback) proto.createdCallback.call(el); } catch (e) {}
                try { if (proto.attachedCallback) proto.attachedCallback.call(el); } catch (e2) {}
            };
            v0.prototype = proto;
            try { window.customElements.define(name, v0); } catch (e3) {}
            return Ctor;
        };
    }
    // drag and drop handler properties (touch devices have no native drag events)
    var dragNames = ['drag', 'dragstart', 'dragenter', 'dragover', 'dragleave', 'dragend', 'drop'];
    var defineDragHandlers = function (obj) {
        if (!obj || ('ondragstart' in obj)) return;
        for (var i = 0; i < dragNames.length; i++) (function (type) {
            try {
                Object.defineProperty(obj, 'on' + type, {
                    get: function () { return this['__on' + type] || null; },
                    set: function (fn) { var old = this['__on' + type]; if (old) this.removeEventListener(type, old, false); this['__on' + type] = typeof fn === 'function' ? fn : null; if (fn) this.addEventListener(type, fn, false); },
                    configurable: true
                });
            } catch (e) {}
        })(dragNames[i]);
    };
    defineDragHandlers(window); defineDragHandlers(document); defineDragHandlers(Ep);
    defineBoolAttrProp(Ep, 'draggable');
    defineAttrProp(Ep, 'dropzone');
    if (!window.WriteableStream && window.WritableStream) window.WriteableStream = window.WritableStream;   // feature checks with the old spelling
    if (!window.webauthn) window.webauthn = { getAssertion: rejectWith('NotSupportedError', 'Web Authentication is not available'), makeCredential: rejectWith('NotSupportedError', 'Web Authentication is not available') };
    if (!window.AuthenticatorAttestationResponse) { window.AuthenticatorAttestationResponse = function AuthenticatorAttestationResponse() {}; window.AuthenticatorAssertionResponse = function AuthenticatorAssertionResponse() {}; }
    if (window.speechSynthesis && window.speechSynthesis.__brStub !== false && !window.speechSynthesis.getVoices().length) {
        var fakeVoice = { voiceURI: 'default', name: 'Default', lang: (navigator.language || 'en-US'), localService: true, 'default': true };
        window.speechSynthesis.getVoices = function () { return [fakeVoice]; };
    }
    // script execution events (fired after the script has run, which is when the old engine tells us)
    observeAdded(function (el) {
        if (el.tagName === 'SCRIPT' && el.src && !el.__brExecEvents) {
            el.__brExecEvents = true;
            el.addEventListener('load', function () { fire(el, 'beforescriptexecute'); fire(el, 'afterscriptexecute'); }, false);
        }
    });

    // ---- Newer DOM conveniences: relList, translate, accessKey, minLength, reportValidity, resource hints
    var makeTokenList = function (el, attr) {
        var list = {
            get length() { return this.__tokens().length; },
            __tokens: function () { var v = el.getAttribute(attr) || ''; return v.split(/\s+/).filter(function (t) { return t; }); },
            item: function (i) { return this.__tokens()[i] || null; },
            contains: function (t) { return this.__tokens().indexOf(String(t)) >= 0; },
            add: function () { var t = this.__tokens(); for (var i = 0; i < arguments.length; i++) if (t.indexOf(String(arguments[i])) < 0) t.push(String(arguments[i])); el.setAttribute(attr, t.join(' ')); },
            remove: function () { var t = this.__tokens(); for (var i = 0; i < arguments.length; i++) { var k = t.indexOf(String(arguments[i])); if (k >= 0) t.splice(k, 1); } el.setAttribute(attr, t.join(' ')); },
            toggle: function (token, force) { var has = this.contains(token); if (force === undefined ? has : !force) { if (has) this.remove(token); return false; } this.add(token); return true; },
            replace: function (a, b) { if (!this.contains(a)) return false; this.remove(a); this.add(b); return true; },
            supports: function (token) { return ['alternate', 'author', 'bookmark', 'help', 'icon', 'license', 'next', 'nofollow', 'noreferrer', 'prev', 'search', 'stylesheet', 'tag', 'prefetch', 'preconnect', 'preload', 'dns-prefetch', 'modulepreload'].indexOf(String(token).toLowerCase()) >= 0; },
            toString: function () { return el.getAttribute(attr) || ''; },
            forEach: function (fn, ctx) { var t = this.__tokens(); for (var i = 0; i < t.length; i++) fn.call(ctx, t[i], i, this); }
        };
        try { Object.defineProperty(list, 'value', { get: function () { return el.getAttribute(attr) || ''; }, set: function (v) { el.setAttribute(attr, v); } }); } catch (e) {}
        return list;
    };
    var relOwners = [window.HTMLAnchorElement, window.HTMLLinkElement, window.HTMLAreaElement];
    for (var ro = 0; ro < relOwners.length; ro++) {
        if (!relOwners[ro] || !relOwners[ro].prototype || ('relList' in relOwners[ro].prototype)) continue;
        try { Object.defineProperty(relOwners[ro].prototype, 'relList', { get: function () { return this.__brRelList || (this.__brRelList = makeTokenList(this, 'rel')); }, configurable: true }); } catch (e) {}
    }
    if (Ep && !('translate' in document.createElement('div'))) {
        try { Object.defineProperty(HEp || Ep, 'translate', { get: function () { var v = (this.getAttribute('translate') || '').toLowerCase(); return v !== 'no'; }, set: function (v) { this.setAttribute('translate', v ? 'yes' : 'no'); }, configurable: true }); } catch (e) {}
    }
    if (HEp && !('accessKey' in document.createElement('div'))) defineAttrProp(HEp, 'accessKey', 'accesskey');
    if (HEp && !('accessKeyLabel' in document.createElement('div'))) try { Object.defineProperty(HEp, 'accessKeyLabel', { get: function () { return this.getAttribute('accesskey') || ''; }, configurable: true }); } catch (e) {}
    if (window.HTMLTextAreaElement && !('minLength' in document.createElement('textarea'))) {
        try { Object.defineProperty(window.HTMLTextAreaElement.prototype, 'minLength', { get: function () { var v = parseInt(this.getAttribute('minlength'), 10); return isNaN(v) ? -1 : v; }, set: function (v) { this.setAttribute('minlength', v); }, configurable: true }); } catch (e) {}
    }
    if (window.HTMLInputElement && !('minLength' in document.createElement('input'))) {
        try { Object.defineProperty(window.HTMLInputElement.prototype, 'minLength', { get: function () { var v = parseInt(this.getAttribute('minlength'), 10); return isNaN(v) ? -1 : v; }, set: function (v) { this.setAttribute('minlength', v); }, configurable: true }); } catch (e) {}
    }
    var validityOwners = [window.HTMLFormElement, window.HTMLInputElement, window.HTMLSelectElement, window.HTMLTextAreaElement, window.HTMLButtonElement];
    for (var vo = 0; vo < validityOwners.length; vo++) {
        var VP = validityOwners[vo] && validityOwners[vo].prototype;
        if (!VP || VP.reportValidity || !VP.checkValidity) continue;
        VP.reportValidity = function () {
            var ok = this.checkValidity();
            if (!ok) {
                var bad = this.tagName === 'FORM' ? this.querySelector(':invalid') : this;
                try { if (bad && bad.focus) bad.focus(); } catch (e) {}
            }
            return ok;
        };
    }
    // sensors and hardware access: present, permission always denied
    var sensorError = function (self) { setTimeout(function () { var ev = { type: 'error', error: domException('NotAllowedError', 'Sensor access is not available') }; if (self.onerror) self.onerror(ev); for (var i = 0; i < self.__l.length; i++) self.__l[i](ev); }, 0); };
    var sensorNames = ['Sensor', 'Accelerometer', 'LinearAccelerationSensor', 'GravitySensor', 'Gyroscope', 'Magnetometer', 'AbsoluteOrientationSensor', 'RelativeOrientationSensor', 'AmbientLightSensor'];
    for (var sn = 0; sn < sensorNames.length; sn++) (function (name) {
        if (window[name]) return;
        var S = function () { this.activated = false; this.hasReading = false; this.timestamp = null; this.onreading = this.onerror = this.onactivate = null; this.__l = []; };
        S.prototype.start = function () { sensorError(this); };
        S.prototype.stop = noop;
        S.prototype.addEventListener = function (t, f) { if (t === 'error') this.__l.push(f); };
        S.prototype.removeEventListener = noop;
        try { Object.defineProperty(S, 'name', { value: name }); } catch (e) {}
        window[name] = S;
    })(sensorNames[sn]);
    if (!navigator.bluetooth) navigator.bluetooth = { requestDevice: rejectWith('NotFoundError', 'Bluetooth is not available'), getAvailability: function () { return resolved(false); }, getDevices: function () { return resolved([]); }, addEventListener: noop, removeEventListener: noop };
    if (!navigator.usb) navigator.usb = { requestDevice: rejectWith('NotFoundError', 'USB is not available'), getDevices: function () { return resolved([]); }, addEventListener: noop, removeEventListener: noop };
    if (!navigator.serial) navigator.serial = { requestPort: rejectWith('NotFoundError', 'Serial is not available'), getPorts: function () { return resolved([]); }, addEventListener: noop, removeEventListener: noop };
    if (!navigator.hid) navigator.hid = { requestDevice: function () { return resolved([]); }, getDevices: function () { return resolved([]); }, addEventListener: noop, removeEventListener: noop };
    if (!window.NDEFReader) { window.NDEFReader = function NDEFReader() { this.onreading = null; this.onreadingerror = null; }; window.NDEFReader.prototype.scan = rejectWith('NotSupportedError', 'NFC is not available'); window.NDEFReader.prototype.write = rejectWith('NotSupportedError', 'NFC is not available'); window.NDEFReader.prototype.addEventListener = noop; window.NDEFReader.prototype.removeEventListener = noop; window.NDEFMessage = function NDEFMessage() {}; window.NDEFRecord = function NDEFRecord() {}; }
    if (!navigator.gpu) navigator.gpu = { requestAdapter: function () { return resolved(null); }, getPreferredCanvasFormat: function () { return 'bgra8unorm'; }, wgslLanguageFeatures: [] };
    if (!window.GPU) window.GPU = function GPU() {};
    if (!window.XRSystem) { window.XRSystem = function XRSystem() {}; window.XRSession = function XRSession() {}; }
    if (window.HTMLMediaElement && !window.HTMLMediaElement.prototype.requestPictureInPicture) { window.HTMLMediaElement.prototype.requestPictureInPicture = rejectWith('NotSupportedError', 'Picture in picture is not available'); if (!('pictureInPictureEnabled' in document)) try { Object.defineProperty(document, 'pictureInPictureEnabled', { get: function () { return false; }, configurable: true }); document.exitPictureInPicture = rejectWith('InvalidStateError', 'not in picture in picture'); } catch (e) {} }
    if (window.MathMLElement === undefined) window.MathMLElement = function MathMLElement() {};

    // ---- Everyday DOM differences that break modern scripts on the old engine
    // addEventListener(type, fn, {passive, once, capture, signal}): the old engine reads the options object as capture=true
    var patchEventTarget = function (obj) {
        if (!obj || !obj.addEventListener || obj.__brListenerOptions) return;
        var origAdd = obj.addEventListener, origRemove = obj.removeEventListener;
        obj.addEventListener = function (type, fn, options) {
            if (!fn) return;
            if (options && typeof options === 'object') {
                var capture = !!options.capture, actual = fn;
                if (options.once) {
                    var self = this;
                    actual = fn.__brOnce || (fn.__brOnce = function (ev) { self.removeEventListener(type, fn, capture); return typeof fn === 'function' ? fn.call(this, ev) : fn.handleEvent(ev); });
                }
                if (options.signal) {
                    if (options.signal.aborted) return;
                    var target = this;
                    options.signal.addEventListener('abort', function () { target.removeEventListener(type, fn, capture); });
                }
                return origAdd.call(this, type, actual, capture);
            }
            return origAdd.call(this, type, fn, !!options);
        };
        obj.removeEventListener = function (type, fn, options) {
            var capture = options && typeof options === 'object' ? !!options.capture : !!options;
            if (fn && fn.__brOnce) origRemove.call(this, type, fn.__brOnce, capture);
            return origRemove.call(this, type, fn, capture);
        };
        obj.__brListenerOptions = true;
    };
    var listenerTargets = [Np, window, window.XMLHttpRequest && window.XMLHttpRequest.prototype, window.XMLHttpRequestUpload && window.XMLHttpRequestUpload.prototype,
                           window.WebSocket && window.WebSocket.prototype, window.EventSource && window.EventSource.prototype, window.FileReader && window.FileReader.prototype,
                           window.MessagePort && window.MessagePort.prototype, window.Worker && window.Worker.prototype, window.MediaQueryList && window.MediaQueryList.prototype,
                           window.EventTarget && window.EventTarget.prototype];
    for (var lt = 0; lt < listenerTargets.length; lt++) patchEventTarget(listenerTargets[lt]);
    // classList.add('a', 'b') only added the first class
    if (window.DOMTokenList && window.DOMTokenList.prototype) {
        var probeList = document.createElement('div');
        probeList.classList.add('a', 'b');
        if (!probeList.classList.contains('b')) {
            var TLp = window.DOMTokenList.prototype, origAddClass = TLp.add, origRemoveClass = TLp.remove;
            TLp.add = function () { for (var i = 0; i < arguments.length; i++) origAddClass.call(this, arguments[i]); };
            TLp.remove = function () { for (var i = 0; i < arguments.length; i++) origRemoveClass.call(this, arguments[i]); };
        }
    }
    // getBoundingClientRect().x / .y
    if (Ep && Ep.getBoundingClientRect) {
        var probeRect = document.documentElement.getBoundingClientRect();
        if (probeRect && !('x' in probeRect)) {
            var origRect = Ep.getBoundingClientRect;
            Ep.getBoundingClientRect = function () {
                var r = origRect.apply(this, arguments);
                return { x: r.left, y: r.top, left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height, toJSON: function () { return this; } };
            };
            if (window.Range && window.Range.prototype.getBoundingClientRect) {
                var origRangeRect = window.Range.prototype.getBoundingClientRect;
                window.Range.prototype.getBoundingClientRect = function () { var r = origRangeRect.apply(this, arguments); return { x: r.left, y: r.top, left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
            }
        }
    }
    // ':scope' in selectors
    var scopeSupported = false;
    try { document.documentElement.querySelector(':scope'); scopeSupported = true; } catch (e) {}
    if (!scopeSupported) {
        var fixScope = function (sel) { return typeof sel === 'string' && sel.indexOf(':scope') >= 0 ? sel.replace(/:scope\b\s*>?/g, function (m) { return m.indexOf('>') >= 0 ? ':scope-child' : ''; }) : sel; };
        var scopedQuery = function (orig) {
            return function (sel) {
                if (typeof sel === 'string' && sel.indexOf(':scope') >= 0) {
                    var el = this, tmpId = false;
                    if (el.nodeType === 1) {
                        if (!el.id) { el.id = 'br-scope-' + Math.random().toString(36).slice(2); tmpId = true; }
                        var rewritten = sel.replace(/:scope\b/g, '#' + el.id);
                        try { return orig.call(el.parentNode || document, rewritten); } finally { if (tmpId) el.removeAttribute('id'); }
                    }
                    return orig.call(this, sel.replace(/:scope\b\s*/g, ''));
                }
                return orig.call(this, sel);
            };
        };
        var queryOwners = [Ep, window.Document && window.Document.prototype, window.DocumentFragment && window.DocumentFragment.prototype];
        for (var qo = 0; qo < queryOwners.length; qo++) {
            if (!queryOwners[qo]) continue;
            if (queryOwners[qo].querySelector) queryOwners[qo].querySelector = scopedQuery(queryOwners[qo].querySelector);
            if (queryOwners[qo].querySelectorAll) queryOwners[qo].querySelectorAll = scopedQuery(queryOwners[qo].querySelectorAll);
        }
    }
    // KeyboardEvent.key from keyCode
    if (window.KeyboardEvent && window.KeyboardEvent.prototype && !('key' in window.KeyboardEvent.prototype)) {
        var keyNames = { 8: 'Backspace', 9: 'Tab', 13: 'Enter', 16: 'Shift', 17: 'Control', 18: 'Alt', 20: 'CapsLock', 27: 'Escape', 32: ' ', 33: 'PageUp', 34: 'PageDown', 35: 'End', 36: 'Home', 37: 'ArrowLeft', 38: 'ArrowUp', 39: 'ArrowRight', 40: 'ArrowDown', 45: 'Insert', 46: 'Delete', 91: 'Meta', 93: 'ContextMenu', 186: ';', 187: '=', 188: ',', 189: '-', 190: '.', 191: '/', 192: '`', 219: '[', 220: '\\', 221: ']', 222: "'" };
        try {
            Object.defineProperty(window.KeyboardEvent.prototype, 'key', { get: function () {
                var c = this.keyCode || this.which || 0;
                if (keyNames[c]) return keyNames[c];
                if (c >= 112 && c <= 123) return 'F' + (c - 111);
                if (c >= 48 && c <= 57) return String.fromCharCode(c);
                if (c >= 65 && c <= 90) return this.shiftKey ? String.fromCharCode(c) : String.fromCharCode(c + 32);
                if (c >= 96 && c <= 105) return String(c - 96);
                return this.keyIdentifier && this.keyIdentifier.indexOf('U+') === 0 ? String.fromCharCode(parseInt(this.keyIdentifier.slice(2), 16)) : 'Unidentified';
            }, configurable: true });
            Object.defineProperty(window.KeyboardEvent.prototype, 'code', { get: function () { var k = this.key; return k.length === 1 && /[a-z]/i.test(k) ? 'Key' + k.toUpperCase() : k.length === 1 && /[0-9]/.test(k) ? 'Digit' + k : k === ' ' ? 'Space' : k; }, configurable: true });
        } catch (e) {}
    }
    if (window.Event && window.Event.prototype && !window.Event.prototype.composedPath) {
        window.Event.prototype.composedPath = function () { var path = [], n = this.target; while (n) { path.push(n); n = n.parentNode || (n === document ? window : null); } if (path[path.length - 1] !== window) path.push(window); return path; };
    }
    if (Ep && !Ep.insertAdjacentElement) {
        Ep.insertAdjacentElement = function (position, el) {
            var p = String(position).toLowerCase();
            if (p === 'beforebegin') this.parentNode.insertBefore(el, this);
            else if (p === 'afterbegin') this.insertBefore(el, this.firstChild);
            else if (p === 'beforeend') this.appendChild(el);
            else if (p === 'afterend') this.parentNode.insertBefore(el, this.nextSibling);
            return el;
        };
        Ep.insertAdjacentText = function (position, text) { return this.insertAdjacentElement(position, document.createTextNode(text)); };
    }
    var collectionProtos = [window.NodeList && window.NodeList.prototype, window.HTMLCollection && window.HTMLCollection.prototype];
    for (var cp = 0; cp < collectionProtos.length; cp++) {
        if (!collectionProtos[cp]) continue;
        if (!collectionProtos[cp].forEach) collectionProtos[cp].forEach = Array.prototype.forEach;
        if (!collectionProtos[cp].entries) collectionProtos[cp].entries = function () { return Array.prototype.slice.call(this).entries(); };
        if (!collectionProtos[cp].keys) collectionProtos[cp].keys = function () { return Array.prototype.slice.call(this).keys(); };
        if (!collectionProtos[cp].values) collectionProtos[cp].values = function () { return Array.prototype.slice.call(this).values(); };
    }
    if (!String.prototype.trimStart) { String.prototype.trimStart = String.prototype.trimLeft || function () { return this.replace(/^\s+/, ''); }; String.prototype.trimEnd = String.prototype.trimRight || function () { return this.replace(/\s+$/, ''); }; }
    if (!Number.parseFloat) Number.parseFloat = parseFloat;
    if (!Number.parseInt) Number.parseInt = parseInt;
    if (!String.prototype.replaceAll) {
        String.prototype.replaceAll = function (search, replacement) {
            if (search instanceof RegExp) { if (!search.global) throw new TypeError('replaceAll must be called with a global RegExp'); return this.replace(search, replacement); }
            if (typeof replacement === 'function') { var s = String(this), out = '', idx = 0, pos; search = String(search); while ((pos = s.indexOf(search, idx)) >= 0) { out += s.slice(idx, pos) + replacement(search, pos, s); idx = pos + search.length; if (!search.length) { if (idx >= s.length) break; out += s.charAt(idx); idx++; } } return out + s.slice(idx); }
            return String(this).split(String(search)).join(String(replacement).replace(/\$/g, '$$$$'));
        };
    }
    if (!('origin' in window.location)) try { Object.defineProperty(window.location, 'origin', { get: function () { return location.protocol + '//' + location.host; } }); } catch (e) {}
    if (window.history && !('scrollRestoration' in window.history)) try { window.history.scrollRestoration = 'auto'; } catch (e) {}
    if (!('isSecureContext' in window)) try { window.isSecureContext = location.protocol === 'https:' || location.hostname === 'localhost'; } catch (e) {}

    // Host object wrappers that carry our added properties must not be collected and recreated without them
    try { window.__brKeepAlive = [window.navigator, window.crypto, window.screen, window.history, window.performance, window.localStorage, window.sessionStorage, navigator.mediaDevices, navigator.geolocation]; } catch (e) {}

    // ---- CSSOM and view interfaces the old engine lacks or hides (browserscore inventory)
    try {
        if (Ep && typeof Ep.scrollTo !== 'function') {
            Ep.scrollTo = function (x, y) { if (x && typeof x === 'object') { y = x.top; x = x.left; } if (x !== undefined && x !== null) this.scrollLeft = x; if (y !== undefined && y !== null) this.scrollTop = y; };
            Ep.scroll = Ep.scrollTo;
            Ep.scrollBy = function (x, y) { if (x && typeof x === 'object') { y = x.top; x = x.left; } this.scrollLeft += x || 0; this.scrollTop += y || 0; };
        }
        if (window.matchMedia && !window.MediaQueryList) {
            var mqlProto = Object.getPrototypeOf(window.matchMedia('all'));
            window.MediaQueryList = function MediaQueryList() {};
            window.MediaQueryList.prototype = mqlProto;
            if (!('onchange' in mqlProto)) try { Object.defineProperty(mqlProto, 'onchange', { get: function () { return this.__onchange || null; }, set: function (f) { if (this.__onchange) this.removeListener(this.__onchange); this.__onchange = f; if (f) this.addListener(f); }, configurable: true }); } catch (e0) {}
        }
        if (!window.MediaQueryListEvent) window.MediaQueryListEvent = function MediaQueryListEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, false); e.media = init && init.media || ''; e.matches = !!(init && init.matches); return e; };
        if (!window.Screen && window.screen) { window.Screen = function Screen() {}; window.Screen.prototype = Object.getPrototypeOf(window.screen); }
        if (window.visualViewport && !window.VisualViewport) {
            window.VisualViewport = function VisualViewport() {};
            var vv = window.visualViewport, vvProto = window.VisualViewport.prototype;
            vvProto.addEventListener = noop; vvProto.removeEventListener = noop; vvProto.dispatchEvent = function () { return true; };
            var vvNames = ['width', 'height', 'scale', 'offsetLeft', 'offsetTop', 'pageLeft', 'pageTop', 'onresize', 'onscroll', 'onscrollend'];
            for (var vvi = 0; vvi < vvNames.length; vvi++) if (!(vvNames[vvi] in vvProto)) vvProto[vvNames[vvi]] = vv[vvNames[vvi]] === undefined ? null : vv[vvNames[vvi]];
            try { vv.__proto__ = vvProto; } catch (e1) {}
        }
        if (window.CSSRule) {
            var ruleConsts = { KEYFRAMES_RULE: 7, KEYFRAME_RULE: 8, MARGIN_RULE: 9, NAMESPACE_RULE: 10, COUNTER_STYLE_RULE: 11, SUPPORTS_RULE: 12, FONT_FEATURE_VALUES_RULE: 14, VIEWPORT_RULE: 15, REGION_STYLE_RULE: 16 };
            for (var rc in ruleConsts) if (ruleConsts.hasOwnProperty(rc) && !(rc in window.CSSRule)) try { window.CSSRule[rc] = ruleConsts[rc]; } catch (e2) {}
        }
        if (!window.CSSKeyframesRule && window.WebKitCSSKeyframesRule) window.CSSKeyframesRule = window.WebKitCSSKeyframesRule;
        if (!window.CSSKeyframeRule && window.WebKitCSSKeyframeRule) window.CSSKeyframeRule = window.WebKitCSSKeyframeRule;
        if (window.CSSKeyframesRule && window.CSSKeyframesRule.prototype && !window.CSSKeyframesRule.prototype.appendRule) {
            window.CSSKeyframesRule.prototype.appendRule = function (rule) { return this.insertRule(rule); };
        }
        var ruleStubs = ['CSSGroupingRule', 'CSSConditionRule', 'CSSSupportsRule', 'CSSLayerBlockRule', 'CSSLayerStatementRule', 'CSSContainerRule', 'CSSCounterStyleRule',
                         'CSSFontFeatureValuesRule', 'CSSFontPaletteValuesRule', 'CSSPropertyRule', 'CSSScopeRule', 'CSSNestedDeclarations', 'CSSStartingStyleRule', 'CSSPositionTryRule', 'CSSViewTransitionRule'];
        for (var rs = 0; rs < ruleStubs.length; rs++) if (!window[ruleStubs[rs]]) window[ruleStubs[rs]] = (function (n) { var F = function () {}; try { F.prototype = Object.create(window.CSSRule ? window.CSSRule.prototype : Object.prototype); } catch (e3) {} F.prototype.constructor = F; return F; })(ruleStubs[rs]);
        if (window.CSSStyleRule && window.CSSStyleRule.prototype && !('cssRules' in window.CSSStyleRule.prototype)) {
            try { Object.defineProperty(window.CSSStyleRule.prototype, 'cssRules', { get: function () { return []; }, configurable: true }); } catch (e4) {}
            window.CSSStyleRule.prototype.insertRule = function () { return 0; };
            window.CSSStyleRule.prototype.deleteRule = noop;
        }
        // Web Animations: a fuller Animation object for element.animate()
        if (!window.Animation || !window.Animation.prototype.play) {
            var Animation = function Animation(effect, timeline) {
                this.effect = effect || null; this.timeline = timeline || (document.timeline || null); this.id = ''; this.startTime = null; this.currentTime = 0;
                this.playbackRate = 1; this.playState = 'finished'; this.replaceState = 'active'; this.pending = false;
                this.onfinish = null; this.oncancel = null; this.onremove = null;
                var self = this;
                this.ready = P ? P.resolve(self) : null; this.finished = this.ready;
            };
            Animation.prototype.cancel = function () { this.playState = 'idle'; if (typeof this.oncancel === 'function') this.oncancel({ target: this }); };
            Animation.prototype.finish = function () { this.playState = 'finished'; if (typeof this.onfinish === 'function') this.onfinish({ target: this }); };
            Animation.prototype.play = function () { this.playState = 'finished'; var s = this; setTimeout(function () { if (typeof s.onfinish === 'function') s.onfinish({ target: s }); }, 0); };
            Animation.prototype.pause = function () { this.playState = 'paused'; };
            Animation.prototype.reverse = noop; Animation.prototype.updatePlaybackRate = function (r) { this.playbackRate = r; }; Animation.prototype.persist = noop; Animation.prototype.commitStyles = noop;
            Animation.prototype.addEventListener = noop; Animation.prototype.removeEventListener = noop; Animation.prototype.dispatchEvent = function () { return true; };
            window.Animation = Animation;
            if (Ep) { Ep.animate = function () { var a = new Animation(); a.play(); return a; }; Ep.getAnimations = function () { return []; }; }
            window.CSSAnimation = function CSSAnimation() { Animation.call(this); this.animationName = ''; };
            window.CSSAnimation.prototype = Object.create(Animation.prototype);
            window.CSSTransition = function CSSTransition() { Animation.call(this); this.transitionProperty = ''; };
            window.CSSTransition.prototype = Object.create(Animation.prototype);
            if (!window.KeyframeEffect) window.KeyframeEffect = function KeyframeEffect(target, keyframes, options) { this.target = target || null; this.composite = 'replace'; this.pseudoElement = null; this.__k = keyframes; this.__o = options; };
            window.KeyframeEffect.prototype.getKeyframes = function () { return this.__k || []; };
            window.KeyframeEffect.prototype.setKeyframes = function (k) { this.__k = k; };
            window.KeyframeEffect.prototype.getTiming = function () { return typeof this.__o === 'object' && this.__o ? this.__o : { duration: this.__o || 0 }; };
            window.KeyframeEffect.prototype.getComputedTiming = window.KeyframeEffect.prototype.getTiming;
            window.KeyframeEffect.prototype.updateTiming = noop;
            window.AnimationEffect = window.AnimationEffect || window.KeyframeEffect;
            if (!window.AnimationTimeline) window.AnimationTimeline = function AnimationTimeline() { this.currentTime = 0; };
            if (!window.DocumentTimeline) { window.DocumentTimeline = function DocumentTimeline() { this.currentTime = 0; }; }
            if (!document.timeline) document.timeline = new window.DocumentTimeline();
            if (!document.getAnimations) document.getAnimations = function () { return []; };
        }
        // Font loading: FontFace members and a FontFaceSet class behind document.fonts
        if (window.FontFace && !('weight' in window.FontFace.prototype)) {
            var ffDefaults = { style: 'normal', weight: 'normal', stretch: 'normal', unicodeRange: 'U+0-10FFFF', variant: 'normal', featureSettings: 'normal', variationSettings: 'normal', display: 'auto', ascentOverride: 'normal', descentOverride: 'normal', lineGapOverride: 'normal' };
            for (var ffk in ffDefaults) if (ffDefaults.hasOwnProperty(ffk) && !(ffk in window.FontFace.prototype)) window.FontFace.prototype[ffk] = ffDefaults[ffk];
            if (!('features' in window.FontFace.prototype)) { window.FontFace.prototype.features = {}; window.FontFace.prototype.variations = {}; window.FontFace.prototype.palettes = {}; }
        }
        if (document.fonts && !window.FontFaceSet) {
            var FontFaceSet = function FontFaceSet() {};
            var fsProto = FontFaceSet.prototype;
            fsProto.add = function () { return this; }; fsProto['delete'] = function () { return false; }; fsProto.clear = noop; fsProto.has = function () { return false; };
            fsProto.load = function () { return resolved([]); }; fsProto.check = function () { return true; }; fsProto.forEach = noop; fsProto.entries = function () { return [].entries ? [].entries() : []; };
            fsProto.keys = fsProto.entries; fsProto.values = fsProto.entries; fsProto.addEventListener = noop; fsProto.removeEventListener = noop; fsProto.dispatchEvent = function () { return true; };
            fsProto.status = 'loaded'; fsProto.size = 0; fsProto.onloading = null; fsProto.onloadingdone = null; fsProto.onloadingerror = null;
            fsProto.ready = resolved({ status: 'loaded' });
            window.FontFaceSet = FontFaceSet;
            try { document.fonts.__proto__ = fsProto; } catch (e5) {}
            window.FontFaceSetLoadEvent = window.FontFaceSetLoadEvent || function FontFaceSetLoadEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, false); e.fontfaces = init && init.fontfaces || []; return e; };
        }
        if (window.Highlight && !window.Highlight.prototype.has) {
            var hp = window.Highlight.prototype;
            hp.has = function () { return false; }; hp.add = function () { return this; }; hp['delete'] = function () { return false; }; hp.clear = noop; hp.forEach = noop;
            hp.values = function () { return []; }; hp.keys = hp.values; hp.entries = hp.values; hp.size = 0; hp.priority = 0; hp.type = 'highlight';
        }
        if (!window.CaretPosition) { window.CaretPosition = function CaretPosition() { this.offsetNode = null; this.offset = 0; }; window.CaretPosition.prototype.getClientRect = function () { return null; }; }
        if (!document.caretPositionFromPoint) document.caretPositionFromPoint = function (x, y) { var r = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null; var c = new window.CaretPosition(); if (r) { c.offsetNode = r.startContainer; c.offset = r.startOffset; } return c; };
        if (!document.elementsFromPoint) document.elementsFromPoint = function (x, y) { var el = document.elementFromPoint(x, y), list = []; while (el) { list.push(el); el = el.parentElement; } return list; };
    } catch (eCSSOM) {}

    // ---- Language runtime extras
    if (!window.globalThis) try { window.globalThis = window; } catch (e) {}
    if (!window.queueMicrotask) window.queueMicrotask = function (cb) { if (P) P.resolve().then(cb); else setTimeout(cb, 0); };
    if (!window.WeakRef) { window.WeakRef = function WeakRef(target) { this.__t = target; }; window.WeakRef.prototype.deref = function () { return this.__t; }; }
    if (!window.FinalizationRegistry) { window.FinalizationRegistry = function FinalizationRegistry() {}; window.FinalizationRegistry.prototype.register = noop; window.FinalizationRegistry.prototype.unregister = noop; }
    if (!window.Atomics) window.Atomics = { add: function (a, i, v) { var o = a[i]; a[i] = o + v; return o; }, load: function (a, i) { return a[i]; }, store: function (a, i, v) { a[i] = v; return v; }, wait: function () { return 'not-equal'; }, notify: function () { return 0; }, isLockFree: function () { return true; } };
    if (!window.SharedArrayBuffer) window.SharedArrayBuffer = window.ArrayBuffer;
    if (!window.DOMMatrix) {
        window.DOMMatrix = window.WebKitCSSMatrix || function DOMMatrix() { this.a = 1; this.b = 0; this.c = 0; this.d = 1; this.e = 0; this.f = 0; this.is2D = true; this.isIdentity = true; };
        window.DOMMatrixReadOnly = window.DOMMatrix;
    }
    if (!window.DOMPoint) { window.DOMPoint = function DOMPoint(x, y, z, w) { this.x = x || 0; this.y = y || 0; this.z = z || 0; this.w = w === undefined ? 1 : w; }; window.DOMPointReadOnly = window.DOMPoint; }
    if (!window.DOMRect) { window.DOMRect = function DOMRect(x, y, w, h) { this.x = x || 0; this.y = y || 0; this.width = w || 0; this.height = h || 0; this.top = this.y; this.left = this.x; this.right = this.x + this.width; this.bottom = this.y + this.height; }; window.DOMRectReadOnly = window.DOMRect; }
    if (!window.DOMQuad) window.DOMQuad = function DOMQuad() {};
    if (window.Notification && !window.Notification.prototype.close) { window.Notification.prototype.close = noop; window.Notification.prototype.addEventListener = noop; window.Notification.prototype.removeEventListener = noop; window.Notification.maxActions = 0; }
    if (!window.ErrorEvent) window.ErrorEvent = function ErrorEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, true); init = init || {}; e.message = init.message || ''; e.filename = init.filename || ''; e.lineno = init.lineno || 0; e.colno = init.colno || 0; e.error = init.error; return e; };
    if (!window.PromiseRejectionEvent) window.PromiseRejectionEvent = function PromiseRejectionEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, true); e.promise = init && init.promise; e.reason = init && init.reason; return e; };
    if (!window.PageTransitionEvent) window.PageTransitionEvent = function PageTransitionEvent() {};
    if (!window.BeforeUnloadEvent) window.BeforeUnloadEvent = function BeforeUnloadEvent() {};
    if (!window.PopStateEvent) window.PopStateEvent = function PopStateEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, false); e.state = init && init.state; return e; };
    if (!window.HashChangeEvent) window.HashChangeEvent = function HashChangeEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, false); e.oldURL = init && init.oldURL; e.newURL = init && init.newURL; return e; };
    if (!window.TransitionEvent && window.WebKitTransitionEvent) window.TransitionEvent = window.WebKitTransitionEvent;
    if (!window.AnimationEvent && window.WebKitAnimationEvent) window.AnimationEvent = window.WebKitAnimationEvent;
    if (!window.Animation) { window.Animation = function Animation() {}; window.KeyframeEffect = function KeyframeEffect() {}; window.DocumentTimeline = function DocumentTimeline() { this.currentTime = 0; }; document.timeline = document.timeline || new window.DocumentTimeline(); document.getAnimations = document.getAnimations || function () { return []; }; }
    if (!window.Worklet) { window.Worklet = function Worklet() {}; window.Worklet.prototype.addModule = function () { return resolved(); }; }
    var makeWorklet = function () { try { return new window.Worklet(); } catch (e) { return { addModule: function () { return resolved(); } }; } };   // a native Worklet cannot be constructed
    try { if (!window.CSS.paintWorklet) window.CSS.paintWorklet = makeWorklet(); } catch (e0) {}
    try { if (!window.CSS.animationWorklet) window.CSS.animationWorklet = makeWorklet(); } catch (e1) {}
    try { if (!window.CSS.layoutWorklet) window.CSS.layoutWorklet = makeWorklet(); } catch (e2) {}
    if (!window.CSS.highlights) { window.CSS.highlights = { set: noop, get: function () { return undefined; }, has: function () { return false; }, 'delete': function () { return false; }, clear: noop, size: 0 }; window.Highlight = function Highlight() {}; }
    if (!window.CSS.elementSources) window.CSS.elementSources = {};
    if (window.CSSStyleSheet && window.CSSStyleSheet.prototype.insertRule && !window.CSSStyleSheet.prototype.__brWrapped) {
        // the old engine requires the index argument; modern code omits it (append)
        window.CSSStyleSheet.prototype.__brWrapped = true;
        var origInsert = window.CSSStyleSheet.prototype.insertRule;
        window.CSSStyleSheet.prototype.insertRule = function (rule, index) { return origInsert.call(this, rule, index === undefined ? (this.cssRules ? this.cssRules.length : 0) : index); };
        if (!window.CSSStyleSheet.prototype.deleteRule && window.CSSStyleSheet.prototype.removeRule) window.CSSStyleSheet.prototype.deleteRule = window.CSSStyleSheet.prototype.removeRule;
    }
    if (!window.CSSLayerBlockRule) { window.CSSLayerBlockRule = function CSSLayerBlockRule() {}; window.CSSContainerRule = function CSSContainerRule() {}; window.CSSSupportsRule = window.CSSSupportsRule || function CSSSupportsRule() {}; }
    if (!document.fonts) {
        document.fonts = { ready: resolved({ status: 'loaded' }), status: 'loaded', check: function () { return true; }, load: function () { return resolved([]); }, add: noop, 'delete': noop, clear: noop, has: function () { return false; }, forEach: noop, addEventListener: noop, removeEventListener: noop, onloadingdone: null, size: 0 };
        window.FontFace = function FontFace(family, source, descriptors) {
            this.family = family; this.status = 'unloaded'; this.__source = source; this.__desc = descriptors || {};
            var self = this;
            this.loaded = new P(function (res) { self.__resolve = res; });
        };
        window.FontFace.prototype.load = function () {
            // register through @font-face so the engine can actually use the font
            var self = this, src = typeof self.__source === 'string' ? self.__source : '';
            if (src) {
                var css = '@font-face{font-family:"' + self.family + '";src:' + src;
                if (self.__desc.weight) css += ';font-weight:' + self.__desc.weight;
                if (self.__desc.style) css += ';font-style:' + self.__desc.style;
                addStyle(css + '}');
            }
            self.status = 'loaded';
            if (self.__resolve) self.__resolve(self);
            return resolved(self);
        };
        window.FontFaceSet = function FontFaceSet() {};
    }
    if (!window.ScreenOrientation) window.ScreenOrientation = function ScreenOrientation() {};
    if (window.screen && window.screen.orientation && !window.screen.orientation.lock) { window.screen.orientation.lock = rejectWith('NotSupportedError', 'Orientation lock is not available'); window.screen.orientation.unlock = noop; }
    if (!window.CloseEvent) window.CloseEvent = function CloseEvent(type, init) { var e = document.createEvent('Event'); e.initEvent(type, false, false); init = init || {}; e.wasClean = !!init.wasClean; e.code = init.code || 0; e.reason = init.reason || ''; return e; };
    if (!window.MessageChannel) {
        window.MessagePort = function MessagePort() { this.onmessage = null; this.__peer = null; this.__l = []; };
        window.MessagePort.prototype = {
            postMessage: function (data) { var peer = this.__peer; if (!peer) return; setTimeout(function () { var ev = { type: 'message', data: data, ports: [], target: peer }; if (peer.onmessage) peer.onmessage(ev); for (var i = 0; i < peer.__l.length; i++) peer.__l[i](ev); }, 0); },
            start: noop, close: noop, addEventListener: function (t, f) { if (t === 'message') this.__l.push(f); }, removeEventListener: function (t, f) { var i = this.__l.indexOf(f); if (i >= 0) this.__l.splice(i, 1); }
        };
        window.MessageChannel = function MessageChannel() { this.port1 = new window.MessagePort(); this.port2 = new window.MessagePort(); this.port1.__peer = this.port2; this.port2.__peer = this.port1; };
    }

    // ---- CSS Typed OM (css-typed-om-1): a working subset. Values parse into CSSUnitValue / CSSKeywordValue /
    // CSSMathSum ... / CSSTransformValue / CSSRGB / CSSImageValue / CSSUnparsedValue, computedStyleMap() and
    // attributeStyleMap wrap the style declarations, and CSS.px() & co. make unit values.
    if (!window.CSSStyleValue || !window.CSSStyleValue.parse) try { (function () {
        var extend = function (Child, Parent) { Child.prototype = Object.create(Parent.prototype); Child.prototype.constructor = Child; return Child; };
        var UNIT_SUFFIX = { number: '', percent: '%' };
        var unitText = function (unit) { return UNIT_SUFFIX.hasOwnProperty(unit) ? UNIT_SUFFIX[unit] : unit; };
        var CSSStyleValue = function CSSStyleValue() {};
        CSSStyleValue.prototype.toString = function () { return this.__css || ''; };
        var CSSKeywordValue = extend(function CSSKeywordValue(value) { this.value = String(value); }, CSSStyleValue);
        CSSKeywordValue.prototype.value = '';
        CSSKeywordValue.prototype.toString = function () { return this.value; };
        var CSSVariableReferenceValue = extend(function CSSVariableReferenceValue(variable, fallback) { this.variable = String(variable); this.fallback = fallback || null; }, CSSStyleValue);
        CSSVariableReferenceValue.prototype.variable = ''; CSSVariableReferenceValue.prototype.fallback = null;
        CSSVariableReferenceValue.prototype.toString = function () { return 'var(' + this.variable + (this.fallback ? ',' + this.fallback : '') + ')'; };
        var listMethods = function (proto) {
            proto.length = 0;
            proto.forEach = function (fn, thisArg) { for (var i = 0; i < this.length; i++) fn.call(thisArg, this[i], i, this); };
            proto.entries = function () { var a = []; for (var i = 0; i < this.length; i++) a.push([i, this[i]]); return a; };
            proto.keys = function () { var a = []; for (var i = 0; i < this.length; i++) a.push(i); return a; };
            proto.values = function () { var a = []; for (var i = 0; i < this.length; i++) a.push(this[i]); return a; };
        };
        var fillList = function (self, items) { for (var i = 0; i < items.length; i++) self[i] = items[i]; self.length = items.length; };
        var CSSUnparsedValue = extend(function CSSUnparsedValue(members) { fillList(this, members || []); }, CSSStyleValue);
        listMethods(CSSUnparsedValue.prototype);
        CSSUnparsedValue.prototype.toString = function () { return this.values().join(''); };
        var CSSNumericArray = function CSSNumericArray(items) { fillList(this, items || []); };
        listMethods(CSSNumericArray.prototype);
        // numeric values
        var CSSNumericValue = extend(function CSSNumericValue() {}, CSSStyleValue);
        var toNumeric = function (v) { return typeof v === 'number' ? new CSSUnitValue(v, 'number') : v; };
        var numericArgs = function (args) { var out = []; for (var i = 0; i < args.length; i++) out.push(toNumeric(args[i])); return out; };
        CSSNumericValue.prototype.add = function () { var a = numericArgs(arguments); if (this instanceof CSSUnitValue && a.length === 1 && a[0] instanceof CSSUnitValue && a[0].unit === this.unit) return new CSSUnitValue(this.value + a[0].value, this.unit); return new CSSMathSum([this].concat(a)); };
        CSSNumericValue.prototype.sub = function () { var a = numericArgs(arguments); if (this instanceof CSSUnitValue && a.length === 1 && a[0] instanceof CSSUnitValue && a[0].unit === this.unit) return new CSSUnitValue(this.value - a[0].value, this.unit); var neg = []; for (var i = 0; i < a.length; i++) neg.push(new CSSMathNegate(a[i])); return new CSSMathSum([this].concat(neg)); };
        CSSNumericValue.prototype.mul = function () { var a = numericArgs(arguments); if (this instanceof CSSUnitValue && a.length === 1 && a[0] instanceof CSSUnitValue && (a[0].unit === 'number' || this.unit === 'number')) return new CSSUnitValue(this.value * a[0].value, this.unit === 'number' ? a[0].unit : this.unit); return new CSSMathProduct([this].concat(a)); };
        CSSNumericValue.prototype.div = function () { var a = numericArgs(arguments); if (this instanceof CSSUnitValue && a.length === 1 && a[0] instanceof CSSUnitValue && a[0].unit === 'number' && a[0].value !== 0) return new CSSUnitValue(this.value / a[0].value, this.unit); var inv = []; for (var i = 0; i < a.length; i++) inv.push(new CSSMathInvert(a[i])); return new CSSMathProduct([this].concat(inv)); };
        CSSNumericValue.prototype.min = function () { return new CSSMathMin([this].concat(numericArgs(arguments))); };
        CSSNumericValue.prototype.max = function () { return new CSSMathMax([this].concat(numericArgs(arguments))); };
        CSSNumericValue.prototype.equals = function () { for (var i = 0; i < arguments.length; i++) if (String(toNumeric(arguments[i])) !== String(this)) return false; return true; };
        var ABS = { px: 1, cm: 96 / 2.54, mm: 96 / 25.4, q: 96 / 101.6, 'in': 96, pt: 4 / 3, pc: 16, deg: 1, grad: 0.9, rad: 180 / Math.PI, turn: 360, s: 1000, ms: 1, hz: 1, khz: 1000, dpi: 1, dpcm: 2.54, dppx: 96 };
        var CANON = { px: 'px', cm: 'px', mm: 'px', q: 'px', 'in': 'px', pt: 'px', pc: 'px', deg: 'deg', grad: 'deg', rad: 'deg', turn: 'deg', s: 'ms', ms: 'ms', hz: 'hz', khz: 'hz', dpi: 'dpi', dpcm: 'dpi', dppx: 'dpi' };
        CSSNumericValue.prototype.to = function (unit) {
            if (!(this instanceof CSSUnitValue)) throw new TypeError('Cannot convert a math value');
            var from = this.unit.toLowerCase(), to = String(unit).toLowerCase();
            if (from === to) return new CSSUnitValue(this.value, unit);
            if (!ABS.hasOwnProperty(from) || !ABS.hasOwnProperty(to) || CANON[from] !== CANON[to]) throw new TypeError('Incompatible units');
            return new CSSUnitValue(this.value * ABS[from] / ABS[to], unit);
        };
        CSSNumericValue.prototype.toSum = function () { var s = new CSSMathSum([this]); if (arguments.length) { var vals = []; for (var i = 0; i < arguments.length; i++) vals.push(this.to(arguments[i])); s = new CSSMathSum(vals); } return s; };
        var TYPE_OF = { px: 'length', em: 'length', rem: 'length', vw: 'length', vh: 'length', cm: 'length', mm: 'length', 'in': 'length', pt: 'length', pc: 'length', percent: 'percent', deg: 'angle', rad: 'angle', turn: 'angle', grad: 'angle', s: 'time', ms: 'time', hz: 'frequency', khz: 'frequency', dpi: 'resolution', dppx: 'resolution', fr: 'flex' };
        CSSNumericValue.prototype.type = function () { var t = {}; if (this instanceof CSSUnitValue && TYPE_OF[this.unit.toLowerCase()]) t[TYPE_OF[this.unit.toLowerCase()]] = 1; return t; };
        CSSNumericValue.parse = function (text) { var v = parseValue(String(text)); if (!(v instanceof CSSNumericValue)) throw new SyntaxError('Not a numeric value'); return v; };
        var CSSUnitValue = extend(function CSSUnitValue(value, unit) { this.value = Number(value); this.unit = String(unit); }, CSSNumericValue);
        CSSUnitValue.prototype.value = 0; CSSUnitValue.prototype.unit = '';
        CSSUnitValue.prototype.toString = function () { return this.value + unitText(this.unit); };
        var CSSMathValue = extend(function CSSMathValue() {}, CSSNumericValue);
        CSSMathValue.prototype.operator = '';
        // "calc(100% - 20px)": negated terms and inverted factors serialise with - and /, nested sums in parentheses
        var mathBody = function (m) {
            var parts = m.values.values(), s = '';
            for (var i = 0; i < parts.length; i++) {
                var v = parts[i];
                if (m.operator === 'sum') s += (v instanceof CSSMathNegate ? (i ? ' - ' : '-') + mathTerm(v.value) : (i ? ' + ' : '') + mathTerm(v));
                else s += (v instanceof CSSMathInvert ? (i ? ' / ' : '1 / ') + mathTerm(v.value) : (i ? ' * ' : '') + mathTerm(v));
            }
            return s;
        };
        var mathTerm = function (v) { return (v instanceof CSSMathSum || v instanceof CSSMathProduct) ? '(' + mathBody(v) + ')' : String(v); };
        var mathList = function (name, operator, joiner) {
            var C = extend(function (values) { this.values = new CSSNumericArray(numericArgs(values && values.length !== undefined && !(values instanceof CSSStyleValue) ? values : arguments)); }, CSSMathValue);
            C.prototype.operator = operator; C.prototype.values = null;
            C.prototype.toString = function () { return joiner ? 'calc(' + mathBody(this) + ')' : operator + '(' + this.values.values().join(', ') + ')'; };
            try { Object.defineProperty(C, 'name', { value: name }); } catch (e) {}
            return C;
        };
        var CSSMathSum = mathList('CSSMathSum', 'sum', ' + ');
        var CSSMathProduct = mathList('CSSMathProduct', 'product', ' * ');
        var CSSMathMin = mathList('CSSMathMin', 'min', null);
        var CSSMathMax = mathList('CSSMathMax', 'max', null);
        var CSSMathNegate = extend(function CSSMathNegate(value) { this.value = toNumeric(value); }, CSSMathValue);
        CSSMathNegate.prototype.operator = 'negate'; CSSMathNegate.prototype.value = null;
        CSSMathNegate.prototype.toString = function () { return '-' + this.value; };
        var CSSMathInvert = extend(function CSSMathInvert(value) { this.value = toNumeric(value); }, CSSMathValue);
        CSSMathInvert.prototype.operator = 'invert'; CSSMathInvert.prototype.value = null;
        CSSMathInvert.prototype.toString = function () { return '1 / ' + this.value; };
        var CSSMathClamp = extend(function CSSMathClamp(lower, value, upper) { this.lower = toNumeric(lower); this.value = toNumeric(value); this.upper = toNumeric(upper); }, CSSMathValue);
        CSSMathClamp.prototype.operator = 'clamp'; CSSMathClamp.prototype.lower = null; CSSMathClamp.prototype.value = null; CSSMathClamp.prototype.upper = null;
        CSSMathClamp.prototype.toString = function () { return 'clamp(' + this.lower + ', ' + this.value + ', ' + this.upper + ')'; };
        // transforms
        var CSSTransformComponent = function CSSTransformComponent() {};
        CSSTransformComponent.prototype.is2D = true;
        CSSTransformComponent.prototype.toMatrix = function () { var M = window.DOMMatrix; try { return new M(this.toString()); } catch (e) { return new M(); } };
        var component = function (name, fields, build) {
            var C = extend(function () { for (var i = 0; i < fields.length; i++) this[fields[i]] = arguments[i] === undefined ? null : arguments[i]; if (build.init) build.init.apply(this, arguments); }, CSSTransformComponent);
            for (var f = 0; f < fields.length; f++) C.prototype[fields[f]] = null;
            C.prototype.toString = build.text;
            try { Object.defineProperty(C, 'name', { value: name }); } catch (e) {}
            return C;
        };
        var num0 = function (v) { return v === null || v === undefined ? new CSSUnitValue(0, 'px') : toNumeric(v); };
        var CSSTranslate = component('CSSTranslate', ['x', 'y', 'z'], { init: function () { this.z = this.z === null ? new CSSUnitValue(0, 'px') : this.z; this.is2D = String(this.z) === '0px'; }, text: function () { return this.is2D ? 'translate(' + num0(this.x) + ', ' + num0(this.y) + ')' : 'translate3d(' + num0(this.x) + ', ' + num0(this.y) + ', ' + this.z + ')'; } });
        var CSSRotate = component('CSSRotate', ['x', 'y', 'z', 'angle'], { init: function () { if (arguments.length === 1) { this.angle = arguments[0]; this.x = 0; this.y = 0; this.z = 1; this.is2D = true; } else this.is2D = false; }, text: function () { return this.is2D ? 'rotate(' + this.angle + ')' : 'rotate3d(' + this.x + ', ' + this.y + ', ' + this.z + ', ' + this.angle + ')'; } });
        var CSSScale = component('CSSScale', ['x', 'y', 'z'], { init: function () { if (this.z === null) { this.z = 1; this.is2D = true; } else this.is2D = false; }, text: function () { return this.is2D ? 'scale(' + this.x + ', ' + this.y + ')' : 'scale3d(' + this.x + ', ' + this.y + ', ' + this.z + ')'; } });
        var CSSSkew = component('CSSSkew', ['ax', 'ay'], { text: function () { return 'skew(' + this.ax + ', ' + this.ay + ')'; } });
        var CSSSkewX = component('CSSSkewX', ['ax'], { text: function () { return 'skewX(' + this.ax + ')'; } });
        var CSSSkewY = component('CSSSkewY', ['ay'], { text: function () { return 'skewY(' + this.ay + ')'; } });
        var CSSPerspective = component('CSSPerspective', ['length'], { init: function () { this.is2D = false; }, text: function () { return 'perspective(' + this.length + ')'; } });
        var CSSMatrixComponent = component('CSSMatrixComponent', ['matrix'], { init: function (m, options) { this.is2D = options && options.is2D !== undefined ? !!options.is2D : !(m && m.is2D === false); }, text: function () { var m = this.matrix; if (!m) return 'matrix(1, 0, 0, 1, 0, 0)'; return this.is2D ? 'matrix(' + [m.a, m.b, m.c, m.d, m.e, m.f].join(', ') + ')' : 'matrix3d(' + [m.m11, m.m12, m.m13, m.m14, m.m21, m.m22, m.m23, m.m24, m.m31, m.m32, m.m33, m.m34, m.m41, m.m42, m.m43, m.m44].join(', ') + ')'; } });
        CSSMatrixComponent.prototype.toMatrix = function () { return this.matrix; };
        var CSSTransformValue = extend(function CSSTransformValue(components) { fillList(this, components || []); }, CSSStyleValue);
        listMethods(CSSTransformValue.prototype);
        CSSTransformValue.prototype.is2D = true;
        try { Object.defineProperty(CSSTransformValue.prototype, 'is2D', { get: function () { for (var i = 0; i < this.length; i++) if (!this[i].is2D) return false; return true; }, configurable: true }); } catch (e) {}
        CSSTransformValue.prototype.toMatrix = function () { var M = window.DOMMatrix; try { return new M(this.toString()); } catch (e) { return new M(); } };
        CSSTransformValue.prototype.toString = function () { return this.values().join(' '); };
        // colours and images
        var CSSColorValue = extend(function CSSColorValue() {}, CSSStyleValue);
        CSSColorValue.prototype.alpha = null;
        var colorClass = function (name, fields, fn) {
            var C = extend(function () { for (var i = 0; i < fields.length; i++) this[fields[i]] = arguments[i] === undefined ? (fields[i] === 'alpha' ? new CSSUnitValue(1, 'number') : null) : toNumeric(arguments[i]); }, CSSColorValue);
            for (var f = 0; f < fields.length; f++) C.prototype[fields[f]] = null;
            C.prototype.toString = function () { var parts = []; for (var i = 0; i < fields.length - 1; i++) parts.push(String(this[fields[i]])); return fn + '(' + parts.join(' ') + ' / ' + this.alpha + ')'; };
            try { Object.defineProperty(C, 'name', { value: name }); } catch (e) {}
            return C;
        };
        var CSSRGB = colorClass('CSSRGB', ['r', 'g', 'b', 'alpha'], 'rgb');
        var CSSHSL = colorClass('CSSHSL', ['h', 's', 'l', 'alpha'], 'hsl');
        var CSSHWB = colorClass('CSSHWB', ['h', 'w', 'b', 'alpha'], 'hwb');
        var CSSLab = colorClass('CSSLab', ['l', 'a', 'b', 'alpha'], 'lab');
        var CSSLCH = colorClass('CSSLCH', ['l', 'c', 'h', 'alpha'], 'lch');
        var CSSOKLab = colorClass('CSSOKLab', ['l', 'a', 'b', 'alpha'], 'oklab');
        var CSSOKLCH = colorClass('CSSOKLCH', ['l', 'c', 'h', 'alpha'], 'oklch');
        var CSSColor = extend(function CSSColor(colorSpace, channels, alpha) { this.colorSpace = colorSpace; this.channels = channels || []; this.alpha = alpha === undefined ? new CSSUnitValue(1, 'number') : toNumeric(alpha); }, CSSColorValue);
        CSSColor.prototype.colorSpace = ''; CSSColor.prototype.channels = null;
        CSSColor.prototype.toString = function () { return 'color(' + this.colorSpace + ' ' + this.channels.join(' ') + ' / ' + this.alpha + ')'; };
        CSSColorValue.parse = function (text) { var v = parseValue(String(text)); return v instanceof CSSColorValue ? v : new CSSKeywordValue(text); };
        var CSSImageValue = extend(function CSSImageValue(css) { this.__css = css; }, CSSStyleValue);
        // parsing
        var NUM_RE = /^([-+]?(?:\d*\.\d+|\d+)(?:e[-+]?\d+)?)([a-z%]*)$/i;
        var splitTop = function (s, sep) { var parts = [], depth = 0, start = 0, q = null; for (var i = 0; i < s.length; i++) { var c = s.charAt(i); if (q) { if (c === q) q = null; continue; } if (c === '"' || c === "'") q = c; else if (c === '(') depth++; else if (c === ')') depth--; else if (depth === 0 && c === sep) { parts.push(s.slice(start, i)); start = i + 1; } } parts.push(s.slice(start)); return parts; };
        var trim = function (s) { return s.replace(/^\s+|\s+$/g, ''); };
        var parseNumeric = function (s) {
            s = trim(s);
            var m = NUM_RE.exec(s);
            if (m) return new CSSUnitValue(parseFloat(m[1]), m[2] === '' ? 'number' : m[2] === '%' ? 'percent' : m[2].toLowerCase());
            var fm = /^(calc|min|max|clamp)\((.*)\)$/i.exec(s);
            if (!fm) return null;
            var name = fm[1].toLowerCase(), inner = fm[2];
            if (name === 'min' || name === 'max' || name === 'clamp') {
                var args = splitTop(inner, ','), vals = [];
                for (var i = 0; i < args.length; i++) { var pv = parseNumeric(args[i]); if (!pv) return null; vals.push(pv); }
                return name === 'min' ? new CSSMathMin(vals) : name === 'max' ? new CSSMathMax(vals) : new CSSMathClamp(vals[0], vals[1], vals[2]);
            }
            // calc: sums of products
            var terms = [], depth = 0, cur = '', sign = 1, i2;
            var flush = function () { var t = trim(cur); if (!t) return true; var pv = parseProduct(t); if (!pv) return false; terms.push(sign < 0 ? new CSSMathNegate(pv) : pv); cur = ''; return true; };
            for (i2 = 0; i2 < inner.length; i2++) {
                var ch = inner.charAt(i2);
                if (ch === '(') depth++; else if (ch === ')') depth--;
                if (depth === 0 && (ch === '+' || ch === '-') && /\s$/.test(cur) && cur.replace(/\s+$/, '')) { if (!flush()) return null; sign = ch === '-' ? -1 : 1; continue; }
                cur += ch;
            }
            if (!flush()) return null;
            return terms.length === 1 && !(terms[0] instanceof CSSMathNegate) ? terms[0] : new CSSMathSum(terms);
        };
        var parseProduct = function (t) {
            var parts = [], depth = 0, cur = '', op = '*';
            var ops = [];
            for (var i = 0; i < t.length; i++) {
                var ch = t.charAt(i);
                if (ch === '(') depth++; else if (ch === ')') depth--;
                if (depth === 0 && (ch === '*' || ch === '/')) { parts.push(cur); ops.push(ch); cur = ''; continue; }
                cur += ch;
            }
            parts.push(cur);
            var vals = [];
            for (var k = 0; k < parts.length; k++) {
                var p = trim(parts[k]);
                if (/^\(.*\)$/.test(p)) p = 'calc' + p;
                var pv = parseNumeric(p);
                if (!pv) return null;
                vals.push(k > 0 && ops[k - 1] === '/' ? new CSSMathInvert(pv) : pv);
            }
            return vals.length === 1 ? vals[0] : new CSSMathProduct(vals);
        };
        var TRANSFORM_FN = /^(translate|translate3d|translatex|translatey|translatez|rotate|rotate3d|rotatex|rotatey|rotatez|scale|scale3d|scalex|scaley|scalez|skew|skewx|skewy|perspective|matrix|matrix3d)\((.*)\)$/i;
        var parseTransform = function (s) {
            var fns = s.match(/[a-z0-9]+\([^)]*\)/gi);
            if (!fns) return null;
            var comps = [];
            for (var i = 0; i < fns.length; i++) {
                var m = TRANSFORM_FN.exec(trim(fns[i]));
                if (!m) return null;
                var name = m[1].toLowerCase(), args = splitTop(m[2], ','), a = [];
                for (var k = 0; k < args.length; k++) { var av = parseNumeric(args[k]); if (!av) return null; a.push(av); }
                var zero = new CSSUnitValue(0, 'px'), one = new CSSUnitValue(1, 'number');
                switch (name) {
                    case 'translate': comps.push(new CSSTranslate(a[0], a[1] || zero)); break;
                    case 'translatex': comps.push(new CSSTranslate(a[0], zero)); break;
                    case 'translatey': comps.push(new CSSTranslate(zero, a[0])); break;
                    case 'translatez': comps.push(new CSSTranslate(zero, zero, a[0])); break;
                    case 'translate3d': comps.push(new CSSTranslate(a[0], a[1], a[2])); break;
                    case 'rotate': case 'rotatez': comps.push(new CSSRotate(a[0])); break;
                    case 'rotatex': comps.push(new CSSRotate(1, 0, 0, a[0])); break;
                    case 'rotatey': comps.push(new CSSRotate(0, 1, 0, a[0])); break;
                    case 'rotate3d': comps.push(new CSSRotate(a[0], a[1], a[2], a[3])); break;
                    case 'scale': comps.push(new CSSScale(a[0], a.length > 1 ? a[1] : a[0])); break;
                    case 'scalex': comps.push(new CSSScale(a[0], one)); break;
                    case 'scaley': comps.push(new CSSScale(one, a[0])); break;
                    case 'scalez': comps.push(new CSSScale(one, one, a[0])); break;
                    case 'scale3d': comps.push(new CSSScale(a[0], a[1], a[2])); break;
                    case 'skew': comps.push(new CSSSkew(a[0], a[1] || new CSSUnitValue(0, 'deg'))); break;
                    case 'skewx': comps.push(new CSSSkewX(a[0])); break;
                    case 'skewy': comps.push(new CSSSkewY(a[0])); break;
                    case 'perspective': comps.push(new CSSPerspective(a[0])); break;
                    default: { var M = window.DOMMatrix, mx; try { mx = new M(trim(fns[i])); } catch (e) { mx = null; } comps.push(new CSSMatrixComponent(mx, { is2D: name === 'matrix' })); }
                }
            }
            return new CSSTransformValue(comps);
        };
        var parseColor = function (s) {
            var m = /^(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\((.*)\)$/i.exec(s);
            if (m) {
                var inner = m[2].replace('/', ' ').replace(/,/g, ' '), toks = inner.split(/\s+/).filter(function (x) { return x; }), vals = [];
                for (var i = 0; i < toks.length; i++) { var pv = parseNumeric(toks[i]); vals.push(pv || new CSSKeywordValue(toks[i])); }
                var fn = m[1].toLowerCase();
                var C = fn === 'rgb' || fn === 'rgba' ? CSSRGB : fn === 'hsl' || fn === 'hsla' ? CSSHSL : fn === 'hwb' ? CSSHWB : fn === 'lab' ? CSSLab : fn === 'lch' ? CSSLCH : fn === 'oklab' ? CSSOKLab : CSSOKLCH;
                return new C(vals[0], vals[1], vals[2], vals.length > 3 ? vals[3] : undefined);
            }
            var hex = /^#([0-9a-f]{3,8})$/i.exec(s);
            if (hex) {
                var h = hex[1];
                if (h.length === 3 || h.length === 4) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2) + (h.length === 4 ? h.charAt(3) + h.charAt(3) : '');
                var n = function (i) { return parseInt(h.substr(i, 2), 16); };
                return new CSSRGB(n(0), n(2), n(4), h.length === 8 ? n(6) / 255 : undefined);
            }
            var cm = /^color\(\s*([a-z0-9-]+)\s+(.*)\)$/i.exec(s);
            if (cm) { var ct = cm[2].replace('/', ' ').split(/\s+/).filter(function (x) { return x; }), cv = []; for (var ci = 0; ci < ct.length; ci++) cv.push(parseNumeric(ct[ci]) || new CSSKeywordValue(ct[ci])); return new CSSColor(cm[1], cv.slice(0, 3), cv.length > 3 ? cv[3] : undefined); }
            return null;
        };
        var parseValue = function (text) {
            var s = trim(text);
            if (!s) return undefined;
            if (/var\(/i.test(s)) {
                var members = [], re = /var\(\s*(--[^,)]+)\s*(?:,\s*([^)]*))?\)/gi, last = 0, mm;
                while ((mm = re.exec(s)) !== null) { if (mm.index > last) members.push(s.slice(last, mm.index)); members.push(new CSSVariableReferenceValue(trim(mm[1]), mm[2] !== undefined ? new CSSUnparsedValue([trim(mm[2])]) : null)); last = mm.index + mm[0].length; }
                if (last < s.length) members.push(s.slice(last));
                return new CSSUnparsedValue(members);
            }
            var num = parseNumeric(s);
            if (num) return num;
            if (/^[a-z-]+$/i.test(s)) return new CSSKeywordValue(s);
            var col = parseColor(s);
            if (col) return col;
            if (/^url\(/i.test(s) || /^(-webkit-)?(linear|radial|conic|repeating-linear|repeating-radial|repeating-conic)-gradient\(/i.test(s) || /^image(-set)?\(/i.test(s)) return new CSSImageValue(s);
            if (TRANSFORM_FN.test(trim(s.split(/\)\s+/)[0] + (s.indexOf(') ') > 0 ? ')' : '')))) { var tv = parseTransform(s); if (tv) return tv; }
            return new CSSUnparsedValue([s]);
        };
        CSSStyleValue.parse = function (property, text) { var v = parseValue(String(text)); if (v === undefined) throw new TypeError('Empty value'); return v; };
        CSSStyleValue.parseAll = function (property, text) { var parts = splitTop(String(text), ','), out = []; for (var i = 0; i < parts.length; i++) { var v = parseValue(parts[i]); if (v !== undefined) out.push(v); } return out; };
        // property maps
        var StylePropertyMapReadOnly = function StylePropertyMapReadOnly(decl) { this.__d = decl; };
        StylePropertyMapReadOnly.prototype.get = function (p) { var v = this.__d.getPropertyValue(String(p)); return v ? parseValue(v) : undefined; };
        StylePropertyMapReadOnly.prototype.getAll = function (p) { var v = this.__d.getPropertyValue(String(p)); if (!v) return []; return /^(transition|animation|background|font-family|will-change|mask|box-shadow|text-shadow)/.test(p) ? CSSStyleValue.parseAll(p, v) : [parseValue(v)]; };
        StylePropertyMapReadOnly.prototype.has = function (p) { return !!this.__d.getPropertyValue(String(p)); };
        StylePropertyMapReadOnly.prototype.size = 0;
        try { Object.defineProperty(StylePropertyMapReadOnly.prototype, 'size', { get: function () { return this.__d.length; }, configurable: true }); } catch (e) {}
        StylePropertyMapReadOnly.prototype.entries = function () { var a = []; for (var i = 0; i < this.__d.length; i++) { var p = this.__d[i] || this.__d.item(i); a.push([p, this.getAll(p)]); } return a; };
        StylePropertyMapReadOnly.prototype.keys = function () { var a = []; for (var i = 0; i < this.__d.length; i++) a.push(this.__d[i] || this.__d.item(i)); return a; };
        StylePropertyMapReadOnly.prototype.values = function () { var e = this.entries(), a = []; for (var i = 0; i < e.length; i++) a.push(e[i][1]); return a; };
        StylePropertyMapReadOnly.prototype.forEach = function (fn, thisArg) { var e = this.entries(); for (var i = 0; i < e.length; i++) fn.call(thisArg, e[i][1], e[i][0], this); };
        var StylePropertyMap = extend(function StylePropertyMap(decl) { this.__d = decl; }, StylePropertyMapReadOnly);
        StylePropertyMap.prototype.set = function (p) { var vals = []; for (var i = 1; i < arguments.length; i++) vals.push(String(arguments[i])); this.__d.setProperty(String(p), vals.join(', ')); };
        StylePropertyMap.prototype.append = function (p) { var cur = this.__d.getPropertyValue(String(p)), vals = cur ? [cur] : []; for (var i = 1; i < arguments.length; i++) vals.push(String(arguments[i])); this.__d.setProperty(String(p), vals.join(', ')); };
        StylePropertyMap.prototype['delete'] = function (p) { this.__d.removeProperty(String(p)); };
        StylePropertyMap.prototype.clear = function () { var names = this.keys(); for (var i = 0; i < names.length; i++) this.__d.removeProperty(names[i]); };
        if (Ep) {
            Ep.computedStyleMap = function () { return new StylePropertyMapReadOnly(window.getComputedStyle(this)); };
            try { Object.defineProperty(Ep, 'attributeStyleMap', { get: function () { if (!this.__brStyleMap) this.__brStyleMap = new StylePropertyMap(this.style); return this.__brStyleMap; }, configurable: true }); } catch (e) {}
        }
        var units = ['number', 'percent', 'em', 'ex', 'ch', 'ic', 'rem', 'lh', 'rlh', 'vw', 'vh', 'vi', 'vb', 'vmin', 'vmax', 'svw', 'svh', 'svi', 'svb', 'svmin', 'svmax', 'lvw', 'lvh', 'lvi', 'lvb', 'lvmin', 'lvmax', 'dvw', 'dvh', 'dvi', 'dvb', 'dvmin', 'dvmax', 'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax', 'cm', 'mm', 'Q', 'in', 'pt', 'pc', 'px', 'deg', 'grad', 'rad', 'turn', 's', 'ms', 'Hz', 'kHz', 'dpi', 'dpcm', 'dppx', 'fr', 'cap', 'rcap', 'rex', 'rch', 'ric'];
        for (var ui = 0; ui < units.length; ui++) (function (u) { window.CSS[u] = function (v) { return new CSSUnitValue(v, u); }; })(units[ui]);
        var expose = { CSSStyleValue: CSSStyleValue, CSSKeywordValue: CSSKeywordValue, CSSUnparsedValue: CSSUnparsedValue, CSSVariableReferenceValue: CSSVariableReferenceValue, CSSNumericValue: CSSNumericValue, CSSUnitValue: CSSUnitValue,
            CSSMathValue: CSSMathValue, CSSMathSum: CSSMathSum, CSSMathProduct: CSSMathProduct, CSSMathNegate: CSSMathNegate, CSSMathInvert: CSSMathInvert, CSSMathMin: CSSMathMin, CSSMathMax: CSSMathMax, CSSMathClamp: CSSMathClamp,
            CSSNumericArray: CSSNumericArray, CSSTransformValue: CSSTransformValue, CSSTransformComponent: CSSTransformComponent, CSSTranslate: CSSTranslate, CSSRotate: CSSRotate, CSSScale: CSSScale, CSSSkew: CSSSkew, CSSSkewX: CSSSkewX,
            CSSSkewY: CSSSkewY, CSSPerspective: CSSPerspective, CSSMatrixComponent: CSSMatrixComponent, CSSImageValue: CSSImageValue, CSSColorValue: CSSColorValue, CSSRGB: CSSRGB, CSSHSL: CSSHSL, CSSHWB: CSSHWB, CSSLab: CSSLab, CSSLCH: CSSLCH,
            CSSOKLab: CSSOKLab, CSSOKLCH: CSSOKLCH, CSSColor: CSSColor, StylePropertyMapReadOnly: StylePropertyMapReadOnly, StylePropertyMap: StylePropertyMap };
        for (var ek in expose) if (expose.hasOwnProperty(ek)) window[ek] = expose[ek];
    })(); } catch (eTypedOM) {}

    // ---- CSSOM rule classes with their members, view extras, event handler attributes, view transitions
    try {
        var proto = function (name) { return window[name] && window[name].prototype; };
        var defaults = function (name, members) { var p = proto(name); if (!p) return; for (var k in members) if (members.hasOwnProperty(k) && !(k in p)) p[k] = members[k]; };
        var emptyRules = function () { return []; };
        defaults('CSSGroupingRule', { cssRules: emptyRules(), insertRule: function () { return 0; }, deleteRule: noop });
        defaults('CSSConditionRule', { conditionText: '' });
        defaults('CSSSupportsRule', { conditionText: '', matches: false });
        if (proto('CSSMediaRule') && !('matches' in proto('CSSMediaRule'))) try { Object.defineProperty(proto('CSSMediaRule'), 'matches', { get: function () { try { return window.matchMedia(this.media.mediaText).matches; } catch (e) { return false; } }, configurable: true }); } catch (e0) {}
        defaults('CSSMediaRule', { conditionText: '' });
        defaults('CSSImportRule', { layerName: null, supportsText: null });
        defaults('CSSLayerBlockRule', { name: '' });
        defaults('CSSLayerStatementRule', { nameList: [] });
        defaults('CSSScopeRule', { start: null, end: null });
        defaults('CSSContainerRule', { containerName: '', containerQuery: '' });
        defaults('CSSPropertyRule', { name: '', syntax: '*', inherits: false, initialValue: null });
        defaults('CSSCounterStyleRule', { name: '', system: '', symbols: '', additiveSymbols: '', negative: '', prefix: '', suffix: '', range: '', pad: '', speakAs: '', fallback: '' });
        defaults('CSSFontFeatureValuesRule', { fontFamily: '', annotation: {}, ornaments: {}, stylistic: {}, swash: {}, characterVariant: {}, styleset: {} });
        defaults('CSSFontPaletteValuesRule', { name: '', fontFamily: '', basePalette: '', overrideColors: '' });
        defaults('CSSPositionTryRule', { name: '', style: null });
        defaults('CSSNestedDeclarations', { style: null });
        var moreStubs = { CSSMarginRule: { name: '', style: null }, CSSNamespaceRule: { namespaceURI: '', prefix: '' }, CSSFunctionRule: { name: '', returnType: '', getParameters: emptyRules, cssRules: [] }, CSSFunctionDeclarations: { style: null },
            CSSColorProfileRule: { name: '', src: '', renderingIntent: '', components: [] }, CSSFontFeatureValuesMap: { set: noop, get: function () { return undefined; }, has: function () { return false; }, 'delete': function () { return false; }, clear: noop, size: 0 } };
        for (var ms in moreStubs) if (moreStubs.hasOwnProperty(ms) && !window[ms]) { window[ms] = (function () { var F = function () {}; try { F.prototype = Object.create(window.CSSRule ? window.CSSRule.prototype : Object.prototype); } catch (e) {} F.prototype.constructor = F; return F; })(); defaults(ms, moreStubs[ms]); }
        if (window.CSSStyleDeclaration) {
            if (!window.CSSStyleProperties) { window.CSSStyleProperties = function CSSStyleProperties() {}; window.CSSStyleProperties.prototype = Object.create(window.CSSStyleDeclaration.prototype); defaults('CSSStyleProperties', { cssFloat: '' }); }
            if (!window.CSSPageDescriptors) { window.CSSPageDescriptors = function CSSPageDescriptors() {}; window.CSSPageDescriptors.prototype = Object.create(window.CSSStyleDeclaration.prototype); defaults('CSSPageDescriptors', { margin: '', marginTop: '', marginRight: '', marginBottom: '', marginLeft: '', 'margin-top': '', 'margin-right': '', 'margin-bottom': '', 'margin-left': '', size: '', pageOrientation: '', 'page-orientation': '', marks: '', bleed: '' }); }
        }
        if (!window.CSSPseudoElement) {
            window.CSSPseudoElement = function CSSPseudoElement() {};
            defaults('CSSPseudoElement', { type: '', element: null, parent: null, pseudo: function () { return null; }, getBoxQuads: emptyRules, convertQuadFromNode: function (q) { return q; }, convertRectFromNode: function (r) { return r; }, convertPointFromNode: function (p) { return p; }, addEventListener: noop, removeEventListener: noop, dispatchEvent: function () { return true; } });
            if (Ep && !Ep.pseudo) Ep.pseudo = function () { return null; };
        }
        if (window.Text && window.Text.prototype && !window.Text.prototype.getBoxQuads) {
            var geometry = { getBoxQuads: emptyRules, convertQuadFromNode: function (q) { return q; }, convertRectFromNode: function (r) { return r; }, convertPointFromNode: function (p) { return p; } };
            defaults('Text', geometry); defaults('Element', geometry); defaults('Document', geometry);
        }
        if (Ep && !('regionOverset' in Ep)) { Ep.regionOverset = 'empty'; Ep.getRegionFlowRanges = emptyRules; }
        // window / document / element view extras
        if (window.HTMLImageElement && window.HTMLImageElement.prototype && !('x' in window.HTMLImageElement.prototype)) {
            try {
                Object.defineProperty(window.HTMLImageElement.prototype, 'x', { get: function () { return Math.round(this.getBoundingClientRect().left + window.pageXOffset); }, configurable: true });
                Object.defineProperty(window.HTMLImageElement.prototype, 'y', { get: function () { return Math.round(this.getBoundingClientRect().top + window.pageYOffset); }, configurable: true });
            } catch (e1) {}
        }
        if (window.MouseEvent && window.MouseEvent.prototype && !('x' in window.MouseEvent.prototype)) {
            try {
                Object.defineProperty(window.MouseEvent.prototype, 'x', { get: function () { return this.clientX; }, configurable: true });
                Object.defineProperty(window.MouseEvent.prototype, 'y', { get: function () { return this.clientY; }, configurable: true });
            } catch (e2) {}
        }
        if (!window.moveTo) { window.moveTo = noop; window.moveBy = noop; window.resizeTo = noop; window.resizeBy = noop; }
        if (!window.scroll) window.scroll = window.scrollTo;
        // handler attributes for the prefixed animation and transition events
        var wireHandler = function (attr, eventName) {
            var Hp = window.HTMLElement && window.HTMLElement.prototype;
            if (!Hp || (attr in Hp)) return;
            try {
                Object.defineProperty(Hp, attr, {
                    get: function () { return this['__' + attr] || null; },
                    set: function (fn) { var old = this['__' + attr]; if (old && eventName) this.removeEventListener(eventName, old, false); this['__' + attr] = typeof fn === 'function' ? fn : null; if (fn && eventName) this.addEventListener(eventName, fn, false); },
                    configurable: true
                });
            } catch (e3) {}
        };
        wireHandler('ontransitionend', 'webkitTransitionEnd'); wireHandler('ontransitionstart', null); wireHandler('ontransitionrun', null); wireHandler('ontransitioncancel', null);
        wireHandler('onanimationstart', 'webkitAnimationStart'); wireHandler('onanimationiteration', 'webkitAnimationIteration'); wireHandler('onanimationend', 'webkitAnimationEnd'); wireHandler('onanimationcancel', null);
        wireHandler('onsnapchanged', null); wireHandler('onsnapchanging', null);
        var evProto = function (name) { return window[name] && window[name].prototype; };
        if (evProto('TransitionEvent') && !('pseudoElement' in evProto('TransitionEvent'))) evProto('TransitionEvent').pseudoElement = '';
        if (evProto('AnimationEvent') && !('pseudoElement' in evProto('AnimationEvent'))) evProto('AnimationEvent').pseudoElement = '';
        var simpleEvent = function (name, fields) {
            if (window[name]) return;
            window[name] = function (type, init) { var e = document.createEvent('Event'); e.initEvent(type, !!(init && init.bubbles), !!(init && init.cancelable)); for (var k in fields) if (fields.hasOwnProperty(k)) e[k] = init && init[k] !== undefined ? init[k] : fields[k]; return e; };
            try { window[name].prototype = Object.create(window.Event.prototype); window[name].prototype.constructor = window[name]; for (var f in fields) if (fields.hasOwnProperty(f)) window[name].prototype[f] = fields[f]; } catch (e4) {}
        };
        simpleEvent('SnapEvent', { snapTargetBlock: null, snapTargetInline: null });
        simpleEvent('ContentVisibilityAutoStateChangeEvent', { skipped: false });
        simpleEvent('PageRevealEvent', { viewTransition: null });
        simpleEvent('AnimationPlaybackEvent', { currentTime: null, timelineTime: null });
        simpleEvent('NavigationEvent', { dir: '', relatedTarget: null });
        // view transitions: the callback runs at once, the promises resolve (the spec's own fallback)
        if (!document.startViewTransition) {
            window.ViewTransition = window.ViewTransition || function ViewTransition() { this.updateCallbackDone = resolved(); this.ready = resolved(); this.finished = resolved(); };
            window.ViewTransition.prototype.skipTransition = noop;
            document.startViewTransition = function (cb) {
                var t = new window.ViewTransition(), fn = typeof cb === 'function' ? cb : cb && typeof cb.update === 'function' ? cb.update : null;
                var done = P ? new P(function (res, rej) { try { res(fn ? fn() : undefined); } catch (e) { rej(e); } }) : null;
                if (done) { t.updateCallbackDone = done; t.ready = done; t.finished = done; }
                return t;
            };
        }
        // animation timelines and effects (web-animations-2, scroll-animations-1)
        if (window.AnimationTimeline) {
            defaults('AnimationTimeline', { currentTime: 0, duration: null, play: function () { return new window.Animation(); } });
            if (!window.ScrollTimeline) { window.ScrollTimeline = function ScrollTimeline(options) { this.source = options && options.source || null; this.axis = options && options.axis || 'block'; }; window.ScrollTimeline.prototype = Object.create(window.AnimationTimeline.prototype); defaults('ScrollTimeline', { source: null, axis: 'block' }); }
            if (!window.ViewTimeline) { window.ViewTimeline = function ViewTimeline(options) { try { window.ScrollTimeline.call(this, options); } catch (e) {} this.subject = options && options.subject || null; this.startOffset = null; this.endOffset = null; }; window.ViewTimeline.prototype = Object.create(window.ScrollTimeline.prototype); defaults('ViewTimeline', { subject: null, startOffset: null, endOffset: null }); }
        }
        if (window.AnimationEffect) {
            defaults('AnimationEffect', { parent: null, previousSibling: null, nextSibling: null, before: noop, after: noop, replace: noop, remove: noop, getTiming: function () { return {}; }, getComputedTiming: function () { return {}; }, updateTiming: noop });
            defaults('KeyframeEffect', { iterationComposite: 'replace', iteratonComposite: 'replace' });
            if (!window.GroupEffect) {
                window.AnimationNodeList = function AnimationNodeList() { this.length = 0; }; window.AnimationNodeList.prototype.item = function () { return null; }; window.AnimationNodeList.prototype.length = 0;
                window.GroupEffect = function GroupEffect(children) { this.children = new window.AnimationNodeList(); this.firstChild = children && children[0] || null; this.lastChild = children && children[children.length - 1] || null; };
                window.GroupEffect.prototype = Object.create(window.AnimationEffect.prototype);
                defaults('GroupEffect', { children: null, firstChild: null, lastChild: null, clone: function () { return new window.GroupEffect(); }, prepend: noop, append: noop });
                window.SequenceEffect = function SequenceEffect(children) { window.GroupEffect.call(this, children); };
                window.SequenceEffect.prototype = Object.create(window.GroupEffect.prototype);
                defaults('SequenceEffect', { clone: function () { return new window.SequenceEffect(); } });
            }
        }
        if (window.Animation && !window.WorkletAnimation) { window.WorkletAnimation = function WorkletAnimation(name) { try { window.Animation.call(this); } catch (e) {} this.animatorName = name || ''; }; window.WorkletAnimation.prototype = Object.create(window.Animation.prototype); defaults('WorkletAnimation', { animatorName: '' }); }
        // resize observer entries with box sizes
        if (window.ResizeObserverEntry && window.ResizeObserverEntry.prototype && !('borderBoxSize' in window.ResizeObserverEntry.prototype)) {
            window.ResizeObserverSize = window.ResizeObserverSize || function ResizeObserverSize(inlineSize, blockSize) { this.inlineSize = inlineSize; this.blockSize = blockSize; };
            defaults('ResizeObserverSize', { inlineSize: 0, blockSize: 0 });
            var sizeOf = function (entry, border) { var t = entry.target, w = border ? t.offsetWidth : t.clientWidth, h = border ? t.offsetHeight : t.clientHeight; return [new window.ResizeObserverSize(w || 0, h || 0)]; };
            try {
                Object.defineProperty(window.ResizeObserverEntry.prototype, 'borderBoxSize', { get: function () { return sizeOf(this, true); }, configurable: true });
                Object.defineProperty(window.ResizeObserverEntry.prototype, 'contentBoxSize', { get: function () { return sizeOf(this, false); }, configurable: true });
                Object.defineProperty(window.ResizeObserverEntry.prototype, 'devicePixelContentBoxSize', { get: function () { var s = sizeOf(this, false)[0], r = window.devicePixelRatio || 1; return [new window.ResizeObserverSize(s.inlineSize * r, s.blockSize * r)]; }, configurable: true });
            } catch (e5) {}
        }
        // font loading extras
        if (window.FontFace) {
            if (!window.FontFaceFeatures) window.FontFaceFeatures = function FontFaceFeatures() {};
            if (!window.FontFaceVariationAxis) { window.FontFaceVariationAxis = function FontFaceVariationAxis() {}; defaults('FontFaceVariationAxis', { name: '', axisTag: '', minimumValue: 0, maximumValue: 0, defaultValue: 0 }); }
            if (!window.FontFacePalettes) { window.FontFacePalettes = function FontFacePalettes() {}; defaults('FontFacePalettes', { length: 0 }); }
            if (!window.FontFacePalette) { window.FontFacePalette = function FontFacePalette() {}; defaults('FontFacePalette', { length: 0, usableWithLightBackground: false, usableWithDarkBackground: false }); }
        }
        if (!window.Viewport) { window.Viewport = function Viewport() {}; defaults('Viewport', { segments: null }); if (!window.viewport) window.viewport = new window.Viewport(); }
    } catch (eCSSOM2) {}
})(window, document);
