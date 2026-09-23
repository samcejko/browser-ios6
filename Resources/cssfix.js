/*
 * cssfix.js - rewrites modern CSS so that the iOS 6 WebKit (536.26) can render it.
 *
 * Runs inside JavaScriptCore on the device (ES5 only!) and in the test harness.
 *
 *   CSSFix.run(kind, text, pageVars)  ->  JSON string {"out": ..., "vars": {...}}
 *     kind: "css" or "html"; pageVars: object or JSON string of already known :root custom properties
 *
 * What it does:
 *   - custom properties: static substitution (rule-local, page, :root, other), fallbacks honoured
 *   - flexbox (2012 syntax) -> the 2009 -webkit-box model; wrapping containers fall back to block
 *   - vendor prefixes: transform, transition, animation, @keyframes, columns, filter, mask, ...
 *   - calc() -> -webkit-calc(), gradients -> -webkit-*-gradient() with old direction syntax
 *   - colours: rgb(r g b / a), #rrggbbaa, hsl(), hwb(), oklch(), oklab(), lab(), lch(), color-mix()
 *   - clamp()/min()/max() approximated, env() removed, logical properties -> physical, inset -> t/r/b/l
 *   - selectors: :is()/:where() -> :-webkit-any() or expansion, :not(a,b) -> :not(a):not(b),
 *     :focus-visible -> :focus, ::placeholder -> ::-webkit-input-placeholder, unsupported ones dropped
 *     per selector instead of the whole rule
 *   - @supports evaluated and unwrapped/dropped, @layer unwrapped, @container dropped,
 *     @media range syntax and resolution converted, hover/pointer/prefers-* queries resolved
 */
var CSSFix = (function () {
    'use strict';

    // ------------------------------------------------------------------ scanning helpers

    function isWS(c) { return c === 32 || c === 9 || c === 10 || c === 13 || c === 12; }

    // index just past the string that starts at i (s[i] is the quote)
    function skipString(s, i, n) {
        var q = s.charCodeAt(i);
        i++;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 92) { i += 2; continue; }          // backslash escape
            if (c === q) return i + 1;
            if (c === 10) return i;                        // unterminated string ends at newline
            i++;
        }
        return n;
    }

    function stripComments(s) {
        if (s.indexOf('/*') < 0) return s;
        var out = [], i = 0, n = s.length, start = 0;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, n); continue; }
            if (c === 47 && s.charCodeAt(i + 1) === 42) {
                out.push(s.slice(start, i));
                var e = s.indexOf('*/', i + 2);
                i = e < 0 ? n : e + 2;
                start = i;
                continue;
            }
            i++;
        }
        out.push(s.slice(start));
        return out.join('');
    }

    // advances from i until a char of `stops` at depth 0 (parens/brackets), respecting strings and escapes
    function scanUntil(s, i, end, stops) {
        var depth = 0;
        while (i < end) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, end); continue; }
            if (c === 92) { i += 2; continue; }
            if (c === 40 || c === 91) depth++;
            else if (c === 41 || c === 93) { if (depth > 0) depth--; }
            else if (depth === 0 && stops.indexOf(s.charAt(i)) >= 0) return i;
            i++;
        }
        return end;
    }

    // s[i] === '{'; returns the index of the matching '}' or -1
    function findBlockEnd(s, i, end) {
        var depth = 0;
        while (i < end) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, end); continue; }
            if (c === 92) { i += 2; continue; }
            if (c === 123) depth++;
            else if (c === 125) { depth--; if (depth === 0) return i; }
            i++;
        }
        return -1;
    }

    // s[i] === '('; returns index of the matching ')' or s.length
    function matchParen(s, i) {
        var depth = 0, n = s.length;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, n); continue; }
            if (c === 92) { i += 2; continue; }
            if (c === 40) depth++;
            else if (c === 41) { depth--; if (depth === 0) return i; }
            i++;
        }
        return n;
    }

    // split at depth 0 by a single character
    function splitTop(s, sep) {
        var parts = [], i = 0, n = s.length, start = 0, depth = 0;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, n); continue; }
            if (c === 92) { i += 2; continue; }
            if (c === 40 || c === 91) depth++;
            else if (c === 41 || c === 93) { if (depth > 0) depth--; }
            else if (depth === 0 && s.charAt(i) === sep) { parts.push(s.slice(start, i)); start = i + 1; }
            i++;
        }
        parts.push(s.slice(start));
        return parts;
    }

    // split by whitespace at depth 0
    function splitWS(s) {
        var parts = [], i = 0, n = s.length, start = -1, depth = 0;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { if (start < 0) start = i; i = skipString(s, i, n); continue; }
            if (c === 40) depth++;
            else if (c === 41) { if (depth > 0) depth--; }
            if (depth === 0 && isWS(c)) {
                if (start >= 0) { parts.push(s.slice(start, i)); start = -1; }
            } else if (start < 0) start = i;
            i++;
        }
        if (start >= 0) parts.push(s.slice(start));
        return parts;
    }

    function trim(s) { return s.replace(/^\s+|\s+$/g, ''); }

    // ------------------------------------------------------------------ parser

    var RULE_AT = { media: 1, supports: 1, layer: 1, container: 1, keyframes: 1, '-webkit-keyframes': 1, document: 1, '-moz-document': 1, scope: 1, 'starting-style': 1 };
    var DECL_AT = { 'font-face': 1, page: 1, property: 1, 'counter-style': 1, viewport: 1, '-ms-viewport': 1, 'font-palette-values': 1 };

    function atName(prelude) {
        var m = /^@([a-zA-Z_-][a-zA-Z0-9_-]*)/.exec(prelude);
        return m ? m[1].toLowerCase() : '';
    }

    function parseDecls(str) {
        var decls = [], i = 0, n = str.length, start = 0, depth = 0;
        function flush(end) {
            var seg = trim(str.slice(start, end));
            if (!seg) return;
            var colon = seg.indexOf(':');
            if (colon <= 0) return;
            var p = trim(seg.slice(0, colon)).toLowerCase();
            var v = trim(seg.slice(colon + 1));
            var imp = false;
            var m = /!\s*important\s*$/i.exec(v);
            if (m) { imp = true; v = trim(v.slice(0, m.index)); }
            if (p.charAt(0) === '*' || p.charAt(0) === '_') return;   // old IE hacks
            decls.push({ p: p, v: v, imp: imp });
        }
        while (i < n) {
            var c = str.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(str, i, n); continue; }
            if (c === 92) { i += 2; continue; }
            if (c === 40 || c === 91) depth++;
            else if (c === 41 || c === 93) { if (depth > 0) depth--; }
            else if (depth === 0 && c === 123) {          // nested rule (CSS nesting): skip it
                var e = findBlockEnd(str, i, n);
                start = e < 0 ? n : e + 1;
                i = start;
                continue;
            } else if (depth === 0 && c === 59) { flush(i); start = i + 1; }
            i++;
        }
        flush(n);
        return decls;
    }

    function parseRules(s, i, end, out) {
        while (i < end) {
            var c = s.charCodeAt(i);
            if (isWS(c) || c === 125 || c === 59) { i++; continue; }
            if (c === 64) {   // @rule
                var j = scanUntil(s, i, end, '{;');
                var prelude = trim(s.slice(i, j));
                var name = atName(prelude);
                var rest = trim(prelude.slice(name.length + 1));
                if (j >= end || s.charCodeAt(j) === 59) {
                    out.push({ t: 'at', name: name, prelude: rest, rules: null, decls: null, raw: null });
                    i = j + 1;
                    continue;
                }
                var close = findBlockEnd(s, j, end);
                if (close < 0) close = end;
                var node = { t: 'at', name: name, prelude: rest, rules: null, decls: null, raw: null };
                if (RULE_AT[name]) { node.rules = []; parseRules(s, j + 1, close, node.rules); }
                else if (DECL_AT[name]) node.decls = parseDecls(s.slice(j + 1, close));
                else node.raw = s.slice(i, close + 1);
                out.push(node);
                i = close + 1;
                continue;
            }
            var j2 = scanUntil(s, i, end, '{;}');
            if (j2 >= end || s.charCodeAt(j2) !== 123) { i = j2 + 1; continue; }
            var sel = trim(s.slice(i, j2));
            var close2 = findBlockEnd(s, j2, end);
            if (close2 < 0) close2 = end;
            out.push({ t: 'q', sel: sel, decls: parseDecls(s.slice(j2 + 1, close2)) });
            i = close2 + 1;
        }
    }

    function serializeDecls(decls) {
        var parts = [];
        for (var i = 0; i < decls.length; i++) {
            var d = decls[i];
            parts.push(d.p + ':' + d.v + (d.imp ? ' !important' : ''));
        }
        return parts.join(';');
    }

    function serializeRules(rules) {
        var out = [];
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.t === 'q') out.push(r.sel + '{' + serializeDecls(r.decls) + '}');
            else if (r.t === 'raw') out.push(r.raw);
            else if (r.t === 'at') {
                var head = '@' + r.name + (r.prelude ? ' ' + r.prelude : '');
                if (r.rules) out.push(head + '{' + serializeRules(r.rules) + '}');
                else if (r.decls) out.push(head + '{' + serializeDecls(r.decls) + '}');
                else if (r.raw) out.push(r.raw);
                else out.push(head + ';');
            }
        }
        return out.join('\n');
    }

    // ------------------------------------------------------------------ custom properties

    function isRootSelector(sel) {
        var parts = splitTop(sel, ',');
        for (var i = 0; i < parts.length; i++) {
            var p = trim(parts[i]).toLowerCase();
            if (p === ':root' || p === 'html' || p === 'body' || p === '*' || p === 'html,body' || p === ':root,body') return true;
        }
        return false;
    }

    function collectVars(rules, ctx, inMedia) {
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.t === 'q') {
                var root = !inMedia && isRootSelector(r.sel);
                for (var k = 0; k < r.decls.length; k++) {
                    var d = r.decls[k];
                    if (d.p.charAt(0) === '-' && d.p.charAt(1) === '-') {
                        if (root) ctx.root[d.p] = d.v;
                        else if (!(d.p in ctx.root)) ctx.other[d.p] = d.v;
                    }
                }
            } else if (r.t === 'at' && r.rules) {
                if (r.name === 'keyframes' || r.name === '-webkit-keyframes') continue;
                collectVars(r.rules, ctx, inMedia || r.name === 'media' || r.name === 'container');
            }
        }
    }

    // returns the value with var() resolved, or null when it cannot be resolved
    function resolveVars(v, local, ctx) {
        for (var iter = 0; iter < 12; iter++) {
            var at = v.indexOf('var(');
            if (at < 0) return v;
            // make sure this is the function name, not e.g. "--foo-var("
            if (at > 0 && /[a-zA-Z0-9_-]/.test(v.charAt(at - 1))) {
                // search further
                var later = v.indexOf('var(', at + 4);
                while (later > 0 && /[a-zA-Z0-9_-]/.test(v.charAt(later - 1))) later = v.indexOf('var(', later + 4);
                if (later < 0) return v;
                at = later;
            }
            var close = matchParen(v, at + 3);
            var inner = v.slice(at + 4, close);
            var comma = scanUntil(inner, 0, inner.length, ',');
            var name = trim(inner.slice(0, comma));
            var fallback = comma < inner.length ? trim(inner.slice(comma + 1)) : null;
            var val = null;
            if (local && name in local) val = local[name];
            else if (name in ctx.page) val = ctx.page[name];
            else if (name in ctx.root) val = ctx.root[name];
            else if (name in ctx.other) val = ctx.other[name];
            else if (fallback !== null) val = fallback;
            if (val === null) return null;
            v = v.slice(0, at) + trim(val) + v.slice(close + 1);
        }
        return null;
    }

    // ------------------------------------------------------------------ colours

    var NAMED = { black: [0, 0, 0], white: [255, 255, 255], red: [255, 0, 0], green: [0, 128, 0], blue: [0, 0, 255], yellow: [255, 255, 0],
        gray: [128, 128, 128], grey: [128, 128, 128], silver: [192, 192, 192], orange: [255, 165, 0], purple: [128, 0, 128], pink: [255, 192, 203],
        transparent: [0, 0, 0, 0], currentcolor: null };

    function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
    function gamma(c) { c = clamp01(c); return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }
    function to255(c) { return Math.round(clamp01(c) * 255); }

    function numOrPct(tok, scale) {   // "50%" -> scale*0.5 ; "0.5" -> 0.5 ; "none" -> 0
        if (tok === 'none') return 0;
        if (tok.charAt(tok.length - 1) === '%') return parseFloat(tok) / 100 * scale;
        return parseFloat(tok);
    }

    function alphaOf(tok) {
        if (tok === undefined || tok === null) return 1;
        if (tok.charAt(tok.length - 1) === '%') return parseFloat(tok) / 100;
        return parseFloat(tok);
    }

    function hueDeg(tok) {
        var v = parseFloat(tok);
        if (/grad$/.test(tok)) v = v * 0.9;
        else if (/rad$/.test(tok)) v = v * 180 / Math.PI;
        else if (/turn$/.test(tok)) v = v * 360;
        return v;
    }

    function rgbString(r, g, b, a) {
        if (a === undefined || a === null || a >= 1) return 'rgb(' + r + ',' + g + ',' + b + ')';
        return 'rgba(' + r + ',' + g + ',' + b + ',' + (Math.round(a * 1000) / 1000) + ')';
    }

    function oklabToRGB(L, a, b, alpha) {
        var l_ = L + 0.3963377774 * a + 0.2158037573 * b;
        var m_ = L - 0.1055613458 * a - 0.0638541728 * b;
        var s_ = L - 0.0894841775 * a - 1.2914855480 * b;
        var l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
        var R = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
        var G = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
        var B = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
        return rgbString(to255(gamma(R)), to255(gamma(G)), to255(gamma(B)), alpha);
    }

    function labToRGB(L, a, b, alpha) {
        // CIE Lab (D50) -> XYZ -> (Bradford D50->D65) -> linear sRGB
        var fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
        var e = 216 / 24389, k = 24389 / 27;
        var xr = fx * fx * fx > e ? fx * fx * fx : (116 * fx - 16) / k;
        var yr = L > k * e ? Math.pow((L + 16) / 116, 3) : L / k;
        var zr = fz * fz * fz > e ? fz * fz * fz : (116 * fz - 16) / k;
        var X = xr * 0.96422, Y = yr * 1.0, Z = zr * 0.82521;
        var X2 = 0.9555766 * X - 0.0230393 * Y + 0.0631636 * Z;
        var Y2 = -0.0282895 * X + 1.0099416 * Y + 0.0210077 * Z;
        var Z2 = 0.0122982 * X - 0.0204830 * Y + 1.3299098 * Z;
        var R = 3.2404542 * X2 - 1.5371385 * Y2 - 0.4985314 * Z2;
        var G = -0.9692660 * X2 + 1.8760108 * Y2 + 0.0415560 * Z2;
        var B = 0.0556434 * X2 - 0.2040259 * Y2 + 1.0572252 * Z2;
        return rgbString(to255(gamma(R)), to255(gamma(G)), to255(gamma(B)), alpha);
    }

    function hslToRGB(h, s, l, alpha) {
        h = ((h % 360) + 360) % 360;
        var c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2;
        var r, g, b;
        if (h < 60) { r = c; g = x; b = 0; } else if (h < 120) { r = x; g = c; b = 0; } else if (h < 180) { r = 0; g = c; b = x; }
        else if (h < 240) { r = 0; g = x; b = c; } else if (h < 300) { r = x; g = 0; b = c; } else { r = c; g = 0; b = x; }
        return rgbString(to255(r + m), to255(g + m), to255(b + m), alpha);
    }

    // splits "a b c / d" or "a, b, c, d" into components and alpha
    function colorComponents(inner) {
        var alpha = null, main = inner;
        var slash = inner.indexOf('/');
        if (slash >= 0) { alpha = trim(inner.slice(slash + 1)); main = inner.slice(0, slash); }
        var comps;
        if (main.indexOf(',') >= 0) {
            comps = splitTop(main, ',');
            for (var i = 0; i < comps.length; i++) comps[i] = trim(comps[i]);
            if (alpha === null && comps.length === 4) alpha = comps.pop();
        } else comps = splitWS(main);
        return { c: comps, a: alpha };
    }

    // parses a colour string into [r,g,b,a] or null
    function parseColor(str) {
        str = trim(str).toLowerCase();
        if (NAMED.hasOwnProperty(str)) return NAMED[str] ? NAMED[str].slice(0) : null;
        var m = /^#([0-9a-f]{3,8})$/.exec(str);
        if (m) {
            var h = m[1];
            if (h.length === 3 || h.length === 4) {
                var r = parseInt(h.charAt(0) + h.charAt(0), 16), g = parseInt(h.charAt(1) + h.charAt(1), 16), b = parseInt(h.charAt(2) + h.charAt(2), 16);
                return [r, g, b, h.length === 4 ? parseInt(h.charAt(3) + h.charAt(3), 16) / 255 : 1];
            }
            if (h.length === 6 || h.length === 8) {
                return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1];
            }
            return null;
        }
        m = /^(rgba?|hsla?)\((.*)\)$/.exec(str);
        if (m) {
            var cc = colorComponents(m[2]);
            if (cc.c.length < 3) return null;
            var a = alphaOf(cc.a);
            if (m[1].charAt(0) === 'r') return [Math.round(numOrPct(cc.c[0], 255)), Math.round(numOrPct(cc.c[1], 255)), Math.round(numOrPct(cc.c[2], 255)), a];
            var rgb = /rgba?\((\d+),(\d+),(\d+)/.exec(hslToRGB(hueDeg(cc.c[0]), numOrPct(cc.c[1], 1), numOrPct(cc.c[2], 1), 1));
            return [+rgb[1], +rgb[2], +rgb[3], a];
        }
        return null;
    }

    function convertColorFunction(name, inner) {
        var cc, a;
        if (name === 'rgb' || name === 'rgba') {
            if (inner.indexOf(',') >= 0 && inner.indexOf('/') < 0) return null;   // legacy syntax already
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            return rgbString(Math.round(numOrPct(cc.c[0], 255)), Math.round(numOrPct(cc.c[1], 255)), Math.round(numOrPct(cc.c[2], 255)), alphaOf(cc.a));
        }
        if (name === 'hsl' || name === 'hsla') {
            if (inner.indexOf(',') >= 0 && inner.indexOf('/') < 0 && !/deg|turn|rad/.test(inner)) return null;
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            return hslToRGB(hueDeg(cc.c[0]), numOrPct(cc.c[1], 1), numOrPct(cc.c[2], 1), alphaOf(cc.a));
        }
        if (name === 'hwb') {
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            var w = numOrPct(cc.c[1], 1), bl = numOrPct(cc.c[2], 1);
            if (w + bl > 1) { var sum = w + bl; w /= sum; bl /= sum; }
            var base = /rgba?\((\d+),(\d+),(\d+)/.exec(hslToRGB(hueDeg(cc.c[0]), 1, 0.5, 1));
            var f = function (c) { return Math.round((c / 255 * (1 - w - bl) + w) * 255); };
            return rgbString(f(+base[1]), f(+base[2]), f(+base[3]), alphaOf(cc.a));
        }
        if (name === 'oklch' || name === 'oklab') {
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            var L = numOrPct(cc.c[0], 1);
            a = alphaOf(cc.a);
            if (name === 'oklab') return oklabToRGB(L, numOrPct(cc.c[1], 0.4), numOrPct(cc.c[2], 0.4), a);
            var C = numOrPct(cc.c[1], 0.4), H = hueDeg(cc.c[2]) * Math.PI / 180;
            return oklabToRGB(L, C * Math.cos(H), C * Math.sin(H), a);
        }
        if (name === 'lab' || name === 'lch') {
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            var Lc = numOrPct(cc.c[0], 100);
            a = alphaOf(cc.a);
            if (name === 'lab') return labToRGB(Lc, numOrPct(cc.c[1], 125), numOrPct(cc.c[2], 125), a);
            var Cc = numOrPct(cc.c[1], 150), Hc = hueDeg(cc.c[2]) * Math.PI / 180;
            return labToRGB(Lc, Cc * Math.cos(Hc), Cc * Math.sin(Hc), a);
        }
        if (name === 'color') {
            var toks = splitWS(inner.replace('/', ' / '));
            if (toks.length < 4) return null;
            var alphaTok = null, sl = toks.indexOf('/');
            if (sl >= 0) { alphaTok = toks[sl + 1]; toks = toks.slice(0, sl); }
            return rgbString(to255(numOrPct(toks[1], 1)), to255(numOrPct(toks[2], 1)), to255(numOrPct(toks[3], 1)), alphaOf(alphaTok));
        }
        if (name === 'color-mix') {
            var args = splitTop(inner, ',');
            if (args.length < 3) return null;
            var c1 = splitWS(trim(args[1])), c2 = splitWS(trim(args[2]));
            var p1 = null, p2 = null, s1 = [], s2 = [], i;
            for (i = 0; i < c1.length; i++) { if (/%$/.test(c1[i])) p1 = parseFloat(c1[i]) / 100; else s1.push(c1[i]); }
            for (i = 0; i < c2.length; i++) { if (/%$/.test(c2[i])) p2 = parseFloat(c2[i]) / 100; else s2.push(c2[i]); }
            var col1 = parseColor(s1.join(' ')), col2 = parseColor(s2.join(' '));
            if (!col1 || !col2) return s1.join(' ');
            if (p1 === null && p2 === null) { p1 = 0.5; p2 = 0.5; }
            else if (p1 === null) p1 = 1 - p2;
            else if (p2 === null) p2 = 1 - p1;
            var tot = p1 + p2; if (tot <= 0) tot = 1;
            p1 /= tot; p2 /= tot;
            var mix = function (k) { return Math.round(col1[k] * p1 + col2[k] * p2); };
            var alphaMix = (col1[3] === undefined ? 1 : col1[3]) * p1 + (col2[3] === undefined ? 1 : col2[3]) * p2;
            return rgbString(mix(0), mix(1), mix(2), alphaMix);
        }
        if (name === 'light-dark') {
            var ld = splitTop(inner, ',');
            return trim(ld[0]);
        }
        return null;
    }

    function fixHexAlpha(v) {
        if (v.indexOf('#') < 0) return v;
        return v.replace(/#([0-9a-fA-F]{8}|[0-9a-fA-F]{4})(?![0-9a-zA-Z_-])/g, function (all, h) {
            var c = parseColor('#' + h);
            return c ? rgbString(c[0], c[1], c[2], c[3]) : all;
        });
    }

    // ------------------------------------------------------------------ gradients

    var SIDES = { top: 'bottom', bottom: 'top', left: 'right', right: 'left' };

    function normalizeStops(stops) {
        var out = [];
        for (var i = 0; i < stops.length; i++) {
            var toks = splitWS(trim(stops[i]));
            if (!toks.length) continue;
            if (toks.length === 1 && /^-?[\d.]+(%|px|em|rem|vw|vh)?$/.test(toks[0])) continue;   // colour hint: drop
            if (toks.length === 3) { out.push(toks[0] + ' ' + toks[1]); out.push(toks[0] + ' ' + toks[2]); continue; }
            out.push(toks.join(' '));
        }
        return out;
    }

    function convertLinearGradient(inner) {
        var args = splitTop(inner, ',');
        var first = trim(args[0]);
        var rest = args.slice(1);
        var dir = null;
        if (/^to\s+/i.test(first)) {
            var words = splitWS(first).slice(1), mapped = [];
            for (var i = 0; i < words.length; i++) mapped.push(SIDES[words[i].toLowerCase()] || words[i]);
            dir = mapped.join(' ');
        } else if (/^-?[\d.]+(deg|grad|rad|turn)$/i.test(first)) {
            var ang = 90 - hueDeg(first);
            ang = ((ang % 360) + 360) % 360;
            dir = (Math.round(ang * 100) / 100) + 'deg';
        } else rest = args;
        var stops = normalizeStops(rest);
        return (dir ? dir + ', ' : '') + stops.join(', ');
    }

    function convertRadialGradient(inner) {
        var args = splitTop(inner, ',');
        var first = trim(args[0]);
        var rest = args.slice(1);
        var head = null;
        if (/\bat\b/i.test(first)) {
            var parts = first.split(/\s+at\s+/i);
            var shape = trim(parts[0]), pos = trim(parts[1] || 'center');
            head = pos + (shape ? ', ' + shape : '');
        } else if (/^(circle|ellipse|closest-|farthest-|-?[\d.]+(px|%|em|rem))/i.test(first)) {
            head = first;
        } else rest = args;
        var stops = normalizeStops(rest);
        return (head ? head + ', ' : '') + stops.join(', ');
    }

    // ------------------------------------------------------------------ values

    var ABS_UNIT = /^-?[\d.]+(px|rem|em|pt|cm|mm|in|ch|ex)$/i;

    function pickMin(args) {
        for (var i = 0; i < args.length; i++) if (ABS_UNIT.test(trim(args[i]))) return trim(args[i]);
        return trim(args[0]);
    }

    function applyFunction(name, inner) {
        switch (name) {
            case 'calc': return '-webkit-calc(' + inner + ')';
            case 'clamp': { var a = splitTop(inner, ','); return a.length === 3 ? trim(a[1]) : trim(a[0]); }
            case 'min': return pickMin(splitTop(inner, ','));
            case 'max': return trim(splitTop(inner, ',')[0]);
            case 'linear-gradient': case 'repeating-linear-gradient':
                return '-webkit-' + name + '(' + convertLinearGradient(inner) + ')';
            case 'radial-gradient': case 'repeating-radial-gradient':
                return '-webkit-' + name + '(' + convertRadialGradient(inner) + ')';
            case 'conic-gradient': case 'repeating-conic-gradient': case 'paint': case 'element': case 'cross-fade':
                return 'none';
            case 'image-set': return '-webkit-image-set(' + inner.replace(/\s*type\([^)]*\)/g, '') + ')';
            case 'fit-content': return inner;
            case 'round': case 'mod': case 'rem': case 'abs': case 'sign': case 'pow': case 'sqrt': case 'hypot':
            case 'sin': case 'cos': case 'tan': case 'asin': case 'acos': case 'atan': case 'atan2': case 'exp': case 'log':
                { var r = splitTop(inner, ','); return trim(/^(nearest|up|down|to-zero)$/.test(trim(r[0])) && r.length > 1 ? r[1] : r[0]); }
            case 'rgb': case 'rgba': case 'hsl': case 'hsla': case 'hwb': case 'oklch': case 'oklab': case 'lab': case 'lch': case 'color': case 'color-mix': case 'light-dark':
                return convertColorFunction(name, inner);
            case 'env': { var e = splitTop(inner, ','); return e.length > 1 ? trim(e[1]) : '0px'; }
        }
        return null;
    }

    // values that contain none of the functions we rewrite skip the walker entirely (url(), translate(), ... are common)
    var INTERESTING_FN = /(?:^|[^a-zA-Z0-9_-])(?:calc|clamp|min|max|linear-gradient|repeating-linear-gradient|radial-gradient|repeating-radial-gradient|conic-gradient|repeating-conic-gradient|rgb|rgba|hsl|hsla|hwb|oklch|oklab|lab|lch|color|color-mix|light-dark|env|image-set|fit-content|round|mod|rem|abs|sign|pow|sqrt|hypot|sin|cos|tan|asin|acos|atan|atan2|exp|log|paint|element|cross-fade)\(/i;

    function transformFunctions(s) {
        if (s.indexOf('(') < 0 || !INTERESTING_FN.test(s)) return s;
        var out = [], i = 0, n = s.length, start = 0;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, n); continue; }
            if (c !== 40) { i++; continue; }
            // function call: name is the identifier right before the "("
            var k = i;
            while (k > start && /[a-zA-Z0-9_-]/.test(s.charAt(k - 1))) k--;
            var name = s.slice(k, i).toLowerCase();
            var close = matchParen(s, i);
            var rawInner = s.slice(i + 1, close);
            if (name === 'url' || name === 'attr' || name === 'format' || name === 'local' || name === 'var') { i = close + 1; continue; }
            var inner = transformFunctions(rawInner);
            var replaced = name ? applyFunction(name, inner) : null;
            if (replaced !== null && replaced !== undefined) {
                out.push(s.slice(start, k), replaced);
            } else if (inner !== rawInner) {
                out.push(s.slice(start, i + 1), inner, ')');
            } else {
                i = close + 1;
                continue;
            }
            start = i = close + 1;
        }
        if (!out.length) return s;
        out.push(s.slice(start));
        return out.join('');
    }

    var INHERITED = { color: 1, cursor: 1, direction: 1, font: 1, 'font-family': 1, 'font-size': 1, 'font-style': 1, 'font-weight': 1, 'font-variant': 1,
        'letter-spacing': 1, 'line-height': 1, 'list-style': 1, 'list-style-type': 1, 'list-style-position': 1, 'list-style-image': 1, quotes: 1,
        'text-align': 1, 'text-indent': 1, 'text-transform': 1, visibility: 1, 'white-space': 1, 'word-spacing': 1, 'word-break': 1, 'word-wrap': 1,
        'overflow-wrap': 1, 'caption-side': 1, 'border-collapse': 1, 'border-spacing': 1, 'empty-cells': 1, 'tab-size': 1, hyphens: 1, 'text-shadow': 1 };

    var SIZING = { width: 1, height: 1, 'min-width': 1, 'min-height': 1, 'max-width': 1, 'max-height': 1, 'flex-basis': 1,
        'inline-size': 1, 'block-size': 1, 'min-inline-size': 1, 'max-inline-size': 1, 'min-block-size': 1, 'max-block-size': 1 };

    function fixValue(p, v) {
        if (v.indexOf('(') >= 0) v = transformFunctions(v);
        v = fixHexAlpha(v);
        if (/\d(dvh|svh|lvh|dvw|svw|lvw|cqw|cqh|cqi|cqb|cqmin|cqmax|vi|vb)\b/.test(v)) {
            v = v.replace(/(\d)(dvh|svh|lvh|cqh|cqb|vb)\b/g, '$1vh').replace(/(\d)(dvw|svw|lvw|cqw|cqi|vi)\b/g, '$1vw')
                 .replace(/(\d)cqmin\b/g, '$1vmin').replace(/(\d)cqmax\b/g, '$1vmax');
        }
        var lv = v.toLowerCase();
        if (lv === 'unset' || lv === 'revert' || lv === 'revert-layer') return INHERITED[p] ? 'inherit' : 'initial';
        if (SIZING[p]) {
            if (lv === 'fit-content') return '-webkit-fit-content';
            if (lv === 'max-content') return '-webkit-max-content';
            if (lv === 'min-content') return '-webkit-min-content';
            if (lv === 'stretch' || lv === '-moz-available') return '-webkit-fill-available';
        }
        return v;
    }

    // ------------------------------------------------------------------ declarations

    var PREFIX = { transform: 1, 'transform-origin': 1, 'transform-style': 1, transition: 1, 'transition-property': 1, 'transition-duration': 1,
        'transition-timing-function': 1, 'transition-delay': 1, animation: 1, 'animation-name': 1, 'animation-duration': 1, 'animation-timing-function': 1,
        'animation-delay': 1, 'animation-iteration-count': 1, 'animation-direction': 1, 'animation-fill-mode': 1, 'animation-play-state': 1,
        'backface-visibility': 1, perspective: 1, 'perspective-origin': 1, 'column-count': 1, 'column-gap': 1, 'column-width': 1, 'column-rule': 1,
        'column-rule-color': 1, 'column-rule-style': 1, 'column-rule-width': 1, 'column-span': 1, 'column-fill': 1, columns: 1, 'user-select': 1,
        appearance: 1, filter: 1, mask: 1, 'mask-image': 1, 'mask-size': 1, 'mask-position': 1, 'mask-repeat': 1, 'mask-composite': 1, 'mask-clip': 1,
        'mask-origin': 1, 'clip-path': 1, 'text-size-adjust': 1, 'font-feature-settings': 1, hyphens: 1, 'box-decoration-break': 1, 'font-kerning': 1,
        'writing-mode': 1, 'text-orientation': 1, 'shape-outside': 1, 'shape-margin': 1, 'text-emphasis': 1, 'text-emphasis-style': 1, 'text-emphasis-color': 1,
        'line-clamp': 1, 'box-reflect': 1, 'text-combine': 1, 'font-smoothing': 1, 'overflow-scrolling': 1, 'tap-highlight-color': 1, 'text-fill-color': 1,
        'text-stroke': 1, 'text-stroke-width': 1, 'text-stroke-color': 1, 'print-color-adjust': 1, 'background-clip': 0 };

    var PACK = { 'flex-start': 'start', start: 'start', left: 'start', 'flex-end': 'end', end: 'end', right: 'end', center: 'center',
        'space-between': 'justify', 'space-around': 'justify', 'space-evenly': 'justify', stretch: 'start', normal: 'start' };
    var ALIGN = { 'flex-start': 'start', start: 'start', 'self-start': 'start', 'flex-end': 'end', end: 'end', 'self-end': 'end', center: 'center',
        baseline: 'baseline', stretch: 'stretch', normal: 'stretch' };

    function push(out, p, v, imp) { out.push({ p: p, v: v, imp: imp }); }

    function expandBox(vals) {   // 1-4 values -> [top, right, bottom, left]
        var t = vals[0], r = vals.length > 1 ? vals[1] : t, b = vals.length > 2 ? vals[2] : t, l = vals.length > 3 ? vals[3] : r;
        return [t, r, b, l];
    }

    var LOGICAL_SINGLE = { 'margin-inline-start': 'margin-left', 'margin-inline-end': 'margin-right', 'margin-block-start': 'margin-top', 'margin-block-end': 'margin-bottom',
        'padding-inline-start': 'padding-left', 'padding-inline-end': 'padding-right', 'padding-block-start': 'padding-top', 'padding-block-end': 'padding-bottom',
        'border-inline-start': 'border-left', 'border-inline-end': 'border-right', 'border-block-start': 'border-top', 'border-block-end': 'border-bottom',
        'border-inline-start-width': 'border-left-width', 'border-inline-end-width': 'border-right-width', 'border-inline-start-color': 'border-left-color',
        'border-inline-end-color': 'border-right-color', 'border-inline-start-style': 'border-left-style', 'border-inline-end-style': 'border-right-style',
        'border-block-start-width': 'border-top-width', 'border-block-end-width': 'border-bottom-width',
        'inset-inline-start': 'left', 'inset-inline-end': 'right', 'inset-block-start': 'top', 'inset-block-end': 'bottom',
        'inline-size': 'width', 'block-size': 'height', 'min-inline-size': 'min-width', 'max-inline-size': 'max-width', 'min-block-size': 'min-height', 'max-block-size': 'max-height',
        'border-start-start-radius': 'border-top-left-radius', 'border-start-end-radius': 'border-top-right-radius',
        'border-end-start-radius': 'border-bottom-left-radius', 'border-end-end-radius': 'border-bottom-right-radius',
        'overflow-inline': 'overflow-x', 'overflow-block': 'overflow-y' };
    var LOGICAL_PAIR = { 'margin-inline': ['margin-left', 'margin-right'], 'margin-block': ['margin-top', 'margin-bottom'],
        'padding-inline': ['padding-left', 'padding-right'], 'padding-block': ['padding-top', 'padding-bottom'],
        'border-inline': ['border-left', 'border-right'], 'border-block': ['border-top', 'border-bottom'],
        'border-inline-width': ['border-left-width', 'border-right-width'], 'border-block-width': ['border-top-width', 'border-bottom-width'],
        'border-inline-color': ['border-left-color', 'border-right-color'], 'border-inline-style': ['border-left-style', 'border-right-style'],
        'inset-inline': ['left', 'right'], 'inset-block': ['top', 'bottom'], 'scroll-margin-inline': ['scroll-margin-left', 'scroll-margin-right'] };

    function parseFlexShorthand(v) {   // returns {grow, basis}
        var lv = v.toLowerCase();
        if (lv === 'none') return { grow: '0', basis: null };
        if (lv === 'auto') return { grow: '1', basis: null };
        if (lv === 'initial') return { grow: '0', basis: null };
        var toks = splitWS(v), grow = null, basis = null;
        for (var i = 0; i < toks.length; i++) {
            var t = toks[i];
            if (/^-?[\d.]+$/.test(t)) { if (grow === null) grow = t; }
            else if (t !== 'auto' && t !== 'content') basis = t;
        }
        return { grow: grow === null ? '1' : grow, basis: basis };
    }

    function fixDeclarations(decls, ctx, keyframe) {
        var local = null, i, d;
        var wrap = false, hasTransform = false, translate = null, rotate = null, scale = null, lastImp = false;
        for (i = 0; i < decls.length; i++) {
            d = decls[i];
            if (d.p.charAt(0) === '-' && d.p.charAt(1) === '-') { if (!local) local = {}; local[d.p] = d.v; }
            else if ((d.p === 'flex-wrap' || d.p === 'flex-flow') && /wrap/i.test(d.v) && !/nowrap/i.test(d.v)) wrap = true;
        }
        var out = [];
        for (i = 0; i < decls.length; i++) {
            d = decls[i];
            var p = d.p, imp = d.imp;
            if (p.charAt(0) === '-' && p.charAt(1) === '-') continue;
            var v = resolveVars(d.v, local, ctx);
            if (v === null) continue;
            v = fixValue(p, v);
            var lv = v.toLowerCase();
            switch (p) {
                case 'display':
                    if (lv === 'flex') push(out, 'display', wrap ? 'block' : '-webkit-box', imp);
                    else if (lv === 'inline-flex') push(out, 'display', wrap ? 'inline-block' : '-webkit-inline-box', imp);
                    else if (lv === 'grid' || lv === 'flow-root' || lv === 'contents') push(out, 'display', 'block', imp);
                    else if (lv === 'inline-grid') push(out, 'display', 'inline-block', imp);
                    else push(out, 'display', v, imp);
                    continue;
                case 'flex-direction':
                    push(out, '-webkit-box-orient', /column/.test(lv) ? 'vertical' : 'horizontal', imp);
                    push(out, '-webkit-box-direction', /reverse/.test(lv) ? 'reverse' : 'normal', imp);
                    push(out, p, v, imp);
                    continue;
                case 'flex-flow':
                    if (/column|row/.test(lv)) {
                        push(out, '-webkit-box-orient', /column/.test(lv) ? 'vertical' : 'horizontal', imp);
                        push(out, '-webkit-box-direction', /reverse/.test(lv) ? 'reverse' : 'normal', imp);
                    }
                    push(out, p, v, imp);
                    continue;
                case 'flex-wrap':
                    push(out, '-webkit-box-lines', /^wrap/.test(lv) ? 'multiple' : 'single', imp);
                    push(out, p, v, imp);
                    continue;
                case 'justify-content':
                    if (PACK[lv]) push(out, '-webkit-box-pack', PACK[lv], imp);
                    push(out, p, v, imp);
                    continue;
                case 'align-items':
                    if (ALIGN[lv]) push(out, '-webkit-box-align', ALIGN[lv], imp);
                    push(out, p, v, imp);
                    continue;
                case 'place-items': {
                    var pi = splitWS(lv);
                    if (ALIGN[pi[0]]) push(out, '-webkit-box-align', ALIGN[pi[0]], imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'place-content': {
                    var pc = splitWS(lv), jc = pc.length > 1 ? pc[1] : pc[0];
                    if (PACK[jc]) push(out, '-webkit-box-pack', PACK[jc], imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'flex': {
                    var f = parseFlexShorthand(v);
                    push(out, '-webkit-box-flex', f.grow, imp);
                    if (f.basis && f.basis !== '0' && f.basis !== '0px' && f.basis !== '0%') push(out, 'width', f.basis, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'flex-grow':
                    push(out, '-webkit-box-flex', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'flex-basis':
                    if (lv !== 'auto' && lv !== 'content' && lv !== '0' && lv !== '0px') push(out, 'width', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'order': {
                    var o = parseInt(v, 10);
                    push(out, '-webkit-box-ordinal-group', String(isNaN(o) ? 1 : Math.max(1, o + 1)), imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'inset': {
                    var ib = expandBox(splitWS(v));
                    push(out, 'top', ib[0], imp); push(out, 'right', ib[1], imp); push(out, 'bottom', ib[2], imp); push(out, 'left', ib[3], imp);
                    continue;
                }
                case 'text-align':
                    push(out, p, lv === 'start' ? 'left' : lv === 'end' ? 'right' : v, imp);
                    continue;
                case 'overflow': case 'overflow-x': case 'overflow-y':
                    push(out, p, lv === 'overlay' ? 'auto' : lv === 'clip' ? 'hidden' : v, imp);
                    continue;
                case 'translate': translate = v; continue;
                case 'rotate': rotate = v; continue;
                case 'scale': scale = v; continue;
                case 'transform':
                    hasTransform = true;
                    push(out, '-webkit-transform', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'transition': case 'transition-property': {
                    var tv = v.replace(/(^|[\s,])(transform|filter|mask|clip-path|backdrop-filter)\b/g, '$1-webkit-$2');
                    push(out, '-webkit-' + p, tv, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'background-clip': case '-webkit-background-clip':
                    if (lv === 'text') push(out, '-webkit-background-clip', 'text', imp);
                    push(out, p, v, imp);
                    continue;
                case 'break-inside': case 'page-break-inside':
                    if (lv === 'avoid' || lv === 'avoid-column') push(out, '-webkit-column-break-inside', 'avoid', imp);
                    push(out, p, v, imp);
                    continue;
                case 'position':
                    push(out, p, v, imp);
                    continue;
                case 'font':
                    push(out, p, v.replace(/\b(system-ui|-apple-system)\b/g, 'Helvetica Neue'), imp);
                    continue;
                case 'font-family':
                    push(out, p, v.replace(/\b(system-ui|-apple-system|BlinkMacSystemFont|ui-sans-serif|ui-serif|ui-monospace)\b/g, function (m) {
                        return m === 'ui-serif' ? 'Georgia' : m === 'ui-monospace' ? 'Courier' : '"Helvetica Neue"';
                    }), imp);
                    continue;
            }
            if (LOGICAL_SINGLE[p]) { push(out, LOGICAL_SINGLE[p], v, imp); continue; }
            if (LOGICAL_PAIR[p]) {
                var pair = LOGICAL_PAIR[p], pv = splitWS(v);
                push(out, pair[0], pv[0], imp);
                push(out, pair[1], pv.length > 1 ? pv[1] : pv[0], imp);
                continue;
            }
            if (PREFIX[p]) {
                push(out, '-webkit-' + p, v, imp);
                push(out, p, v, imp);
                continue;
            }
            push(out, p, v, imp);
            lastImp = imp;
        }
        if ((translate || rotate || scale) && !hasTransform) {
            var parts = [];
            if (translate && translate !== 'none') { var tt = splitWS(translate); parts.push(tt.length > 1 ? 'translate(' + tt[0] + ', ' + tt[1] + ')' : 'translate(' + tt[0] + ')'); }
            if (rotate && rotate !== 'none') parts.push('rotate(' + rotate + ')');
            if (scale && scale !== 'none') { var st = splitWS(scale); parts.push(st.length > 1 ? 'scale(' + st[0] + ', ' + st[1] + ')' : 'scale(' + st[0] + ')'); }
            if (parts.length) { push(out, '-webkit-transform', parts.join(' '), false); push(out, 'transform', parts.join(' '), false); }
        }
        return out;
    }

    // ------------------------------------------------------------------ selectors

    var DROP_SELECTOR = /:has\(|::part\(|::slotted\(|:host|:state\(|:popover-open|::backdrop|:modal|::marker|::file-selector-button|::cue|::view-transition|:placeholder-shown|:focus-within|:dir\(|:read-write|:read-only|:user-invalid|:user-valid|:autofill|:target-within|:fullscreen|:picture-in-picture|:paused|:playing|:defined|:current|:past|:future|:local-link|::highlight|::spelling-error|::grammar-error|::target-text|:xr-overlay|:open|:closed|:muted|:volume-locked|>>>|\/deep\/|^\s*&|\s&|&\s|:nth-child\([^)]*\bof\b/i;

    function isCompound(sel) {   // no combinators at depth 0
        var depth = 0;
        for (var i = 0; i < sel.length; i++) {
            var c = sel.charAt(i);
            if (c === '"' || c === "'") { i = skipString(sel, i, sel.length) - 1; continue; }
            if (c === '(' || c === '[') depth++;
            else if (c === ')' || c === ']') depth--;
            else if (depth === 0 && (c === ' ' || c === '>' || c === '+' || c === '~')) return false;
        }
        return true;
    }

    // number of simple selectors in a compound (e.g. ".a.b" -> 2, "div" -> 1)
    function simpleCount(sel) {
        var count = 0, depth = 0, i = 0, n = sel.length;
        while (i < n) {
            var c = sel.charAt(i);
            if (c === '"' || c === "'") { i = skipString(sel, i, n); continue; }
            if (c === '\\') { i += 2; continue; }
            if (c === '(' || c === '[') { depth++; if (c === '[') count++; }
            else if (c === ')' || c === ']') depth--;
            else if (depth === 0 && (c === '.' || c === '#' || c === ':')) { if (c !== ':' || sel.charAt(i - 1) !== ':') count++; }
            else if (depth === 0 && i === 0 && /[a-zA-Z*]/.test(c)) count++;
            i++;
        }
        return count;
    }

    // splits "a b > c" into [prefix, lastCompound] at the last top-level combinator
    function splitLastCompound(sel) {
        var depth = 0, cut = -1, n = sel.length;
        for (var i = 0; i < n; i++) {
            var c = sel.charAt(i);
            if (c === '"' || c === "'") { i = skipString(sel, i, n) - 1; continue; }
            if (c === '(' || c === '[') depth++;
            else if (c === ')' || c === ']') depth--;
            else if (depth === 0 && (c === ' ' || c === '>' || c === '+' || c === '~')) cut = i;
        }
        if (cut < 0) return ['', sel];
        return [sel.slice(0, cut + 1), sel.slice(cut + 1)];
    }

    // the compound selector text immediately before position `at` (so it can be merged)
    function compoundBefore(sel, at) {
        var depth = 0, i = at - 1;
        while (i >= 0) {
            var c = sel.charAt(i);
            if (c === ')' || c === ']') depth++;
            else if (c === '(' || c === '[') depth--;
            else if (depth === 0 && (c === ' ' || c === '>' || c === '+' || c === '~' || c === ',')) break;
            i--;
        }
        return sel.slice(i + 1, at);
    }

    function mergeCompound(outer, inner) {
        // a type selector must come first
        var innerTag = /^[a-zA-Z*][a-zA-Z0-9_-]*/.exec(inner), outerTag = /^[a-zA-Z*][a-zA-Z0-9_-]*/.exec(outer);
        if (innerTag && outerTag) return null;
        if (innerTag) return innerTag[0] + outer + inner.slice(innerTag[0].length);
        return outer + inner;
    }

    function expandIs(sel, budget) {
        var m = /:(?:is|where|matches|-moz-any)\(/i.exec(sel);
        if (!m) return [sel];
        var open = m.index + m[0].length - 1;
        var close = matchParen(sel, open);
        var inner = sel.slice(open + 1, close);
        var items = splitTop(inner, ','), i;
        var allCompound = true;
        for (i = 0; i < items.length; i++) { items[i] = trim(items[i]); if (!isCompound(items[i])) allCompound = false; }
        var before = sel.slice(0, m.index), after = sel.slice(close + 1);
        var results = [];
        if (allCompound && items.length > 1) {
            results.push(before + ':-webkit-any(' + items.join(',') + ')' + after);
        } else {
            for (i = 0; i < items.length; i++) {
                var item = items[i];
                if (!item) continue;
                if (isCompound(item)) { results.push(before + (item.charAt(0) === '*' && before ? item.slice(1) : item) + after); continue; }
                var sp = splitLastCompound(item);
                var outerCompound = compoundBefore(before, before.length);
                var merged = outerCompound ? mergeCompound(outerCompound, sp[1]) : sp[1];
                if (merged === null) continue;
                results.push(before.slice(0, before.length - outerCompound.length) + sp[0] + merged + after);
            }
        }
        var expanded = [];
        for (i = 0; i < results.length; i++) {
            if (expanded.length > budget) break;
            var sub = expandIs(results[i], budget);
            for (var k = 0; k < sub.length; k++) expanded.push(sub[k]);
        }
        return expanded;
    }

    function fixNot(sel) {
        var out = '', i = 0, n = sel.length;
        while (i < n) {
            var idx = sel.indexOf(':not(', i);
            if (idx < 0) { out += sel.slice(i); break; }
            var close = matchParen(sel, idx + 4);
            var inner = sel.slice(idx + 5, close);
            var items = splitTop(inner, ','), parts = [];
            for (var k = 0; k < items.length; k++) {
                var it = trim(items[k]);
                if (!it) continue;
                if (!isCompound(it) || simpleCount(it) > 1) return null;   // level 3 :not() takes one simple selector
                parts.push(':not(' + it + ')');
            }
            out += sel.slice(i, idx) + parts.join('');
            i = close + 1;
        }
        return out;
    }

    function fixSelector(sel) {
        sel = trim(sel);
        if (!sel || DROP_SELECTOR.test(sel)) return [];
        sel = sel.replace(/:focus-visible/gi, ':focus')
                 .replace(/::?placeholder\b/gi, '::-webkit-input-placeholder')
                 .replace(/:any-link/gi, ':link')
                 .replace(/:scope\b/gi, ':root')
                 .replace(/(\[[^\]]*?)\s+[isIS]\s*\]/g, '$1]')
                 .replace(/:lang\(([^,)]*),[^)]*\)/gi, ':lang($1)');
        var list = /:(is|where|matches|-moz-any)\(/i.test(sel) ? expandIs(sel, 48) : [sel];
        var out = [];
        for (var i = 0; i < list.length && out.length < 64; i++) {
            var s = list[i];
            if (s.indexOf(':not(') >= 0) { s = fixNot(s); if (s === null) continue; }
            s = trim(s.replace(/\s+/g, ' '));
            if (s) out.push(s);
        }
        return out;
    }

    function fixSelectorList(sel) {
        var parts = splitTop(sel, ','), out = [];
        for (var i = 0; i < parts.length; i++) {
            var fixed = fixSelector(parts[i]);
            for (var k = 0; k < fixed.length; k++) out.push(fixed[k]);
        }
        return out;
    }

    // ------------------------------------------------------------------ at-rules

    function fixMedia(q) {
        q = q.replace(/\(\s*(-?[\d.]+(?:px|em|rem))\s*(<=|<)\s*(width|height)\s*(<=|<)\s*(-?[\d.]+(?:px|em|rem))\s*\)/gi, '(min-$3: $1) and (max-$3: $5)')
             .replace(/\(\s*(width|height)\s*(>=|>)\s*([^)]+?)\s*\)/gi, '(min-$1: $3)')
             .replace(/\(\s*(width|height)\s*(<=|<)\s*([^)]+?)\s*\)/gi, '(max-$1: $3)')
             .replace(/\(\s*([^)]+?)\s*(<=|<)\s*(width|height)\s*\)/gi, '(min-$3: $1)')
             .replace(/\(\s*([^)]+?)\s*(>=|>)\s*(width|height)\s*\)/gi, '(max-$3: $1)')
             .replace(/\(\s*(min-|max-)?resolution\s*:\s*([\d.]+)\s*(dppx|x)\s*\)/gi, function (m, mm, n) { return '(-webkit-' + (mm || '') + 'device-pixel-ratio: ' + n + ')'; })
             .replace(/\(\s*(min-|max-)?resolution\s*:\s*([\d.]+)\s*dpi\s*\)/gi, function (m, mm, n) { return '(-webkit-' + (mm || '') + 'device-pixel-ratio: ' + (Math.round(n / 96 * 100) / 100) + ')'; })
             .replace(/\(\s*(?:any-)?hover\s*:\s*none\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*(?:any-)?hover\s*:\s*hover\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*(?:any-)?pointer\s*:\s*(fine|none)\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*prefers-reduced-motion\s*:\s*no-preference\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*prefers-reduced-motion\s*(?::\s*reduce\s*)?\)/gi, '(max-width: 0px)')
             .replace(/\(\s*prefers-color-scheme\s*:\s*light\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*prefers-color-scheme\s*:\s*dark\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*prefers-contrast\s*:\s*no-preference\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*prefers-contrast\s*:\s*[a-z]+\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*prefers-reduced-transparency\s*[^)]*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*forced-colors\s*:\s*none\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*forced-colors\s*:\s*active\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*display-mode\s*:\s*browser\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*display-mode\s*:\s*[a-z-]+\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*scripting\s*:\s*enabled\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*scripting\s*:\s*[a-z-]+\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*update\s*:\s*fast\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*dynamic-range\s*:\s*standard\s*\)/gi, '(min-width: 0px)')
             .replace(/\(\s*dynamic-range\s*:\s*high\s*\)/gi, '(max-width: 0px)')
             .replace(/\(\s*(min-|max-)?aspect-ratio\s*:\s*([\d.]+)\s*\/\s*([\d.]+)\s*\)/gi, '($1aspect-ratio: $2/$3)');
        // "@media screen and (max-width: 100px), ..." is fine; old WebKit also needs "and" lower case
        return q.replace(/\bAND\b/g, 'and');
    }

    var SUPPORTED_PROPS = { display: /^(block|inline|inline-block|none|flex|inline-flex|-webkit-box|-webkit-flex|table|table-cell|table-row|list-item|inline-table|-webkit-inline-box)$/i,
        position: /^(static|relative|absolute|fixed)$/i, transform: 1, '-webkit-transform': 1, transition: 1, animation: 1, filter: 1, '-webkit-filter': 1,
        mask: 1, '-webkit-mask': 1, 'clip-path': 1, '-webkit-clip-path': 1, columns: 1, 'column-count': 1, 'box-shadow': 1, 'border-radius': 1, opacity: 1,
        'background-size': 1, 'background-clip': 1, 'box-sizing': 1, 'text-overflow': 1, 'word-break': 1, 'overflow-wrap': 1, 'pointer-events': 1,
        calc: 1, width: /calc|vw|vh|vmin|px|%|em|rem|fit-content|max-content|min-content/i, height: /calc|vw|vh|vmin|px|%|em|rem/i,
        'font-feature-settings': 1, 'user-select': 1, appearance: 1, '-webkit-appearance': 1, color: 1, 'background-color': 1, 'background-image': 1, background: 1, inset: 1,
        'margin-inline': 1, 'padding-inline': 1, 'flex-direction': 1, 'justify-content': 1, 'align-items': 1, 'flex-wrap': 0, 'flex-grow': 1, 'flex-basis': 1, flex: 1, order: 1 };

    function supportsDeclaration(decl) {
        var colon = decl.indexOf(':');
        if (colon < 0) return false;
        var p = trim(decl.slice(0, colon)).toLowerCase(), v = trim(decl.slice(colon + 1));
        if (p.charAt(0) === '-' && p.charAt(1) === '-') return true;   // custom properties: resolved statically
        if (p.indexOf('grid') >= 0 || p === 'gap' || p === 'row-gap' || p === 'column-gap' && !/column/.test(v) || p === 'aspect-ratio' || p === 'object-fit' ||
            p === 'position' && /sticky/i.test(v) || p === 'backdrop-filter' || p === '-webkit-backdrop-filter' || p === 'container-type' || p === 'container' ||
            p === 'overflow' && /clip/i.test(v) || p === 'display' && /grid|contents|flow-root/i.test(v) || p === 'scroll-snap-type' || p === 'scroll-behavior' ||
            p === 'writing-mode' || p === 'text-wrap' || p === 'anchor-name' || p === 'view-transition-name' || p === 'contain' || p === 'content-visibility' ||
            p === 'accent-color' || p === 'color-scheme' || p === 'field-sizing' || p === 'text-box-trim' || p === 'animation-timeline') return false;
        if (/oklch|oklab|lab\(|lch\(|color-mix|light-dark|hwb\(/i.test(v)) return true;   // converted statically
        if (/conic-gradient|paint\(|anchor\(|round\(|mod\(|rem\(|sin\(|cos\(/i.test(v)) return false;
        if (/^(min|max|clamp)\(/i.test(v)) return true;   // approximated
        var s = SUPPORTED_PROPS[p];
        if (s === undefined) return false;
        if (s === 1) return true;
        if (s === 0) return false;
        return s.test(v);
    }

    function evalSupports(cond) {
        cond = trim(cond);
        if (!cond) return false;
        // strip one level of outer parens when they wrap the whole condition
        while (cond.charAt(0) === '(' && matchParen(cond, 0) === cond.length - 1) cond = trim(cond.slice(1, -1));
        if (/^not\s/i.test(cond)) return !evalSupports(cond.slice(4));
        // split by top level " and " / " or "
        var terms = [], ops = [], i = 0, n = cond.length, depth = 0, start = 0;
        while (i < n) {
            var c = cond.charAt(i);
            if (c === '"' || c === "'") { i = skipString(cond, i, n); continue; }
            if (c === '(') depth++;
            else if (c === ')') depth--;
            else if (depth === 0) {
                var m = /^\s+(and|or)\s+/i.exec(cond.slice(i));
                if (m) { terms.push(cond.slice(start, i)); ops.push(m[1].toLowerCase()); i += m[0].length; start = i; continue; }
            }
            i++;
        }
        terms.push(cond.slice(start));
        if (terms.length === 1) {
            var t = trim(terms[0]);
            if (/^selector\(/i.test(t)) return !/:has\(|:is\(|:where\(|:focus-visible|::part|:host|::slotted|:nth-child\([^)]*of/i.test(t);
            if (/^font-tech\(|^font-format\(/i.test(t)) return false;
            if (t.charAt(0) === '(') return evalSupports(t);
            if (/^not\s/i.test(t)) return !evalSupports(t.slice(4));
            return supportsDeclaration(t);
        }
        var result = evalSupports(terms[0]);
        for (i = 0; i < ops.length; i++) {
            var r = evalSupports(terms[i + 1]);
            result = ops[i] === 'and' ? (result && r) : (result || r);
        }
        return result;
    }

    // ------------------------------------------------------------------ rule transformation

    function transformRules(rules, ctx, keyframe) {
        var out = [];
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.t === 'q') {
                var sels = keyframe ? [r.sel] : fixSelectorList(r.sel);
                if (!sels.length) continue;
                var decls = fixDeclarations(r.decls, ctx, keyframe);
                if (!decls.length) continue;
                out.push({ t: 'q', sel: sels.join(','), decls: decls });
                continue;
            }
            if (r.t !== 'at') continue;
            var name = r.name, k, sub;
            if (name === 'media') {
                if (!r.rules) continue;
                sub = transformRules(r.rules, ctx, keyframe);
                if (sub.length) out.push({ t: 'at', name: 'media', prelude: fixMedia(r.prelude), rules: sub, decls: null, raw: null });
            } else if (name === 'supports') {
                if (r.rules && evalSupports(r.prelude)) {
                    sub = transformRules(r.rules, ctx, keyframe);
                    for (k = 0; k < sub.length; k++) out.push(sub[k]);
                }
            } else if (name === 'layer' || name === 'scope') {
                if (r.rules) {
                    sub = transformRules(r.rules, ctx, keyframe);
                    for (k = 0; k < sub.length; k++) out.push(sub[k]);
                }
            } else if (name === 'keyframes' || name === '-webkit-keyframes') {
                if (!r.rules) continue;
                sub = transformRules(r.rules, ctx, true);
                out.push({ t: 'at', name: '-webkit-keyframes', prelude: r.prelude, rules: sub, decls: null, raw: null });
            } else if (name === 'font-face') {
                var fd = fixDeclarations(r.decls || [], ctx, false);
                for (k = 0; k < fd.length; k++) {
                    if (fd[k].p === 'src') {
                        // WOFF2 files are converted to TrueType by the network layer, so tell the engine to try them
                        fd[k].v = fd[k].v.replace(/format\(\s*(["']?)woff2(?:-variations)?\1\s*\)/gi, 'format("truetype")')
                                         .replace(/\s*tech\([^)]*\)/gi, '');
                    }
                }
                out.push({ t: 'at', name: name, prelude: r.prelude, rules: null, decls: fd, raw: null });
            } else if (name === 'page') {
                out.push({ t: 'at', name: name, prelude: r.prelude, rules: null, decls: r.decls || [], raw: null });
            } else if (name === 'import') {
                var pre = r.prelude.replace(/\s+layer(\([^)]*\))?/i, '').replace(/\s+supports\([^)]*\)/i, '');
                out.push({ t: 'at', name: name, prelude: pre, rules: null, decls: null, raw: null });
            } else if (name === 'charset' || name === 'namespace') {
                out.push({ t: 'at', name: name, prelude: r.prelude, rules: null, decls: null, raw: null });
            }
            // container, property, counter-style, document, starting-style, font-feature-values and unknown ones are dropped
        }
        return out;
    }

    function makeContext(pageVars) {
        var page = {};
        if (pageVars) {
            if (typeof pageVars === 'string') { try { pageVars = JSON.parse(pageVars); } catch (e) { pageVars = null; } }
            if (pageVars && typeof pageVars === 'object') for (var k in pageVars) if (pageVars.hasOwnProperty(k)) page[k] = pageVars[k];
        }
        return { page: page, root: {}, other: {} };
    }

    function fixCSS(text, ctx) {
        var clean = stripComments(text);
        var rules = [];
        parseRules(clean, 0, clean.length, rules);
        collectVars(rules, ctx, false);
        return serializeRules(transformRules(rules, ctx, false));
    }

    function fixInlineStyle(text, ctx) {
        var decls = parseDecls(stripComments(text));
        return serializeDecls(fixDeclarations(decls, ctx, false));
    }

    // ------------------------------------------------------------------ scripts inside HTML

    var scriptCache = {}, scriptCacheSize = 0;   // hash -> transpiled inline script

    function hashString(s) {
        var h = 2166136261, i = 0, n = s.length;
        for (; i < n; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
        return h.toString(36) + ':' + n;
    }

    function isJavaScriptType(type) {
        if (!type) return true;
        type = trim(type).toLowerCase();
        return type === '' || type === 'text/javascript' || type === 'application/javascript' || type === 'text/ecmascript' ||
               type === 'application/ecmascript' || type === 'text/jscript' || type === 'application/x-javascript' || type === 'module';
    }

    function transpileInline(code, moduleId) {
        if (typeof BRTranspile === 'undefined' || !code || !/[^\s]/.test(code) || code.length > 32768) return null;
        var key = hashString(code) + (moduleId ? '|' + moduleId : '');
        if (scriptCache.hasOwnProperty(key)) return scriptCache[key];
        var out = null;
        try { out = moduleId ? BRTranspile.transpileModule(code, moduleId) : BRTranspile.run(code, 'inline.js'); } catch (e) { out = null; }
        if (out === '') out = null;   // already ES5
        if (scriptCacheSize > 2000000) { scriptCache = {}; scriptCacheSize = 0; }
        scriptCache[key] = out;
        scriptCacheSize += (out || '').length;
        return out;
    }

    function attrValue(attrs, name) {
        var m = new RegExp('\\b' + name + '\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i').exec(attrs);
        if (!m) return null;
        return m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4];
    }

    function jsString(s) {
        return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/<\//g, '<\\/').replace(/\n/g, '\\n') + '"';
    }

    function fixScripts(html, opts) {
        var re = /(<script\b([^>]*)>)([\s\S]*?)(<\/script\s*>)/gi;
        var pageBase = '';
        if (opts && opts.pageURL) {
            pageBase = String(opts.pageURL).replace(/[#?].*$/, '');
            pageBase = pageBase.slice(0, pageBase.lastIndexOf('/') + 1);
        }
        var inlineCount = 0, modulesConverted = false;
        html = html.replace(re, function (all, open, attrs, body, close) {
            var type = attrValue(attrs, 'type') || '';
            var ltype = trim(type).toLowerCase();
            if (ltype === 'importmap') return open.replace(/\btype\s*=\s*("importmap"|'importmap'|importmap)/i, 'type="systemjs-importmap"') + body + close;
            if (!isJavaScriptType(type)) return all;
            if (!opts || !opts.transpile) return all;
            var src = attrValue(attrs, 'src');
            if (ltype === 'module') {
                // ES modules are not run by the old engine at all: hand them to SystemJS
                var cleanAttrs = attrs.replace(/\s*\btype\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, '')
                                      .replace(/\s*\b(src|crossorigin|integrity|defer|async|nomodule|referrerpolicy|fetchpriority)\b(\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?/gi, '');
                if (src) {
                    modulesConverted = true;
                    return '<script' + cleanAttrs + '>System.import(' + jsString(src) + ').catch(function(e){console.error(e)});' + close;
                }
                if (!/[^\s]/.test(body)) return '';
                var moduleId = pageBase + '__inline_module_' + (++inlineCount) + '.js';
                var fixedModule = transpileInline(body, moduleId);
                if (fixedModule === null) return all;
                modulesConverted = true;
                return '<script' + cleanAttrs + '>' + fixedModule + '\nSystem.import(' + jsString(moduleId) + ').catch(function(e){console.error(e)});' + close;
            }
            if (src) return all;                                        // external scripts are transpiled by the network layer
            var fixed = transpileInline(body, null);
            if (fixed === null) return all;
            return open + fixed + close;
        });
        // nomodule fallbacks would run in addition to the converted modules
        if (modulesConverted) html = html.replace(/<script\b[^>]*\bnomodule\b[^>]*>[\s\S]*?<\/script\s*>/gi, '');
        return html;
    }

    function injectPolyfills(html, url) {
        if (!url || html.indexOf(url) >= 0) return html;
        if (!/<html|<head|<body/i.test(html)) return html;               // fragments
        var tag = '<script src="' + url + '"></script>';
        var m = /<head\b[^>]*>/i.exec(html);
        if (m) return html.slice(0, m.index + m[0].length) + tag + html.slice(m.index + m[0].length);
        m = /<html\b[^>]*>/i.exec(html);
        if (m) return html.slice(0, m.index + m[0].length) + tag + html.slice(m.index + m[0].length);
        m = /<(script|link|style|body)\b/i.exec(html);
        if (m) return html.slice(0, m.index) + tag + html.slice(m.index);
        return tag + html;
    }

    function fixHTML(html, ctx, opts) {
        var styleRe = /(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>)/gi;
        // 1. collect variables from every <style> block first (they usually hold the theme)
        var m;
        while ((m = styleRe.exec(html)) !== null) {
            var clean = stripComments(m[2]);
            var rules = [];
            parseRules(clean, 0, clean.length, rules);
            collectVars(rules, ctx, false);
        }
        // 2. rewrite the blocks
        html = html.replace(styleRe, function (all, open, body, close) {
            if (!trim(body)) return all;
            return open + fixCSS(body, ctx) + close;
        });
        // 3. inline style attributes
        html = html.replace(/(\sstyle\s*=\s*)("([^"]*)"|'([^']*)')/gi, function (all, prefix, quoted, dq, sq) {
            var css = dq !== undefined ? dq : sq;
            if (!css || (css.indexOf('(') < 0 && css.indexOf('var') < 0 && css.indexOf('flex') < 0 && css.indexOf('transform') < 0 && css.indexOf('inset') < 0 && css.indexOf('#') < 0)) return all;
            var fixed = fixInlineStyle(css.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&'), ctx);
            fixed = fixed.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
            return prefix + '"' + fixed + '"';
        });
        // 4. scripts: inline ones transpiled, polyfill bundle injected first thing in <head>
        html = fixScripts(html, opts);
        if (opts && opts.polyfillURL) html = injectPolyfills(html, opts.polyfillURL);
        return html;
    }

    function run(kind, text, pageVars, options) {
        var ctx = makeContext(pageVars);
        var opts = null;
        if (options) {
            if (typeof options === 'string') { try { opts = JSON.parse(options); } catch (e) { opts = null; } }
            else opts = options;
        }
        var out = kind === 'html' ? fixHTML(text, ctx, opts) : fixCSS(text, ctx);
        return JSON.stringify({ out: out, vars: ctx.root });
    }

    return { run: run, fixCSS: fixCSS, fixHTML: fixHTML, fixInlineStyle: fixInlineStyle, makeContext: makeContext, evalSupports: evalSupports,
             fixSelectorList: fixSelectorList, fixMedia: fixMedia, transformFunctions: transformFunctions, parseColor: parseColor };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = CSSFix;
