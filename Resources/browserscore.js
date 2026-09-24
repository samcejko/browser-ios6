/* browserscore.js - runs the flattened browserscore/features tests (window.BROWSERSCORE_FEATURES, built by
 * tools/browserscore-convert.mjs) on this engine, in two layers: what the engine accepts natively, and what it
 * accepts after the app's CSS rewriter (window.CSSFix) has had its say. ES5 only. */
(function () {
    'use strict';
    var specs = window.BROWSERSCORE_FEATURES || [];
    var fix = window.CSSFix;
    var probe = document.createElement('div');
    var probeStyle = probe.style;
    var styleEl = document.createElement('style');
    styleEl.__brOwn = true;   // the native checks need the engine's own parse: the page shim must not rewrite it
    document.head.appendChild(styleEl);
    var cssPrefixes = ['', '-webkit-'];
    var domPrefixes = ['', 'webkit', 'Webkit', 'WebKit'];
    var NATIVE = 2, EMULATED = 1, FAIL = 0;
    var cache = {};
    var ctx = fix ? fix.makeContext({}) : null;
    // properties whose emulation only shows inside a flex or grid container rule
    var CONTEXT_PROPS = /^(gap|row-gap|column-gap|justify-content|justify-items|justify-self|align-items|align-content|align-self|place-(content|items|self)|order|flex.*|grid.*)$/;

    function camel(p) { return p.replace(/-([a-z])/g, function (m, c) { return c.toUpperCase(); }); }
    function prefixDom(prefix, name) { return prefix ? prefix + name.charAt(0).toUpperCase() + name.slice(1) : name; }

    // ---- native checks (browserscore/supports semantics on an engine without CSS.supports)
    function nativeProperty(p) {
        for (var i = 0; i < cssPrefixes.length; i++) {
            var name = cssPrefixes[i] + p;
            if ((name in probeStyle) || probeStyle[camel(name)] !== undefined) return true;
        }
        return false;
    }
    function nativeValue(p, v) {
        var okProp = null;
        for (var i = 0; i < cssPrefixes.length && okProp === null; i++) {
            if (nativePropertyExact(cssPrefixes[i] + p)) okProp = cssPrefixes[i] + p;
        }
        if (okProp === null) return false;
        for (var j = 0; j < cssPrefixes.length; j++) {
            try {
                probeStyle.setProperty(okProp, '');
                var lenBefore = probeStyle.length;
                probeStyle.setProperty(okProp, cssPrefixes[j] + v);
                var got = probeStyle.getPropertyValue(okProp);
                // this engine accepts and applies -webkit-calc() but serialises it as an empty value ("width: ;"): the
                // declaration being there is what counts
                var added = probeStyle.length > lenBefore;
                probeStyle.setProperty(okProp, '');
                if (got || added) return true;
            } catch (e) {}
        }
        return false;
    }
    function nativePropertyExact(name) { return (name in probeStyle) || probeStyle[camel(name)] !== undefined; }
    function rulesParse(css) {
        try {
            styleEl.textContent = css;
            var sheet = styleEl.sheet;
            return sheet && sheet.cssRules && sheet.cssRules.length > 0 ? sheet.cssRules[0] : null;
        } catch (e) { return null; }
    }
    function nativeSelector(s) {
        for (var i = 0; i < cssPrefixes.length; i++) {
            var sel = s.replace(/^[@:]*/, function (m) { return m + cssPrefixes[i]; });
            if (rulesParse(sel + '{}')) return true;
        }
        return false;
    }
    function atruleCSS(code, contents, parent, before) {
        var body = code;
        if (contents === false) body += ';';
        else body += '{ ' + (typeof contents === 'string' ? contents : '') + ' }';
        if (before) body = before + body;
        if (parent) body = parent + ' { ' + body + ' }';
        return body;
    }
    function nativeAtrule(t) {
        for (var i = 0; i < cssPrefixes.length; i++) {
            var code = t.code.replace(/^@/, '@' + cssPrefixes[i]);
            var rule = rulesParse(atruleCSS(code, t.contents, t.parent, t.before));
            if (!rule) continue;
            if (t.parent || t.before) {
                // the outer rule always parses: the inner one counts only if it changed the serialisation
                var without = rulesParse(t.parent ? t.parent + ' { ' + (t.before || '') + ' }' : (t.before || ''));
                var textWithout = without ? without.cssText : '';
                var withRule = rulesParse(atruleCSS(code, t.contents, t.parent, t.before));
                if (withRule && withRule.cssText !== textWithout) return true;
                continue;
            }
            return true;
        }
        return false;
    }
    function atruleInstance(at) {
        for (var i = 0; i < cssPrefixes.length; i++) {
            var rule = rulesParse(at.replace(/^@/, '@' + cssPrefixes[i]) + ' { }');
            if (rule) return rule;
        }
        return null;
    }
    function nativeDescriptor(at, d) {
        var rule = atruleInstance(at);
        if (!rule) return false;
        var style = rule.style || rule;
        return (d in style) || style[camel(d)] !== undefined || (style.getPropertyValue && style.getPropertyValue(d) !== undefined && (d in style));
    }
    function nativeDescriptorValue(at, d, v) {
        var rule = rulesParse(at + ' { ' + d + ': ' + v + '; }');
        if (!rule) return false;
        var style = rule.style || rule;
        var got = style.getPropertyValue ? style.getPropertyValue(d) : style[camel(d)];
        return Boolean(got);
    }
    function nativeMedia(q) {
        try { return window.matchMedia && window.matchMedia(q).media.indexOf('not all') < 0; } catch (e) { return false; }
    }
    function resolveGlobal(g) {
        for (var i = 0; i < domPrefixes.length; i++) {
            var name = prefixDom(domPrefixes[i], g);
            if (name in window) return name;
        }
        if (g.indexOf('CSS') === 0) {
            for (var j = 1; j < domPrefixes.length; j++) {
                var alt = 'CSS' + prefixDom(domPrefixes[j], g.slice(3));
                if (alt in window) return alt;
            }
        }
        return null;
    }
    // This engine keeps IDL attributes on the instances, not on the prototypes, so a prototype lookup alone would
    // report almost every DOM attribute as missing. When the prototype has nothing, a real instance is asked.
    var instanceFactories = {
        Element: function () { return document.createElement('div'); },
        HTMLElement: function () { return document.createElement('div'); },
        HTMLImageElement: function () { return document.createElement('img'); },
        HTMLInputElement: function () { return document.createElement('input'); },
        HTMLVideoElement: function () { return document.createElement('video'); },
        HTMLMediaElement: function () { return document.createElement('video'); },
        HTMLCanvasElement: function () { return document.createElement('canvas'); },
        HTMLIFrameElement: function () { return document.createElement('iframe'); },
        HTMLStyleElement: function () { return document.createElement('style'); },
        HTMLLinkElement: function () { return document.createElement('link'); },
        Node: function () { return document.createElement('div'); },
        Document: function () { return document; },
        Text: function () { return document.createTextNode('x'); },
        Range: function () { return document.createRange(); },
        Window: function () { return window; },
        Screen: function () { return window.screen; },
        Navigator: function () { return window.navigator; },
        History: function () { return window.history; },
        Location: function () { return window.location; },
        Performance: function () { return window.performance; },
        Storage: function () { return window.localStorage; },
        MediaQueryList: function () { return window.matchMedia('all'); },
        CSSStyleDeclaration: function () { return document.createElement('div').style; },
        StyleSheet: function () { return styleSheetInstance(); },
        StyleSheetList: function () { return document.styleSheets; },
        MediaList: function () { var s = styleSheetInstance(); return s && s.media; },
        CSSRuleList: function () { var s = styleSheetInstance(); return s && s.cssRules; },
        CSSStyleSheet: function () { return styleSheetInstance(); },
        CSSRule: function () { return ruleInstance('.bs-x { color: red }'); },
        CSSStyleRule: function () { return ruleInstance('.bs-x { color: red }'); },
        CSSMediaRule: function () { return ruleInstance('@media all { .bs-x { color: red } }'); },
        CSSFontFaceRule: function () { return ruleInstance('@font-face { font-family: x }'); },
        CSSImportRule: function () { return ruleInstance('@import url(x.css);'); },
        CSSPageRule: function () { return ruleInstance('@page { margin: 0 }'); },
        CSSKeyframesRule: function () { return ruleInstance('@-webkit-keyframes bsk { from { top: 0 } }'); },
        CSSKeyframeRule: function () { var r = ruleInstance('@-webkit-keyframes bsk { from { top: 0 } }'); return r && r.cssRules ? r.cssRules[0] : null; },
        Event: function () { return document.createEvent('Event'); },
        UIEvent: function () { return document.createEvent('UIEvent'); },
        MouseEvent: function () { return document.createEvent('MouseEvent'); },
        KeyboardEvent: function () { return document.createEvent('KeyboardEvent'); },
        TouchEvent: function () { return document.createEvent('TouchEvent'); },
        AnimationEvent: function () { return document.createEvent('WebKitAnimationEvent'); },
        TransitionEvent: function () { return document.createEvent('WebKitTransitionEvent'); },
        CustomEvent: function () { return document.createEvent('CustomEvent'); },
        XMLHttpRequest: function () { return new XMLHttpRequest(); },
        Image: function () { return new Image(); },
        FontFace: function () { return window.FontFace ? new window.FontFace('bs', 'url(x)') : null; },
        FontFaceSet: function () { return document.fonts; },
        Animation: function () { return window.Animation ? new window.Animation() : null; },
        DOMMatrix: function () { return window.DOMMatrix ? new window.DOMMatrix() : null; },
        DOMRect: function () { return document.createElement('div').getBoundingClientRect(); },
        ClientRect: function () { return document.createElement('div').getBoundingClientRect(); },
        VisualViewport: function () { return window.visualViewport; },
        Highlight: function () { return window.Highlight ? new window.Highlight() : null; },
        IntersectionObserver: function () { return window.IntersectionObserver ? new window.IntersectionObserver(function () {}) : null; },
        ResizeObserver: function () { return window.ResizeObserver ? new window.ResizeObserver(function () {}) : null; },
        MutationObserver: function () { return window.MutationObserver ? new window.MutationObserver(function () {}) : null; }
    };
    function styleSheetInstance() { rulesParse('.bs-x { color: red }'); return styleEl.sheet; }
    function ruleInstance(css) { return rulesParse(css); }
    function instanceOf(g) {
        var f = instanceFactories[g];
        if (!f) return null;
        try { return f() || null; } catch (e) { return null; }
    }
    function memberPresent(object, t) {
        for (var i = 0; i < domPrefixes.length; i++) {
            var m = prefixDom(domPrefixes[i], t.m);
            var present = false;
            try { present = (m in object); } catch (e) { present = false; }
            if (!present) continue;
            if (t.fn) { var type; try { type = typeof object[m]; } catch (e2) { return false; } return type === 'function'; }
            return true;
        }
        return false;
    }
    function nativeMember(t) {
        var name = resolveGlobal(t.g);
        if (!name) return false;
        var object = window[name];
        if (!object) return false;
        var isConstructor = typeof object === 'function' || (typeof object === 'object' && object.prototype && /^[A-Z]/.test(t.g));
        if (t.path && isConstructor) {
            var proto = object[t.path];
            if (proto && memberPresent(proto, t)) return true;
            var inst = instanceOf(t.g);
            return inst ? memberPresent(inst, t) : false;
        }
        // lower-case globals (document, navigator) are instances themselves
        return memberPresent(object, t);
    }
    function nativeExtends(g, s) {
        var C = window[resolveGlobal(g) || g], S = window[resolveGlobal(s) || s];
        if (!C || !S) return false;
        var p = C;
        try { for (;;) { p = Object.getPrototypeOf(p); if (!p) return false; if (p === S) return true; } } catch (e) { return false; }
    }
    function nativeInstanceof(g, c) {
        var o = window[resolveGlobal(g) || g], C = window[resolveGlobal(c) || c];
        try { return !!(o && C && o instanceof C); } catch (e) { return false; }
    }

    // ---- the rewriter's view: does cssfix turn the syntax into something the engine accepts?
    function parseRewritten(css) {   // "sel{p:v;p:v}\nsel2{...}" -> [{sel, decls:[[p,v]]}]
        var rules = [], re = /([^{}]+)\{([^{}]*)\}/g, m;
        while ((m = re.exec(css)) !== null) {
            var decls = [], parts = m[2].split(';');
            for (var i = 0; i < parts.length; i++) {
                var colon = parts[i].indexOf(':');
                if (colon < 0) continue;
                decls.push([parts[i].slice(0, colon).replace(/^\s+|\s+$/g, ''), parts[i].slice(colon + 1).replace(/^\s+|\s+$/g, '').replace(/\s*!important$/, '')]);
            }
            rules.push({ sel: m[1].replace(/^\s+|\s+$/g, ''), decls: decls });
        }
        return rules;
    }
    function rewriteCSS(css) {
        if (!fix) return '';
        try { return fix.fixCSS(css, ctx) || ''; } catch (e) { return ''; }
    }
    // the declaration (and any extra rules) after rewriting, given an optional container context
    var contextBaseline = {};
    function contextRuleCount(context) {
        if (!context) return 1;
        if (contextBaseline[context] === undefined) contextBaseline[context] = parseRewritten(rewriteCSS('.bs{' + context + '}')).length;
        return contextBaseline[context];
    }
    function emulatedDeclaration(p, v, context) {
        var css = '.bs{' + (context || '') + p + ':' + v + '}';
        var out = rewriteCSS(css);
        if (!out) return false;
        var rules = parseRewritten(out);
        if (!rules.length) return false;
        var main = rules[0];
        // rules the declaration added beyond what the bare context produces (grid columns, flex gaps, wrap items)
        var extra = rules.length > contextRuleCount(context);
        var accepted = extra, changed = extra;
        var contextProps = context ? parseRewritten(rewriteCSS('.bs{' + context + '}'))[0].decls : [];
        for (var i = 0; i < main.decls.length; i++) {
            var dp = main.decls[i][0], dv = main.decls[i][1];
            var fromContext = false;
            for (var c = 0; c < contextProps.length; c++) if (contextProps[c][0] === dp && contextProps[c][1] === dv) fromContext = true;
            if (fromContext) continue;
            if (dp !== p || dv.toLowerCase() !== v.toLowerCase()) changed = true;
            if (nativeValue(dp, dv)) accepted = true;
        }
        if (changed && accepted) return true;
        // declarations the page shim resolves per element (custom properties that differ between elements, inherit())
        var m = manifestOf(css);
        if (m && m.cv) {
            for (var k = 0; k < m.cv.length; k++) {
                var uses = m.cv[k].u || [];
                for (var u = 0; u < uses.length; u++) if (uses[u][0] === p) return true;
            }
        }
        return false;
    }
    function emulatedValue(p, v) {
        if (emulatedDeclaration(p, v, '')) return true;
        if (CONTEXT_PROPS.test(p)) return emulatedDeclaration(p, v, 'display:flex;') || emulatedDeclaration(p, v, 'display:grid;grid-template-columns:1fr 1fr;');
        return false;
    }
    function emulatedProperty(p) {
        return emulatedValue(p, 'inherit') || emulatedValue(p, 'initial') || (CONTEXT_PROPS.test(p) && emulatedValue(p, '1px'));
    }
    function emulatedSelector(s) {
        if (!fix) return false;
        if (s.indexOf('&') >= 0) {
            // the nesting selector only exists inside a nested rule: the rewriter flattens ".bs{&:hover{}}" into ".bs:hover{}"
            var nested = rewriteCSS('.bs{' + s + '{color:rgb(1,2,3)}}');
            var nr = parseRewritten(nested);
            for (var n = 0; n < nr.length; n++) {
                if (nr[n].decls.length === 1 && nr[n].decls[0][0] === 'color' && nr[n].decls[0][1] === 'rgb(1,2,3)') return nr[n].sel.indexOf('&') < 0 && nativeSelector(nr[n].sel);
            }
            return false;
        }
        var list;
        try { list = fix.fixSelectorList(s); } catch (e) { return false; }
        if (!list || !list.length) return false;
        for (var i = 0; i < list.length; i++) {
            if (list[i] === s) return false;   // unchanged, and the native check already failed
            if (!nativeSelector(list[i])) return false;
        }
        return true;
    }
    function emulatedAtrule(t) {
        if (!fix || t.parent) return false;
        var m = /^@([a-z-]+)\s*([\s\S]*)$/i.exec(t.code);
        if (!m) return false;
        var name = m[1].toLowerCase(), prelude = m[2].replace(/^\s+|\s+$/g, '');
        try {
            // conditions the rewriter evaluates itself (the rule is then unwrapped or dropped on purpose)
            if (name === 'supports') return typeof fix.evalSupports(prelude) === 'boolean';
            if (name === 'media') { var q = fix.fixMedia(prelude); return typeof q === 'string' && nativeMedia(q); }
            if (name === 'layer' || name === 'scope') {
                if (t.contents === false) return true;   // statements are consumed without error
                var out = rewriteCSS(t.code + '{.bs{color:rgb(1,2,3)}}');
                return /\.bs\s*\{/.test(out) && rulesParse(out) !== null;
            }
            if (name === 'property') {
                // the rule itself is consumed, and a registered initial value reaches var() users
                var pout = rewriteCSS(t.code + '{' + (typeof t.contents === 'string' ? t.contents : '') + '}.bs{color:rgb(1,2,3)}');
                if (!/\.bs\s*\{color:rgb\(1,2,3\)\}/.test(pout)) return false;
                var seeded = rewriteCSS('@property --bsp{syntax:"<length>";inherits:false;initial-value:7px}.bs{width:var(--bsp)}');
                return /\.bs\s*\{width:7px\}/.test(seeded);
            }
            if (name === 'position-try') {
                // the rule goes to the page manifest, where the deferred-value shim uses it for position-try-fallbacks
                var tm = manifestOf(t.code + '{' + (typeof t.contents === 'string' && t.contents ? t.contents : 'top:anchor(bottom)') + '}');
                if (!tm || !tm.pt) return false;
                for (var pi = 0; pi < tm.pt.length; pi++) if (tm.pt[pi].n === prelude) return true;
                return false;
            }
        } catch (e) { return false; }
        var inner = typeof t.contents === 'string' && t.contents ? t.contents : '.bs{color:rgb(1,2,3)}';
        var css = t.contents === false ? t.code + ';' : t.code + '{' + inner + '}';
        var rewritten = rewriteCSS(css);
        if (!rewritten || !/\S/.test(rewritten)) return false;
        return rulesParse(rewritten) !== null && rewritten.replace(/\s+/g, '') !== css.replace(/\s+/g, '');
    }
    // the manifest the rewriter produces for a stylesheet (deferred values, position-try rules), or null
    function manifestOf(css) {
        if (!fix || !fix.run) return null;
        try { var r = JSON.parse(fix.run('css', css, null)); return r.manifest || null; } catch (e) { return null; }
    }
    // descriptors of at-rules the rewriter hands to the page shim
    function emulatedDescriptor(at, d) {
        if (!/^@position-try\s/i.test(at)) return false;
        var m = manifestOf(at + '{' + d + ':initial}');
        if (!m || !m.pt || !m.pt.length) return false;
        var decls = m.pt[m.pt.length - 1].d || [];
        for (var i = 0; i < decls.length; i++) if (decls[i][0] === d) return true;
        return false;
    }
    function emulatedMedia(q) {
        if (!fix) return false;
        var fixed;
        try { fixed = fix.fixMedia(q); } catch (e) { return false; }
        return typeof fixed === 'string' && fixed !== q && nativeMedia(fixed);
    }

    // ---- one test
    function runTest(t) {
        var key = JSON.stringify(t);
        if (cache[key] !== undefined) return cache[key];
        var r = FAIL;
        try {
            switch (t.k) {
                case 'prop': r = nativeProperty(t.p) ? NATIVE : (emulatedProperty(t.p) ? EMULATED : FAIL); break;
                case 'val': r = nativeValue(t.p, t.v) ? NATIVE : (emulatedValue(t.p, t.v) ? EMULATED : FAIL); break;
                case 'sel': r = nativeSelector(t.s) ? NATIVE : (emulatedSelector(t.s) ? EMULATED : FAIL); break;
                case 'at': r = nativeAtrule(t) ? NATIVE : (emulatedAtrule(t) ? EMULATED : FAIL); break;
                case 'desc': r = nativeDescriptor(t.at, t.d) ? NATIVE : (emulatedDescriptor(t.at, t.d) ? EMULATED : FAIL); break;
                case 'descval': r = nativeDescriptorValue(t.at, t.d, t.v) ? NATIVE : FAIL; break;
                case 'mq': r = nativeMedia(t.q) ? NATIVE : (emulatedMedia(t.q) ? EMULATED : FAIL); break;
                case 'global': r = resolveGlobal(t.g) ? NATIVE : FAIL; break;
                case 'member': r = nativeMember(t) ? NATIVE : FAIL; break;
                case 'extends': r = nativeExtends(t.g, t.s) ? NATIVE : FAIL; break;
                case 'instanceof': r = nativeInstanceof(t.g, t.c) ? NATIVE : FAIL; break;
            }
        } catch (e) { r = FAIL; }
        cache[key] = r;
        return r;
    }
    function describe(t) {
        switch (t.k) {
            case 'prop': return t.p;
            case 'val': return t.p + ': ' + t.v;
            case 'sel': return t.s;
            case 'at': return t.code + (t.parent ? ' (v ' + t.parent + ')' : '');
            case 'desc': return t.at + ' { ' + t.d + ' }';
            case 'descval': return t.at + ' { ' + t.d + ': ' + t.v + ' }';
            case 'mq': return '@media ' + t.q;
            case 'global': return t.g;
            case 'member': return t.g + (t.path ? '.prototype.' : '.') + t.m + (t.fn ? '()' : '');
            case 'extends': return t.g + ' extends ' + t.s;
            case 'instanceof': return t.g + ' instanceof ' + t.c;
        }
        return JSON.stringify(t);
    }

    // ---- run everything in slices, then render
    var results = [], si = 0, fi = 0, totals = { total: 0, native: 0, emulated: 0, fail: 0 };
    var status = document.getElementById('bs-status'), out = document.getElementById('bs-results'), scoreEl = document.getElementById('bs-score');
    var started = new Date().getTime();

    function runSlice() {
        var deadline = new Date().getTime() + 60;
        while (si < specs.length) {
            var spec = specs[si];
            if (!results[si]) results[si] = { spec: spec, total: 0, native: 0, emulated: 0, fail: 0, missing: [], emulatedList: [] };
            var r = results[si];
            while (fi < spec.features.length) {
                var f = spec.features[fi], gate = f.gate ? runTest(f.gate) : null;
                var count = (f.gate ? 1 : 0) + f.tests.length;
                r.total += count;
                if (gate === FAIL) {
                    r.fail += count;
                    r.missing.push(describe(f.gate) + (f.tests.length ? ' (+' + f.tests.length + ')' : ''));
                } else {
                    if (gate === NATIVE) r.native++; else if (gate === EMULATED) { r.emulated++; r.emulatedList.push(describe(f.gate)); }
                    for (var i = 0; i < f.tests.length; i++) {
                        var tr = runTest(f.tests[i]);
                        if (tr === NATIVE) r.native++;
                        else if (tr === EMULATED) { r.emulated++; r.emulatedList.push(describe(f.tests[i])); }
                        else { r.fail++; r.missing.push(describe(f.tests[i])); }
                    }
                }
                fi++;
                if (new Date().getTime() > deadline) { updateStatus(); setTimeout(runSlice, 0); return; }
            }
            totals.total += r.total; totals.native += r.native; totals.emulated += r.emulated; totals.fail += r.fail;
            si++; fi = 0;
        }
        render();
    }
    function updateStatus() {
        if (status) status.textContent = 'Testuji ' + (si + 1) + ' / ' + specs.length + ' specifikací…';
    }
    function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
    function pct(a, b) { return b ? Math.round(a * 1000 / b) / 10 : 0; }
    function render() {
        var passed = totals.native + totals.emulated;
        if (scoreEl) scoreEl.textContent = pct(passed, totals.total) + ' %';
        if (status) status.textContent = passed + ' z ' + totals.total + ' testů: ' + totals.native + ' nativně, ' + totals.emulated + ' přes přepis, ' + totals.fail + ' chybí (' + Math.round((new Date().getTime() - started) / 1000) + ' s)';
        var html = '';
        var groups = [['stable', 'Stabilní specifikace'], ['experimental', 'Experimentální specifikace'], ['', 'Ostatní']];
        for (var g = 0; g < groups.length; g++) {
            var rows = '';
            for (var i = 0; i < results.length; i++) {
                var r = results[i], st = r.spec.status || '';
                if ((groups[g][0] === '' && (st === 'stable' || st === 'experimental')) || (groups[g][0] !== '' && st !== groups[g][0])) continue;
                if (!r.total) continue;
                var ok = r.native + r.emulated;
                rows += '<div class="spec' + (r.fail ? ' has-missing' : '') + '"><div class="head" data-i="' + i + '"><span class="pct">' + pct(ok, r.total) + ' %</span><b>' + esc(r.spec.title) + '</b>' +
                        '<i>' + r.native + ' + ' + r.emulated + ' / ' + r.total + '</i></div>' +
                        '<div class="detail" id="bs-d' + i + '" style="display:none">' +
                        (r.emulatedList.length ? '<p class="emu">Přes přepis CSS: ' + esc(r.emulatedList.join(' · ')) + '</p>' : '') +
                        (r.missing.length ? '<p class="miss">Chybí: ' + esc(r.missing.join(' · ')) + '</p>' : '<p class="all">Vše prochází.</p>') + '</div></div>';
            }
            if (rows) html += '<h2>' + groups[g][1] + '</h2>' + rows;
        }
        if (out) out.innerHTML = html;
        document.title = 'Browserscore: ' + pct(passed, totals.total) + ' %';
        window.BROWSERSCORE_RESULT = { totals: totals, specs: results.map(function (r) { return { id: r.spec.id, total: r.total, native: r.native, emulated: r.emulated, missing: r.missing, emulated_list: r.emulatedList }; }) };
        if (out) out.onclick = function (e) {
            var el = e.target;
            while (el && el !== out && !(el.className === 'head')) el = el.parentNode;
            if (!el || el === out) return;
            var d = document.getElementById('bs-d' + el.getAttribute('data-i'));
            if (d) d.style.display = d.style.display === 'none' ? 'block' : 'none';
        };
    }
    if (!specs.length) { if (status) status.textContent = 'Chybí data testů (browserscore-features.js).'; return; }
    if (!fix && status) status.textContent = 'Přepisovač CSS není k dispozici, měřím jen engine.';
    setTimeout(runSlice, 50);
})();
