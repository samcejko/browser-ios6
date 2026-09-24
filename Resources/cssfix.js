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

    // Declarations of a block. With `nestedOut`, nested rules (CSS nesting: "&:hover{}", ".b{}", "@media{}")
    // are collected into it as {t:'q', sel, decls, nested} / {t:'at', name, prelude, decls, nested}; without
    // it they are skipped (descriptor blocks, inline styles).
    function parseDecls(str, nestedOut) {
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
            else if (depth === 0 && c === 123) {          // nested rule
                var e = findBlockEnd(str, i, n);
                if (e < 0) e = n;
                if (nestedOut) {
                    var head = trim(str.slice(start, i)), sub = [];
                    if (head) {
                        var inner = str.slice(i + 1, e);
                        if (head.charAt(0) === '@') {
                            var an = atName(head);
                            nestedOut.push({ t: 'at', name: an, prelude: trim(head.slice(an.length + 1)), decls: parseDecls(inner, sub), nested: sub });
                        } else nestedOut.push({ t: 'q', sel: head, decls: parseDecls(inner, sub), nested: sub });
                    }
                }
                start = e + 1;
                i = start;
                continue;
            } else if (depth === 0 && c === 59) { flush(i); start = i + 1; }
            i++;
        }
        flush(n);
        return decls;
    }

    // ---- CSS nesting: nested rules become plain descendant rules, nested conditional at-rules are hoisted
    var NESTED_AT = { media: 1, supports: 1, container: 1, layer: 1, scope: 1, 'starting-style': 1 };

    function replaceNestingSelector(sel, parent) {   // every "&" outside strings and brackets -> parent
        var out = '', i = 0, n = sel.length, depth = 0;
        while (i < n) {
            var c = sel.charCodeAt(i);
            if (c === 34 || c === 39) { var e = skipString(sel, i, n); out += sel.slice(i, e); i = e; continue; }
            if (c === 91) depth++; else if (c === 93) { if (depth > 0) depth--; }
            if (c === 38 && depth === 0) out += parent; else out += sel.charAt(i);
            i++;
        }
        return out;
    }

    function nestedSelectors(parentSels, childSel) {
        var parts = splitTop(childSel, ','), out = [];
        for (var i = 0; i < parts.length && out.length < 64; i++) {
            var c = trim(parts[i].replace(/\s+/g, ' '));
            if (!c) continue;
            for (var k = 0; k < parentSels.length && out.length < 64; k++) {
                if (c.indexOf('&') >= 0) out.push(replaceNestingSelector(c, parentSels[k]));
                else out.push(parentSels[k] + ' ' + c);   // relative selectors (".b", "> .b", "+ .b") are descendants of the parent
            }
        }
        return out;
    }

    function emitNested(nested, parentSels, out, depth) {
        if (depth > 12) return;
        for (var i = 0; i < nested.length; i++) {
            var n = nested[i];
            if (n.t === 'q' || n.name === 'nest') {
                var sels = nestedSelectors(parentSels, n.t === 'q' ? n.sel : n.prelude);
                if (!sels.length) continue;
                out.push({ t: 'q', sel: sels.join(','), decls: n.decls });
                if (n.nested.length) emitNested(n.nested, sels, out, depth + 1);
            } else if (NESTED_AT[n.name]) {
                var inner = [];
                if (n.decls.length) inner.push({ t: 'q', sel: parentSels.join(','), decls: n.decls });
                if (n.nested.length) emitNested(n.nested, parentSels, inner, depth + 1);
                if (inner.length) out.push({ t: 'at', name: n.name, prelude: n.prelude, rules: inner, decls: null, raw: null });
            }
        }
    }

    function flattenNesting(rules) {
        var out = [];
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.t === 'q') {
                out.push(r);
                if (r.nested && r.nested.length) {
                    var sels = [], parts = splitTop(r.sel, ',');
                    for (var k = 0; k < parts.length; k++) { var ps = trim(parts[k].replace(/\s+/g, ' ')); if (ps) sels.push(ps); }
                    if (sels.length) emitNested(r.nested, sels, out, 0);
                }
            } else if (r.t === 'at' && r.rules) {
                out.push({ t: 'at', name: r.name, prelude: r.prelude, rules: flattenNesting(r.rules), decls: null, raw: null });
            } else out.push(r);
        }
        return out;
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
            var nested = [];
            out.push({ t: 'q', sel: sel, decls: parseDecls(s.slice(j2 + 1, close2), nested), nested: nested });
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
            } else if (r.t === 'at' && r.name === 'property' && r.decls) {
                // @property --x { initial-value: 4px }: a registered property falls back to its initial value
                // (var() fallbacks never apply to it), so the initial value is the last resort of resolveVars
                var pname = trim(r.prelude);
                if (pname.indexOf('--') === 0) {
                    if (!ctx.initial) ctx.initial = {};
                    for (var q = 0; q < r.decls.length; q++) if (r.decls[q].p === 'initial-value') ctx.initial[pname] = r.decls[q].v;
                }
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
            else if (ctx.initial && name in ctx.initial) val = ctx.initial[name];
            else if (fallback !== null) val = fallback;
            if (val === null) return null;
            v = v.slice(0, at) + trim(val) + v.slice(close + 1);
        }
        return null;
    }

    // ------------------------------------------------------------------ colours

    var NAMED = { black: [0, 0, 0], white: [255, 255, 255], red: [255, 0, 0], green: [0, 128, 0], blue: [0, 0, 255], yellow: [255, 255, 0],
        gray: [128, 128, 128], grey: [128, 128, 128], silver: [192, 192, 192], orange: [255, 165, 0], purple: [128, 0, 128], pink: [255, 192, 203],
        rebeccapurple: [102, 51, 153], teal: [0, 128, 128], olive: [128, 128, 0], navy: [0, 0, 128], maroon: [128, 0, 0], lime: [0, 255, 0], aqua: [0, 255, 255],
        cyan: [0, 255, 255], magenta: [255, 0, 255], fuchsia: [255, 0, 255], brown: [165, 42, 42], gold: [255, 215, 0], beige: [245, 245, 220],
        transparent: [0, 0, 0, 0], currentcolor: null };
    // colour keywords the old engine does not know (CSS Color 4 named and system colours), as plain hex
    var COLOR_KEYWORDS = { rebeccapurple: '#663399', canvas: '#ffffff', canvastext: '#000000', linktext: '#0000ee', visitedtext: '#551a8b',
        activetext: '#ff0000', field: '#ffffff', fieldtext: '#000000', accentcolor: '#0a84ff', accentcolortext: '#ffffff', buttonborder: '#767676',
        buttontext: '#000000', mark: '#ffff00', marktext: '#000000', selecteditem: '#b3d4fc', selecteditemtext: '#000000' };
    var COLOR_KEYWORD_RE = /\b(rebeccapurple|canvas|canvastext|linktext|visitedtext|activetext|field|fieldtext|accentcolor|accentcolortext|buttonborder|buttontext|mark|marktext|selecteditem|selecteditemtext)\b/i;

    function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
    function gamma(c) { c = clamp01(c); return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }
    function to255(c) { return Math.round(clamp01(c) * 255); }

    function numOrPct(tok, scale) {   // "50%" -> scale*0.5 ; "0.5" -> 0.5 ; "none" -> 0
        if (tok === undefined || tok === 'none') return 0;
        if (tok.charAt(tok.length - 1) === '%') return parseFloat(tok) / 100 * scale;
        var n = parseFloat(tok);
        return isNaN(n) ? 0 : n;
    }

    function alphaOf(tok) {
        if (tok === undefined || tok === null) return 1;
        if (tok === 'none') return 0;   // a missing alpha renders as 0 (CSS Color 4)
        if (tok.charAt(tok.length - 1) === '%') return parseFloat(tok) / 100;
        var a = parseFloat(tok);
        return isNaN(a) ? 1 : a;
    }

    function hueDeg(tok) {
        if (tok === 'none') return 0;
        var v = parseFloat(tok);
        if (isNaN(v)) return 0;
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

    // every CSS named colour (for relative colour syntax, colour math and contrast-color)
    var NAMED_ALL_SRC = 'aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32';
    var NAMED_ALL = null;
    function namedColor(name) {
        if (!NAMED_ALL) {
            NAMED_ALL = {};
            var t = NAMED_ALL_SRC.split(' ');
            for (var i = 0; i + 1 < t.length; i += 2) NAMED_ALL[t[i]] = t[i + 1];
        }
        return NAMED_ALL.hasOwnProperty(name) ? NAMED_ALL[name] : null;
    }

    // ---- sRGB -> other colour spaces (inverse of the conversions above), for relative colour syntax
    function linearChannel(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
    function cbrt(x) { return x < 0 ? -Math.pow(-x, 1 / 3) : Math.pow(x, 1 / 3); }
    function rgbToXYZ(r, g, b) {   // D65
        var R = linearChannel(r), G = linearChannel(g), B = linearChannel(b);
        return [0.4124564 * R + 0.3575761 * G + 0.1804375 * B, 0.2126729 * R + 0.7151522 * G + 0.0721750 * B, 0.0193339 * R + 0.1191920 * G + 0.9503041 * B];
    }
    function rgbToLab(r, g, b) {
        var xyz = rgbToXYZ(r, g, b);
        var X = 1.0478112 * xyz[0] + 0.0228866 * xyz[1] - 0.0501270 * xyz[2];   // Bradford D65 -> D50
        var Y = 0.0295424 * xyz[0] + 0.9904844 * xyz[1] - 0.0170491 * xyz[2];
        var Z = -0.0092345 * xyz[0] + 0.0150436 * xyz[1] + 0.7521316 * xyz[2];
        var e = 216 / 24389, k = 24389 / 27;
        var f = function (t) { return t > e ? cbrt(t) : (k * t + 16) / 116; };
        var fx = f(X / 0.96422), fy = f(Y), fz = f(Z / 0.82521);
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
    }
    function rgbToOklab(r, g, b) {
        var R = linearChannel(r), G = linearChannel(g), B = linearChannel(b);
        var l = cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
        var m = cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
        var s = cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
        return [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s];
    }
    function rgbToHsl(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        var max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, h = 0, s = 0, d = max - min;
        if (d) {
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            if (max === r) h = (g - b) / d + (g < b ? 6 : 0); else if (max === g) h = (b - r) / d + 2; else h = (r - g) / d + 4;
            h *= 60;
        }
        return [h, s * 100, l * 100];
    }
    function polar(ab) {   // [a, b] -> [chroma, hue in degrees]
        var h = Math.atan2(ab[1], ab[0]) * 180 / Math.PI;
        return [Math.sqrt(ab[0] * ab[0] + ab[1] * ab[1]), h < 0 ? h + 360 : h];
    }
    function num4(n) { return String(Math.round(n * 10000) / 10000); }

    // "rgb(from indianred 255 g b)", "oklch(from var(--c) l c calc(h + 90))": the base colour's channels in the
    // target space replace the channel keywords, calc() is evaluated, and the plain function is converted
    function relativeColor(name, inner) {
        var s = trim(inner.slice(4)), baseEnd, m = /^[a-zA-Z-]+\(/.exec(s);
        if (m) baseEnd = matchParen(s, m[0].length - 1) + 1;
        else { baseEnd = 0; while (baseEnd < s.length && !isWS(s.charCodeAt(baseEnd))) baseEnd++; }
        var base = parseColor(s.slice(0, baseEnd));
        if (!base) return null;
        var rest = trim(s.slice(baseEnd)).toLowerCase(), space = name;
        if (name === 'color') {
            var sm = /^([a-z0-9-]+)\s*/.exec(rest);
            if (!sm) return null;
            space = sm[1];
            rest = rest.slice(sm[0].length);
        }
        var r = base[0], g = base[1], b = base[2], alpha = base[3] === undefined ? 1 : base[3];
        var names, vals, pct = [false, false, false], hsl, lab, ok, xyz;
        switch (space) {
            case 'rgb': case 'rgba': names = ['r', 'g', 'b']; vals = [r, g, b]; break;
            case 'hsl': case 'hsla': hsl = rgbToHsl(r, g, b); names = ['h', 's', 'l']; vals = hsl; pct = [false, true, true]; break;
            case 'hwb': hsl = rgbToHsl(r, g, b); names = ['h', 'w', 'b']; vals = [hsl[0], Math.min(r, g, b) / 255 * 100, (1 - Math.max(r, g, b) / 255) * 100]; pct = [false, true, true]; break;
            case 'lab': names = ['l', 'a', 'b']; vals = rgbToLab(r, g, b); break;
            case 'lch': lab = rgbToLab(r, g, b); names = ['l', 'c', 'h']; vals = [lab[0]].concat(polar([lab[1], lab[2]])); break;
            case 'oklab': names = ['l', 'a', 'b']; vals = rgbToOklab(r, g, b); break;
            case 'oklch': ok = rgbToOklab(r, g, b); names = ['l', 'c', 'h']; vals = [ok[0]].concat(polar([ok[1], ok[2]])); break;
            case 'srgb': case 'display-p3': case 'a98-rgb': case 'prophoto-rgb': case 'rec2020': names = ['r', 'g', 'b']; vals = [r / 255, g / 255, b / 255]; break;
            case 'srgb-linear': names = ['r', 'g', 'b']; vals = [linearChannel(r), linearChannel(g), linearChannel(b)]; break;
            case 'xyz': case 'xyz-d65': case 'xyz-d50': names = ['x', 'y', 'z']; vals = rgbToXYZ(r, g, b); break;
            default: return null;
        }
        var alphaTok = null, slash = scanUntil(rest, 0, rest.length, '/');
        if (slash < rest.length) { alphaTok = trim(rest.slice(slash + 1)); rest = rest.slice(0, slash); }
        var toks = splitWS(rest);
        if (toks.length < 3) return null;
        var subst = function (tok) {
            // the walker already turned "calc(h + 90)" (unknown keywords) into "-webkit-calc(h + 90)"
            tok = tok.replace(/-webkit-calc\(/g, 'calc(').replace(/(^|[^a-zA-Z0-9_.%-])(alpha|[a-z])(?![a-zA-Z0-9_%-])/g, function (all, pre, id) {
                if (id === 'alpha') return pre + num4(alpha);
                var k = names.indexOf(id);
                return k < 0 ? all : pre + num4(vals[k]);
            });
            if (tok.indexOf('calc(') >= 0) tok = transformFunctions(tok);
            return tok;
        };
        var outToks = [];
        for (var i = 0; i < 3; i++) {
            var t = subst(toks[i]);
            if (pct[i] && /^-?[\d.]+$/.test(t)) t += '%';   // hsl()/hwb() channels are percentages
            outToks.push(t);
        }
        var assembled = (name === 'color' ? space + ' ' : '') + outToks.join(' ') + (alphaTok !== null ? ' / ' + subst(alphaTok) : (alpha < 1 ? ' / ' + num4(alpha) : ''));
        return convertColorFunction(name, assembled);
    }

    function relativeLuminance(c) {
        return 0.2126 * linearChannel(c[0]) + 0.7152 * linearChannel(c[1]) + 0.0722 * linearChannel(c[2]);
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
        if (/^[a-z]+$/.test(str)) { var named = namedColor(str); if (!named) return null; str = '#' + named; }
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

    function pctChannel(tok) {   // "50%" -> 0.5, "50" -> 0.5 (modern syntax takes numbers as percentages), "none" -> 0
        if (tok === undefined || tok === 'none') return 0;
        var n = parseFloat(tok);
        return isNaN(n) ? 0 : n / 100;
    }

    function convertColorFunction(name, inner) {
        var cc, a;
        if (/^from\s/i.test(inner)) return relativeColor(name, inner);
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
            return hslToRGB(hueDeg(cc.c[0]), pctChannel(cc.c[1]), pctChannel(cc.c[2]), alphaOf(cc.a));
        }
        if (name === 'contrast-color') {
            // black or white, whichever contrasts more with the given colour
            var cbase = parseColor(trim(inner));
            if (!cbase) return null;
            return relativeLuminance(cbase) > 0.179 ? '#000000' : '#ffffff';
        }
        if (name === 'device-cmyk') {
            cc = colorComponents(inner);
            if (cc.c.length < 4) return null;
            var cy = numOrPct(cc.c[0], 1), mg = numOrPct(cc.c[1], 1), ye = numOrPct(cc.c[2], 1), kk = numOrPct(cc.c[3], 1);
            return rgbString(to255((1 - cy) * (1 - kk)), to255((1 - mg) * (1 - kk)), to255((1 - ye) * (1 - kk)), alphaOf(cc.a));
        }
        if (name === 'hwb') {
            cc = colorComponents(inner);
            if (cc.c.length < 3) return null;
            var w = pctChannel(cc.c[1]), bl = pctChannel(cc.c[2]);
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

    // "in lch", "in hsl longer hue": colour interpolation methods the old engine cannot parse
    var INTERPOLATION_RE = /\s*\bin\s+[a-z][a-z0-9-]*(\s+(shorter|longer|increasing|decreasing)\s+hue)?\b\s*/i;

    function convertLinearGradient(inner) {
        inner = inner.replace(INTERPOLATION_RE, ' ');
        var args = splitTop(inner, ',');
        var first = trim(args[0]);
        if (!first) args = args.slice(1);
        first = trim(args[0] || '');
        var rest = args.slice(1);
        var dir = null;
        if (/^to\s+/i.test(first)) {
            var words = splitWS(first).slice(1), mapped = [];
            for (var i = 0; i < words.length; i++) mapped.push(SIDES[words[i].toLowerCase()] || words[i]);
            dir = mapped.join(' ');
        } else if (/^-?[\d.]+(deg|grad|rad|turn)$/i.test(first) || first === '0') {
            var ang = 90 - hueDeg(first === '0' ? '0deg' : first);
            ang = ((ang % 360) + 360) % 360;
            dir = (Math.round(ang * 100) / 100) + 'deg';
        } else rest = args;
        var stops = singleStop(normalizeStops(rest));
        return (dir ? dir + ', ' : '') + stops.join(', ');
    }

    // a gradient with one colour stop is a solid fill; the old syntax needs two stops for that
    function singleStop(stops) {
        if (stops.length === 1) stops.push(splitWS(stops[0])[0]);
        return stops;
    }

    function convertRadialGradient(inner) {
        inner = inner.replace(INTERPOLATION_RE, ' ');
        var args = splitTop(inner, ',');
        var first = trim(args[0]);
        if (!first) { args = args.slice(1); first = trim(args[0] || ''); }
        var rest = args.slice(1);
        var head = null;
        if (/\bat\b/i.test(first)) {
            var parts = first.split(/\s+at\s+/i);
            var shape = trim(parts[0]), pos = trim(parts[1] || 'center');
            head = pos + (shape ? ', ' + shape : '');
        } else if (/^(circle|ellipse|closest-|farthest-|-?[\d.]+(px|%|em|rem))/i.test(first)) {
            head = first;
        } else rest = args;
        var stops = singleStop(normalizeStops(rest));
        return (head ? head + ', ' : '') + stops.join(', ');
    }

    // conic gradients do not exist in the old engine: the same colour stops as a top-to-bottom linear gradient
    // keep the colours of pie charts and decorations instead of leaving the box empty
    function convertConicGradient(inner) {
        inner = inner.replace(INTERPOLATION_RE, ' ');
        var args = splitTop(inner, ',');
        if (/^\s*(from\s|at\s)/i.test(args[0])) args = args.slice(1);
        var stops = [];
        for (var i = 0; i < args.length; i++) {
            var toks = splitWS(trim(args[i])), out = [];
            for (var k = 0; k < toks.length; k++) {
                if (/^-?[\d.]+(deg|grad|rad|turn)$/i.test(toks[k])) out.push((Math.round(hueDeg(toks[k].toLowerCase()) / 360 * 10000) / 100) + '%');
                else out.push(toks[k]);
            }
            if (out.length) stops.push(out.join(' '));
        }
        return singleStop(normalizeStops(stops)).join(', ');
    }

    // image("a.png"), image(url(a.png), red), image(red): the first image, or a flat gradient of the colour
    function convertImage(inner) {
        var args = splitTop(inner, ','), color = null;
        for (var i = 0; i < args.length; i++) {
            var a = trim(args[i]).replace(/^(ltr|rtl)\s+/i, '');
            if (/^["']/.test(a)) return 'url(' + a + ')';
            if (/^(url|-webkit-[a-z-]*gradient|[a-z-]*gradient|-webkit-image-set|image-set)\(/i.test(a)) return a;
            if (!color && parseColor(a)) color = a;
        }
        return color ? '-webkit-linear-gradient(' + color + ', ' + color + ')' : 'none';
    }

    // cross-fade(url(a) 25%, url(b)) / cross-fade(url(a), url(b), 25%) -> -webkit-cross-fade(url(a), url(b), 25%)
    function convertCrossFade(inner) {
        var args = splitTop(inner, ','), images = [], pcts = [], trailing = null;
        for (var i = 0; i < args.length; i++) {
            var toks = splitWS(trim(args[i])), pct = null, img = [];
            for (var k = 0; k < toks.length; k++) { if (/^[\d.]+%$/.test(toks[k])) pct = toks[k]; else img.push(toks[k]); }
            if (img.length) {
                var im = img.join(' ');
                if (!/\(/.test(im) && parseColor(im)) im = '-webkit-linear-gradient(' + im + ', ' + im + ')';
                images.push(im);
                pcts.push(pct);
            } else if (pct !== null) trailing = pct;
        }
        if (!images.length) return 'none';
        if (images.length === 1) return images[0];
        var p = trailing !== null ? trailing : pcts[1] !== null ? pcts[1] : pcts[0] !== null ? (100 - parseFloat(pcts[0])) + '%' : '50%';
        return '-webkit-cross-fade(' + images[0] + ', ' + images[1] + ', ' + p + ')';
    }

    // ------------------------------------------------------------------ values

    var ABS_UNIT = /^-?[\d.]+(px|rem|em|pt|cm|mm|in|ch|ex)$/i;

    function pickMin(args) {
        for (var i = 0; i < args.length; i++) if (ABS_UNIT.test(trim(args[i]))) return trim(args[i]);
        return trim(args[0]);
    }

    // viewport of the page being rewritten (set by run()), for clamp()/min()/max() with viewport units
    var g_viewportWidth = 768, g_viewportHeight = 1024;

    // ---- manifest for the page shim: :has() selectors and @container queries the engine cannot evaluate are
    // rewritten to classes (.br-has-<hash>, .br-cq-<hash>) that shims-extra.js toggles on the elements; the
    // entries travel in a trailing comment of the rewritten output and the app hands them to the page.
    var g_manifest = null, g_suppressManifest = false;   // suppressed while @supports selector() is only being evaluated
    function manifestHash(s) {
        var h = 5381;
        for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
        return h.toString(36);
    }
    function manifestAdd(kind, entry) {
        if (g_suppressManifest) return;
        if (!g_manifest) g_manifest = { has: [], cq: [], seen: {} };
        var key = kind + ':' + entry.h;
        if (g_manifest.seen[key]) return;
        g_manifest.seen[key] = true;
        g_manifest[kind].push(entry);
    }

    function pxString(n) { return (Math.round(n * 100) / 100) + 'px'; }

    // ---- calc-style expressions evaluated statically: numbers with absolute, font or viewport units, + - * /, parentheses.
    // Returns {n, u} with u '' (number), 'px' or 'deg', or null when something (%, ch, unknown idents) cannot be resolved.
    var MATH_CONSTANTS = { e: Math.E, pi: Math.PI };
    function unitValue(num, unit) {
        var n = parseFloat(num);
        if (isNaN(n)) return null;
        switch (unit) {
            case '': return { n: n, u: '' };
            case 'px': return { n: n, u: 'px' };
            case 'vw': return { n: n * g_viewportWidth / 100, u: 'px' };
            case 'vh': return { n: n * g_viewportHeight / 100, u: 'px' };
            case 'vmin': return { n: n * Math.min(g_viewportWidth, g_viewportHeight) / 100, u: 'px' };
            case 'vmax': return { n: n * Math.max(g_viewportWidth, g_viewportHeight) / 100, u: 'px' };
            case 'rem': case 'em': case 'ic': case 'ric': return { n: n * 16, u: 'px' };
            case 'lh': case 'rlh': return { n: n * 16 * 1.2, u: 'px' };
            case 'cap': case 'rcap': return { n: n * 16 * 0.7, u: 'px' };
            case 'rex': case 'rch': return { n: n * 8, u: 'px' };
            case 'pt': return { n: n * 4 / 3, u: 'px' };
            case 'pc': return { n: n * 16, u: 'px' };
            case 'in': return { n: n * 96, u: 'px' };
            case 'cm': return { n: n * 96 / 2.54, u: 'px' };
            case 'mm': return { n: n * 96 / 25.4, u: 'px' };
            case 'q': return { n: n * 96 / 101.6, u: 'px' };
            case 'deg': return { n: n, u: 'deg' };
            case 'grad': return { n: n * 0.9, u: 'deg' };
            case 'rad': return { n: n * 180 / Math.PI, u: 'deg' };
            case 'turn': return { n: n * 360, u: 'deg' };
        }
        return null;
    }
    function evalExpr(expr) {
        var s = trim(expr).toLowerCase(), pos = 0, failed = false;
        function peek() { return s.charAt(pos); }
        function skip() { while (pos < s.length && /\s/.test(s.charAt(pos))) pos++; }
        function atom() {
            skip();
            var c = peek();
            if (c === '(') { pos++; var v = sum(); skip(); if (peek() !== ')') { failed = true; return null; } pos++; return v; }
            if (c === '-' || c === '+') { pos++; var inner = atom(); if (!inner) return null; return { n: c === '-' ? -inner.n : inner.n, u: inner.u }; }
            var m = /^(\d*\.?\d+(?:e[-+]?\d+)?)([a-z%]*)/.exec(s.slice(pos));
            if (m) { pos += m[0].length; var uv = unitValue(m[1], m[2]); if (!uv) failed = true; return uv; }
            var id = /^[a-z][a-z0-9-]*/.exec(s.slice(pos));
            if (id && MATH_CONSTANTS.hasOwnProperty(id[0])) { pos += id[0].length; return { n: MATH_CONSTANTS[id[0]], u: '' }; }
            failed = true;
            return null;
        }
        function product() {
            var left = atom();
            for (;;) {
                skip();
                var op = peek();
                if (op !== '*' && op !== '/') return left;
                pos++;
                var right = atom();
                if (!left || !right) { failed = true; return null; }
                if (op === '*') {
                    if (left.u && right.u) { failed = true; return null; }
                    left = { n: left.n * right.n, u: left.u || right.u };
                } else {
                    if (right.u && right.u !== left.u) { failed = true; return null; }
                    if (right.n === 0) { failed = true; return null; }
                    left = { n: left.n / right.n, u: right.u ? '' : left.u };
                }
            }
        }
        function sum() {
            var left = product();
            for (;;) {
                skip();
                var op = peek();
                if (op !== '+' && op !== '-') return left;
                pos++;
                var right = product();
                if (!left || !right) { failed = true; return null; }
                if (left.u !== right.u) { if (left.n === 0 && !left.u) left.u = right.u; else if (right.n === 0 && !right.u) right.u = left.u; else { failed = true; return null; } }
                left = { n: op === '+' ? left.n + right.n : left.n - right.n, u: left.u };
            }
        }
        var result = sum();
        skip();
        if (failed || !result || pos < s.length || isNaN(result.n) || !isFinite(result.n)) return null;
        return result;
    }
    function fmtValue(v) {
        var n = Math.round(v.n * 100000) / 100000;   // enough precision for nested evaluation
        return n + (v.u || '');
    }
    function evalArgs(args) {
        var out = [];
        for (var i = 0; i < args.length; i++) { var v = evalExpr(args[i]); if (!v) return null; out.push(v); }
        return out;
    }
    function sameUnit(vals) {
        for (var i = 1; i < vals.length; i++) if (vals[i].u !== vals[0].u) return false;
        return true;
    }
    function toRadians(v) { return v.u === 'deg' ? v.n * Math.PI / 180 : v.n; }
    // math functions with statically evaluable arguments; null when they must be left alone
    function evalMathFunction(name, args) {
        var vals, a, b;
        switch (name) {
            case 'round': {
                var strategy = 'nearest', list = args.slice(0);
                if (/^(nearest|up|down|to-zero)$/.test(trim(list[0]).toLowerCase())) strategy = trim(list.shift()).toLowerCase();
                vals = evalArgs(list);
                if (!vals || vals.length < 1) return null;
                a = vals[0]; b = vals.length > 1 ? vals[1] : { n: 1, u: a.u };
                if (a.u !== b.u || b.n === 0) return null;
                var q = a.n / b.n, r;
                if (strategy === 'up') r = Math.ceil(q); else if (strategy === 'down') r = Math.floor(q); else if (strategy === 'to-zero') r = q < 0 ? Math.ceil(q) : Math.floor(q); else r = Math.round(q);
                return fmtValue({ n: r * b.n, u: a.u });
            }
            case 'mod': case 'rem': {
                vals = evalArgs(args);
                if (!vals || vals.length !== 2 || vals[0].u !== vals[1].u || vals[1].n === 0) return null;
                a = vals[0].n; b = vals[1].n;
                var res = name === 'mod' ? a - b * Math.floor(a / b) : a - b * (a / b < 0 ? Math.ceil(a / b) : Math.floor(a / b));
                return fmtValue({ n: res, u: vals[0].u });
            }
            case 'abs': vals = evalArgs(args); return vals && vals.length === 1 ? fmtValue({ n: Math.abs(vals[0].n), u: vals[0].u }) : null;
            case 'sign': {
                var sv = /^\s*(-?)\s*[\d.]/.exec(args[0] || '');
                vals = evalArgs(args);
                if (vals && vals.length === 1) return String(vals[0].n > 0 ? 1 : vals[0].n < 0 ? -1 : 0);
                return sv ? (sv[1] === '-' ? '-1' : '1') : null;   // percentages keep their sign
            }
            case 'pow': vals = evalArgs(args); return vals && vals.length === 2 && !vals[0].u && !vals[1].u ? fmtValue({ n: Math.pow(vals[0].n, vals[1].n), u: '' }) : null;
            case 'sqrt': vals = evalArgs(args); return vals && vals.length === 1 && !vals[0].u && vals[0].n >= 0 ? fmtValue({ n: Math.sqrt(vals[0].n), u: '' }) : null;
            case 'hypot': {
                vals = evalArgs(args);
                if (!vals || !vals.length || !sameUnit(vals)) return null;
                var sq = 0;
                for (var i = 0; i < vals.length; i++) sq += vals[i].n * vals[i].n;
                return fmtValue({ n: Math.sqrt(sq), u: vals[0].u });
            }
            case 'exp': vals = evalArgs(args); return vals && vals.length === 1 && !vals[0].u ? fmtValue({ n: Math.exp(vals[0].n), u: '' }) : null;
            case 'log': {
                vals = evalArgs(args);
                if (!vals || !vals.length || vals[0].u || vals[0].n <= 0) return null;
                var lg = Math.log(vals[0].n);
                if (vals.length > 1) { if (vals[1].u || vals[1].n <= 0) return null; lg /= Math.log(vals[1].n); }
                return fmtValue({ n: lg, u: '' });
            }
            case 'sin': case 'cos': case 'tan': {
                vals = evalArgs(args);
                if (!vals || vals.length !== 1 || (vals[0].u && vals[0].u !== 'deg')) return null;
                var rad = toRadians(vals[0]);
                var t = name === 'sin' ? Math.sin(rad) : name === 'cos' ? Math.cos(rad) : Math.tan(rad);
                if (!isFinite(t) || Math.abs(t) > 1e12) return null;
                return fmtValue({ n: t, u: '' });
            }
            case 'asin': case 'acos': case 'atan': {
                vals = evalArgs(args);
                if (!vals || vals.length !== 1 || vals[0].u) return null;
                var an = name === 'asin' ? Math.asin(vals[0].n) : name === 'acos' ? Math.acos(vals[0].n) : Math.atan(vals[0].n);
                if (isNaN(an)) return null;
                return fmtValue({ n: an * 180 / Math.PI, u: 'deg' });
            }
            case 'atan2': {
                vals = evalArgs(args);
                if (!vals || vals.length !== 2 || vals[0].u !== vals[1].u) return null;
                return fmtValue({ n: Math.atan2(vals[0].n, vals[1].n) * 180 / Math.PI, u: 'deg' });
            }
        }
        return null;
    }

    function applyFunction(name, inner) {
        switch (name) {
            case 'calc': {
                var calcEval = evalExpr(inner);
                if (calcEval) return fmtValue(calcEval);
                // constants and evaluable pieces are substituted; the rest stays a calc() the old engine understands
                var calcInner = inner.replace(/(^|[^\w.-])(e|pi)(?![\w.-])/gi, function (m, pre, id) { return pre + Math.round(MATH_CONSTANTS[id.toLowerCase()] * 100000) / 100000; });
                return '-webkit-calc(' + calcInner + ')';
            }
            case 'clamp': {
                var a = splitTop(inner, ',');
                if (a.length === 3) {
                    var cv = evalArgs(a);
                    if (cv && sameUnit(cv)) return fmtValue({ n: Math.min(Math.max(cv[1].n, cv[0].n), cv[2].n), u: cv[0].u });
                    return trim(a[1]);
                }
                return trim(a[0]);
            }
            case 'min': { var mn = splitTop(inner, ','), mnv = evalArgs(mn); if (mnv && sameUnit(mnv)) { var mnBest = mnv[0]; for (var mi = 1; mi < mnv.length; mi++) if (mnv[mi].n < mnBest.n) mnBest = mnv[mi]; return fmtValue(mnBest); } return pickMin(mn); }
            case 'max': { var mx = splitTop(inner, ','), mxv = evalArgs(mx); if (mxv && sameUnit(mxv)) { var mxBest = mxv[0]; for (var xi = 1; xi < mxv.length; xi++) if (mxv[xi].n > mxBest.n) mxBest = mxv[xi]; return fmtValue(mxBest); } return trim(mx[0]); }
            case 'round': case 'mod': case 'rem': case 'abs': case 'sign': case 'pow': case 'sqrt': case 'hypot':
            case 'sin': case 'cos': case 'tan': case 'asin': case 'acos': case 'atan': case 'atan2': case 'exp': case 'log': {
                var mr = evalMathFunction(name, splitTop(inner, ','));
                if (mr !== null) return mr;
                var r = splitTop(inner, ',');
                return trim(/^(nearest|up|down|to-zero)$/.test(trim(r[0])) && r.length > 1 ? r[1] : r[0]);
            }
            case 'linear-gradient': case 'repeating-linear-gradient':
                return '-webkit-' + name + '(' + convertLinearGradient(inner) + ')';
            case 'radial-gradient': case 'repeating-radial-gradient':
                return '-webkit-' + name + '(' + convertRadialGradient(inner) + ')';
            case 'conic-gradient': return '-webkit-linear-gradient(' + convertConicGradient(inner) + ')';
            case 'repeating-conic-gradient': return '-webkit-repeating-linear-gradient(' + convertConicGradient(inner) + ')';
            case 'image': return convertImage(inner);
            case 'cross-fade': return convertCrossFade(inner);
            case 'paint': case 'element':
                return 'none';
            case 'image-set': {
                // type() hints go, bare strings become url(), gradients stay as they are
                var isv = inner.replace(/\s*type\([^)]*\)/g, '').replace(/(^|,)\s*("[^"]*"|'[^']*')/g, function (m, pre, str) { return pre + ' url(' + str + ')'; });
                return '-webkit-image-set(' + trim(isv) + ')';
            }
            case 'fit-content': return inner;
            case 'progress': {
                // progress(value, start, end) -> a plain number
                var pa = evalArgs(splitTop(inner, ','));
                if (pa && pa.length === 3 && sameUnit(pa) && pa[2].n !== pa[1].n) return fmtValue({ n: (pa[0].n - pa[1].n) / (pa[2].n - pa[1].n), u: '' });
                return null;
            }
            case 'mix': case 'calc-mix': {
                // mix(<progress>, a, b): numbers and lengths interpolate, colours go through color-mix, anything else picks a side
                var ma = splitTop(inner, ',');
                if (ma.length !== 3) return null;
                var mp = mixProgress(trim(ma[0]));
                if (mp === null) return null;
                var mA = trim(ma[1]), mB = trim(ma[2]), nA = evalExpr(mA), nB = evalExpr(mB);
                if (nA && nB && sameUnit([nA, nB])) return fmtValue({ n: nA.n + (nB.n - nA.n) * mp, u: nA.u });
                if (name === 'mix' && parseColor(mA) && parseColor(mB)) return convertColorFunction('color-mix', 'in srgb, ' + mA + ' ' + Math.round((1 - mp) * 100) + '%, ' + mB);
                return mp < 0.5 ? mA : mB;
            }
            case 'random': {
                // random([options,] min, max [, step]): one value chosen when the stylesheet is rewritten
                var rArgs = splitTop(inner, ','), rNums = [];
                for (var ri = 0; ri < rArgs.length; ri++) { var rvv = evalExpr(rArgs[ri]); if (rvv) rNums.push(rvv); }
                if (rNums.length < 2 || !sameUnit(rNums)) return null;
                var rMin = rNums[0].n, rMax = rNums[1].n, rVal = rMin + Math.random() * (rMax - rMin);
                if (rNums.length > 2 && rNums[2].n > 0) rVal = rMin + Math.round((rVal - rMin) / rNums[2].n) * rNums[2].n;
                return fmtValue({ n: Math.min(rMax, rVal), u: rNums[0].u });
            }
            case 'calc-size': {
                // calc-size(basis, expr): the basis alone, or the expression evaluated when the basis is a plain length
                var csArgs = splitTop(inner, ',');
                if (csArgs.length !== 2) return null;
                var csBasis = trim(csArgs[0]), csExpr = trim(csArgs[1]).toLowerCase();
                if (csExpr === 'size') return csBasis;
                if (csExpr.indexOf('size') < 0) { var csPlain = evalExpr(csExpr); return csPlain ? fmtValue(csPlain) : csExpr; }
                var csBase = evalExpr(csBasis);
                if (!csBase) return null;   // auto / stretch / max-content bases need the layout, which only the engine knows
                var csVal = evalExpr(csExpr.replace(/\bsize\b/g, '(' + fmtValue(csBase) + ')'));
                return csVal ? fmtValue(csVal) : null;
            }
            case 'rgb': case 'rgba': case 'hsl': case 'hsla': case 'hwb': case 'oklch': case 'oklab': case 'lab': case 'lch': case 'color': case 'color-mix': case 'light-dark':
            case 'contrast-color': case 'device-cmyk':
                return convertColorFunction(name, inner);
            case 'env': { var e = splitTop(inner, ','); return e.length > 1 ? trim(e[1]) : '0px'; }
        }
        return null;
    }

    // values that contain none of the functions we rewrite skip the walker entirely (url(), translate(), ... are common)
    var INTERESTING_FN = /(?:^|[^a-zA-Z0-9_-])(?:calc|clamp|min|max|linear-gradient|repeating-linear-gradient|radial-gradient|repeating-radial-gradient|conic-gradient|repeating-conic-gradient|rgb|rgba|hsl|hsla|hwb|oklch|oklab|lab|lch|color|color-mix|light-dark|contrast-color|device-cmyk|env|image-set|image|fit-content|round|mod|rem|abs|sign|pow|sqrt|hypot|sin|cos|tan|asin|acos|atan|atan2|exp|log|paint|element|cross-fade|progress|mix|calc-mix|random|calc-size)\(/i;

    function mixProgress(tok) {   // "0.5" or "50%" -> 0.5; timelines and other sources cannot be resolved statically
        if (/^-?[\d.]+%$/.test(tok)) return parseFloat(tok) / 100;
        if (/^-?[\d.]+$/.test(tok)) return parseFloat(tok);
        return null;
    }

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

    // lh = line height (normal is about 1.2 em), cap = cap height, ic = ideographic advance, rex/rch = root ex/ch
    var FONT_UNITS = { lh: [1.2, 'em'], rlh: [1.2, 'rem'], cap: [0.7, 'em'], rcap: [0.7, 'rem'], ic: [1, 'em'], ric: [1, 'rem'], rex: [0.5, 'rem'], rch: [0.5, 'rem'] };

    var SIZING = { width: 1, height: 1, 'min-width': 1, 'min-height': 1, 'max-width': 1, 'max-height': 1, 'flex-basis': 1,
        'inline-size': 1, 'block-size': 1, 'min-inline-size': 1, 'max-inline-size': 1, 'min-block-size': 1, 'max-block-size': 1 };

    function fixValue(p, v) {
        if (v.indexOf('(') >= 0) v = transformFunctions(v);
        v = fixHexAlpha(v);
        if (COLOR_KEYWORD_RE.test(v)) v = v.replace(new RegExp(COLOR_KEYWORD_RE.source, 'gi'), function (m) { return COLOR_KEYWORDS[m.toLowerCase()] || m; });
        if (/\d(dvh|svh|lvh|dvw|svw|lvw|cqw|cqh|cqi|cqb|cqmin|cqmax|vi|vb|svi|lvi|dvi|svb|lvb|dvb|svmin|lvmin|dvmin|svmax|lvmax|dvmax)\b/.test(v)) {
            v = v.replace(/(\d)(dvh|svh|lvh|cqh|cqb|vb|svb|lvb|dvb)\b/g, '$1vh').replace(/(\d)(dvw|svw|lvw|cqw|cqi|vi|svi|lvi|dvi)\b/g, '$1vw')
                 .replace(/(\d)(cqmin|svmin|lvmin|dvmin)\b/g, '$1vmin').replace(/(\d)(cqmax|svmax|lvmax|dvmax)\b/g, '$1vmax');
        }
        // font-relative units the engine lacks, as their typical em/rem equivalents
        if (/\d(lh|rlh|cap|rcap|ic|ric|rex|rch)\b/.test(v)) v = v.replace(/(-?\d*\.?\d+)(lh|rlh|cap|rcap|ic|ric|rex|rch)\b/g, function (m, num, unit) {
            var f = FONT_UNITS[unit];
            return (Math.round(parseFloat(num) * f[0] * 1000) / 1000) + f[1];
        });
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
        'line-clamp': 1, 'box-reflect': 1, 'text-combine': 1, 'font-smoothing': 1, 'overflow-scrolling': 1, 'tap-highlight-color': 1, 'text-fill-color': 1, 'hyphenate-character': 1, 'tab-size': 1,
        'text-stroke': 1, 'text-stroke-width': 1, 'text-stroke-color': 1, 'print-color-adjust': 1, 'background-clip': 0 };

    var PACK = { 'flex-start': 'start', start: 'start', left: 'start', 'flex-end': 'end', end: 'end', right: 'end', center: 'center',
        'space-between': 'justify', 'space-around': 'justify', 'space-evenly': 'justify', stretch: 'start', normal: 'start', 'anchor-center': 'center' };
    var ALIGN = { 'flex-start': 'start', start: 'start', 'self-start': 'start', left: 'start', 'flex-end': 'end', end: 'end', 'self-end': 'end', right: 'end',
        center: 'center', 'anchor-center': 'center', baseline: 'baseline', stretch: 'stretch', normal: 'stretch' };

    function isGlobalKeyword(lv) { return lv === 'inherit' || lv === 'initial'; }

    // the two corners of each css-borders-4 side shorthand, clockwise
    var RADIUS_SIDES = { top: ['border-top-left-radius', 'border-top-right-radius'], right: ['border-top-right-radius', 'border-bottom-right-radius'],
        bottom: ['border-bottom-right-radius', 'border-bottom-left-radius'], left: ['border-bottom-left-radius', 'border-top-left-radius'] };
    RADIUS_SIDES['block-start'] = RADIUS_SIDES.top; RADIUS_SIDES['block-end'] = RADIUS_SIDES.bottom;
    RADIUS_SIDES['inline-start'] = RADIUS_SIDES.left; RADIUS_SIDES['inline-end'] = RADIUS_SIDES.right;

    // css-text-4: white-space is "<white-space-collapse> || <text-wrap-mode>"; the old engine knows the five classic values
    function whiteSpaceValue(p, lv) {
        if (isGlobalKeyword(lv)) return p === 'white-space' ? lv : null;
        var collapse = null, wrap = null, toks = lv.split(/\s+/);
        if (toks.length === 1 && /^(normal|pre|nowrap|pre-wrap|pre-line)$/.test(lv)) return lv;
        for (var i = 0; i < toks.length; i++) {
            var t = toks[i];
            if (t === 'normal' || t === 'pre' || t === 'pre-wrap' || t === 'pre-line') return t;
            if (t === 'collapse' || t === 'preserve' || t === 'preserve-breaks' || t === 'preserve-spaces' || t === 'break-spaces' || t === 'discard') collapse = t;
            else if (t === 'wrap' || t === 'nowrap') wrap = t;
            else if (p === 'text-wrap' || p === 'text-wrap-mode') { /* balance, pretty, stable, auto: no equivalent */ }
            else return null;
        }
        if (p === 'text-wrap' || p === 'text-wrap-mode') return wrap === 'nowrap' ? 'nowrap' : wrap === 'wrap' ? 'normal' : null;
        if (collapse === null && wrap === null) return null;
        var nowrap = wrap === 'nowrap';
        switch (collapse) {
            case 'preserve': return nowrap ? 'pre' : 'pre-wrap';
            case 'preserve-breaks': return 'pre-line';
            case 'preserve-spaces': case 'break-spaces': return 'pre-wrap';
            default: return nowrap ? 'nowrap' : 'normal';   // collapse, discard, none
        }
    }
    // "safe center", "first baseline", "legacy left": the qualifiers mean nothing to the 2009 box model
    function alignKeywords(lv) {
        var toks = lv.split(/\s+/), out = [];
        for (var i = 0; i < toks.length; i++) if (!/^(safe|unsafe|first|last|legacy)$/.test(toks[i])) out.push(toks[i]);
        return out.length ? out : ['baseline'];
    }
    function alignKeyword(lv) { return alignKeywords(lv)[0]; }

    function push(out, p, v, imp) { out.push({ p: p, v: v, imp: imp }); }

    // two-value display syntax (css-display-3): "block flex" -> flex, "inline flow-root" -> inline-block, ...
    var DISPLAY_INSIDE = { flow: 1, 'flow-root': 1, table: 1, flex: 1, grid: 1, ruby: 1, math: 1 };
    function normalizeDisplay(lv) {
        var toks = lv.split(/\s+/), outside = null, inside = null, listItem = false;
        for (var i = 0; i < toks.length; i++) {
            var t = toks[i];
            if (t === 'block' || t === 'inline' || t === 'run-in') outside = t;
            else if (DISPLAY_INSIDE[t]) inside = t;
            else if (t === 'list-item') listItem = true;
            else return lv;
        }
        if (listItem) return outside === 'inline' ? 'inline-block' : 'list-item';
        var inl = outside === 'inline';
        switch (inside || 'flow') {
            case 'flow': return outside || 'block';
            case 'flow-root': return inl ? 'inline-block' : 'flow-root';
            case 'table': return inl ? 'inline-table' : 'table';
            case 'flex': return inl ? 'inline-flex' : 'flex';
            case 'grid': return inl ? 'inline-grid' : 'grid';
            case 'ruby': return inl ? 'ruby' : 'block';
            case 'math': return inl ? 'inline' : 'block';
        }
        return lv;
    }

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

    // [leftIsAuto, rightIsAuto] for a margin / margin-inline shorthand value
    function autoMarginSides(prop, value) {
        var mv = splitWS(value);
        if (!mv.length) return [false, false];
        if (prop === 'margin-inline') return [mv[0] === 'auto', (mv.length > 1 ? mv[1] : mv[0]) === 'auto'];
        if (mv.length === 1) return [mv[0] === 'auto', mv[0] === 'auto'];
        if (mv.length < 4) return [mv[1] === 'auto', mv[1] === 'auto'];
        return [mv[3] === 'auto', mv[1] === 'auto'];
    }

    // the margin shorthand with the lone auto side replaced by 0
    function replaceAutoMargin(value, leftIsTheAutoSide) {
        var mv = splitWS(value);
        if (mv.length === 1) return value;                       // "margin: auto" centres, left alone
        if (mv.length < 4) { if (mv[1] !== 'auto') return value; mv = [mv[0], mv[1], mv.length > 2 ? mv[2] : mv[0], mv[1]]; }
        if (leftIsTheAutoSide && mv[3] === 'auto') mv[3] = '0';
        if (!leftIsTheAutoSide && mv[1] === 'auto') mv[1] = '0';
        return mv.join(' ');
    }

    function fixDeclarations(decls, ctx, keyframe) {
        var local = null, i, d;
        var wrap = false, hasTransform = false, translate = null, rotate = null, scale = null, lastImp = false;
        var objectFit = null, objectPosition = null, ofiDone = false, columnFlex = false;
        var autoLeft = false, autoRight = false, hasDisplay = false;
        // markers the page shim reads back from the computed counter-reset: aspect ratios, containers, scroll snap,
        // smooth scrolling, balanced text (one counter-reset per rule, emitted after the declarations)
        var markers = [], markerKeyword = null;   // "inherit"/"initial" on a marker property becomes counter-reset: inherit/initial
        for (i = 0; i < decls.length; i++) {
            d = decls[i];
            if (d.p === 'display') hasDisplay = true;
            if (d.p.charAt(0) === '-' && d.p.charAt(1) === '-') { if (!local) local = {}; local[d.p] = d.v; }
            else if ((d.p === 'flex-wrap' || d.p === 'flex-flow') && /wrap/i.test(d.v) && !/nowrap/i.test(d.v)) wrap = true;
            else if (d.p === 'object-fit') objectFit = d.v.toLowerCase();
            else if (d.p === 'object-position') objectPosition = d.v.toLowerCase();
            // a column flex container is plain block stacking; the 2009 box model lays nested boxes out
            // repeatedly and deeply nested flex pages (seznam.cz) never finished, so columns stay blocks
            if ((d.p === 'flex-direction' || d.p === 'flex-flow') && /column/i.test(d.v)) columnFlex = true;
            // horizontal auto margins: which sides does the rule set to auto?
            var mvl = trim(d.v).toLowerCase();
            if (d.p === 'margin-left' || d.p === 'margin-inline-start') { if (mvl === 'auto') autoLeft = true; }
            else if (d.p === 'margin-right' || d.p === 'margin-inline-end') { if (mvl === 'auto') autoRight = true; }
            else if (d.p === 'margin' || d.p === 'margin-inline') {
                var ms = autoMarginSides(d.p, mvl);
                if (ms[0]) autoLeft = true;
                if (ms[1]) autoRight = true;
            }
        }
        // "margin-left: auto" on one side only is how flex items are pushed to the far end. The 2009 box model
        // resolves that auto margin to all the free space before the flexible siblings get theirs (Google's
        // result text ended up 0 px wide next to its thumbnail), so the lone auto margin becomes 0.
        var flexPush = autoLeft !== autoRight;
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
                    if (lv.indexOf(' ') > 0 || lv === 'flow') { lv = normalizeDisplay(lv); v = lv; }
                    if (lv === 'flex') push(out, 'display', (wrap || columnFlex) ? 'block' : '-webkit-box', imp);
                    else if (lv === 'inline-flex') push(out, 'display', (wrap || columnFlex) ? 'inline-block' : '-webkit-inline-box', imp);
                    else if (lv === 'grid' || lv === 'flow-root' || lv === 'contents') push(out, 'display', 'block', imp);
                    else if (lv === 'inline-grid') push(out, 'display', 'inline-block', imp);
                    else push(out, 'display', v, imp);
                    continue;
                case 'flex-direction':
                    if (isGlobalKeyword(lv)) { push(out, '-webkit-box-orient', lv, imp); push(out, '-webkit-box-direction', lv, imp); }
                    else {
                        push(out, '-webkit-box-orient', /column/.test(lv) ? 'vertical' : 'horizontal', imp);
                        push(out, '-webkit-box-direction', /reverse/.test(lv) ? 'reverse' : 'normal', imp);
                    }
                    push(out, p, v, imp);
                    continue;
                case 'flex-flow':
                    if (/column|row/.test(lv)) {
                        push(out, '-webkit-box-orient', /column/.test(lv) ? 'vertical' : 'horizontal', imp);
                        push(out, '-webkit-box-direction', /reverse/.test(lv) ? 'reverse' : 'normal', imp);
                    } else if (isGlobalKeyword(lv)) { push(out, '-webkit-box-orient', lv, imp); push(out, '-webkit-box-direction', lv, imp); push(out, '-webkit-box-lines', lv, imp); }
                    if (/wrap/.test(lv) && !/nowrap/.test(lv)) push(out, '-webkit-box-lines', 'multiple', imp);
                    push(out, p, v, imp);
                    continue;
                case 'flex-wrap':
                    push(out, '-webkit-box-lines', isGlobalKeyword(lv) ? lv : /^wrap/.test(lv) ? 'multiple' : 'single', imp);
                    push(out, p, v, imp);
                    continue;
                case 'justify-content': {
                    var jcv = alignKeyword(lv);
                    if (PACK[jcv]) push(out, '-webkit-box-pack', PACK[jcv], imp);
                    else if (isGlobalKeyword(lv)) push(out, '-webkit-box-pack', lv, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'align-items': {
                    var aiv = alignKeyword(lv);
                    if (ALIGN[aiv]) push(out, '-webkit-box-align', ALIGN[aiv], imp);
                    else if (isGlobalKeyword(lv)) push(out, '-webkit-box-align', lv, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'place-items': {
                    var pi = alignKeyword(lv);   // "<align-items> <justify-items>?": the first is the cross axis
                    if (ALIGN[pi]) push(out, '-webkit-box-align', ALIGN[pi], imp);
                    else if (isGlobalKeyword(lv)) push(out, '-webkit-box-align', lv, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'place-content': {
                    var pc = alignKeywords(lv), jc = pc.length > 1 ? pc[1] : pc[0];
                    if (PACK[jc]) push(out, '-webkit-box-pack', PACK[jc], imp);
                    else if (isGlobalKeyword(lv)) push(out, '-webkit-box-pack', lv, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'flex': {
                    if (isGlobalKeyword(lv)) { push(out, '-webkit-box-flex', lv, imp); push(out, p, v, imp); continue; }
                    var f = parseFlexShorthand(v);
                    push(out, '-webkit-box-flex', f.grow, imp);
                    if (f.basis && f.basis !== '0' && f.basis !== '0px' && f.basis !== '0%') push(out, 'width', /^(min-content|max-content|fit-content|stretch)$/.test(f.basis) ? 'auto' : f.basis, imp);
                    else if (/\b(auto|content)\b/.test(lv) || lv === 'none' || lv === 'initial') push(out, 'width', 'auto', imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'flex-grow':
                    push(out, '-webkit-box-flex', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'flex-basis':
                    if (lv === 'auto' || lv === 'content' || /^(min-content|max-content|fit-content|stretch|-webkit-)/.test(lv)) push(out, 'width', 'auto', imp);
                    else if (lv !== '0' && lv !== '0px') push(out, 'width', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'order': {
                    var o = parseInt(v, 10);
                    push(out, '-webkit-box-ordinal-group', isGlobalKeyword(lv) ? lv : String(isNaN(o) ? 1 : Math.max(1, o + 1)), imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'inset': {
                    var ib = expandBox(splitWS(v));
                    push(out, 'top', ib[0], imp); push(out, 'right', ib[1], imp); push(out, 'bottom', ib[2], imp); push(out, 'left', ib[3], imp);
                    continue;
                }
                case 'aspect-ratio': {
                    // the engine has no aspect-ratio: the ratio travels in a harmless counter-reset value that
                    // shims-extra.js reads back from the computed style and turns into a height
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    var ar = /(?:^|\s)([\d.]+)\s*(?:\/\s*([\d.]+))?\s*$/.exec(lv.replace(/^auto\s*/, ''));
                    if (ar) {
                        var arw = parseFloat(ar[1]), arh = ar[2] ? parseFloat(ar[2]) : 1;
                        if (arw > 0 && arh > 0) markers.push('br-aspect ' + Math.round(arw * 1000) + ' br-aspect-h ' + Math.round(arh * 1000));
                    }
                    push(out, p, v, imp);
                    continue;
                }
                case 'width': case 'inline-size':
                    // the engine has no intrinsic sizing keywords: a table shrinks to fit its content (and never
                    // below the min-content width, which "width: 1px" then asks for)
                    if (!hasDisplay && !keyframe && (lv === '-webkit-fit-content' || lv === '-webkit-max-content' || lv === '-webkit-min-content')) {
                        push(out, 'display', 'table', imp);
                        push(out, 'width', lv === '-webkit-min-content' ? '1px' : 'auto', imp);
                    }
                    push(out, 'width', v, imp);
                    continue;
                case 'margin-left': case 'margin-inline-start':
                    push(out, 'margin-left', (flexPush && autoLeft && lv === 'auto') ? '0' : v, imp);
                    continue;
                case 'margin-right': case 'margin-inline-end':
                    push(out, 'margin-right', (flexPush && autoRight && lv === 'auto') ? '0' : v, imp);
                    continue;
                case 'margin':
                    push(out, p, flexPush ? replaceAutoMargin(lv, autoLeft) : v, imp);
                    continue;
                case 'margin-inline': {
                    var miv = splitWS(lv), miStart = miv[0], miEnd = miv.length > 1 ? miv[1] : miv[0];
                    if (flexPush && autoLeft && miStart === 'auto') miStart = '0';
                    if (flexPush && autoRight && miEnd === 'auto') miEnd = '0';
                    push(out, 'margin-left', miStart, imp);
                    push(out, 'margin-right', miEnd, imp);
                    continue;
                }
                case 'overflow': case 'overflow-x': case 'overflow-y':
                    push(out, p, lv === 'overlay' ? 'auto' : lv === 'clip' ? 'hidden' : v, imp);
                    continue;
                case 'opacity':
                    push(out, p, /%$/.test(lv) ? String(Math.round(parseFloat(lv) * 10) / 1000) : v, imp);
                    continue;
                case 'overflow-wrap': case 'word-wrap':
                    push(out, 'word-wrap', lv === 'anywhere' ? 'break-word' : v, imp);
                    if (p === 'overflow-wrap') push(out, p, v, imp);
                    continue;
                case 'word-break':
                    push(out, p, lv === 'auto-phrase' ? 'normal' : v, imp);
                    continue;
                case 'white-space': case 'white-space-collapse': case 'text-wrap': case 'text-wrap-mode': {
                    // css-text-4 keywords and the two-value syntax become the classic white-space values
                    var wsv = whiteSpaceValue(p, lv);
                    if (p === 'white-space') { push(out, p, wsv || v, imp); continue; }
                    if (wsv) push(out, 'white-space', wsv, imp);
                    if (/\bbalance\b/.test(lv)) markers.push('br-balance 1');   // the shim balances the lines of marked headings
                    if (p === 'text-wrap' && isGlobalKeyword(lv)) markerKeyword = lv;
                    push(out, p, v, imp);
                    continue;
                }
                case 'text-wrap-style':
                    if (lv === 'balance') markers.push('br-balance 1');
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    push(out, p, v, imp);
                    continue;
                case 'vertical-align': {
                    // css-inline-3 baseline keywords (alphabetic, central, first/last) map onto the classic ones
                    var vat = lv.split(/\s+/), vout = [];
                    for (var vi = 0; vi < vat.length; vi++) {
                        var vt = vat[vi];
                        if (vt === 'first' || vt === 'last') continue;
                        vout.push(vt === 'alphabetic' ? 'baseline' : vt === 'central' || vt === 'mathematical' || vt === 'center' ? 'middle' : vt === 'ideographic' ? 'text-bottom' : vt);
                    }
                    push(out, p, vout.length ? vout[0] : 'baseline', imp);
                    continue;
                }
                case 'text-overflow': {
                    // fade() and strings are not drawn here; of two values (start/end lines) the end one is kept
                    var tov = splitWS(lv), tol = tov[tov.length - 1] || 'clip';
                    push(out, p, tol === 'clip' || tol === 'ellipsis' || isGlobalKeyword(tol) ? tol : 'ellipsis', imp);
                    continue;
                }
                case 'image-rendering':
                    if (lv === 'pixelated' || lv === 'crisp-edges') push(out, p, '-webkit-optimize-contrast', imp);
                    else if (lv === 'smooth' || lv === 'high-quality') push(out, p, 'auto', imp);
                    push(out, p, v, imp);
                    continue;
                case 'contain':
                    if (/(^|\s)(strict|content|paint)(\s|$)/.test(lv)) push(out, 'overflow', 'hidden', imp);   // paint containment clips
                    push(out, p, v, imp);
                    continue;
                case 'hyphenate-limit-chars': {
                    // "<total> <before> <after>" -> the old engine's before/after limits
                    var hl = lv.split(/\s+/);
                    if (hl.length > 1 && hl[1] !== 'auto') push(out, '-webkit-hyphenate-limit-before', hl[1], imp);
                    if (hl.length > 2 && hl[2] !== 'auto') push(out, '-webkit-hyphenate-limit-after', hl[2], imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'hyphenate-limit-lines':
                    push(out, '-webkit-hyphenate-limit-lines', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'letter-spacing': case 'word-spacing':
                    // percentages are relative to the font size (letter-spacing) or the space width (word-spacing, about a quarter em)
                    if (/^-?[\d.]+%$/.test(lv)) push(out, p, (Math.round(parseFloat(lv) * (p === 'letter-spacing' ? 100 : 25)) / 10000) + 'em', imp);
                    else push(out, p, v, imp);
                    continue;
                case 'resize':
                    push(out, p, lv === 'block' ? 'vertical' : lv === 'inline' ? 'horizontal' : v, imp);
                    continue;
                case 'user-select':
                    push(out, '-webkit-user-select', lv === 'contain' || lv === 'all' ? 'text' : v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'line-break':
                    push(out, '-webkit-line-break', lv === 'anywhere' ? 'loose' : v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'text-align': {
                    var ta = lv === 'start' ? 'left' : lv === 'end' ? 'right' : lv === 'justify-all' ? 'justify' : v;
                    push(out, p, ta, imp);
                    continue;
                }
                case 'font-weight': {
                    // arbitrary numbers (CSS Fonts 4) become the nearest hundred the old engine knows
                    var fw = /^-?[\d.]+$/.test(lv) ? parseFloat(lv) : NaN;
                    if (!isNaN(fw) && (fw % 100 !== 0 || fw < 100 || fw > 900)) fw = Math.min(900, Math.max(100, Math.round(fw / 100) * 100));
                    push(out, p, isNaN(fw) ? v : String(fw), imp);
                    continue;
                }
                case 'font-style':
                    push(out, p, /^oblique\s+-?[\d.]+(deg|grad|rad|turn)/.test(lv) ? 'oblique' : v, imp);
                    continue;
                case 'text-decoration': {
                    // the shorthand may carry style, colour and thickness; the old engine only takes the lines
                    var lines = [], tdToks = splitWS(lv), other = false;
                    for (var tdi = 0; tdi < tdToks.length; tdi++) {
                        if (/^(none|underline|overline|line-through|blink)$/.test(tdToks[tdi])) lines.push(tdToks[tdi]); else other = true;
                    }
                    push(out, p, other && lines.length ? lines.join(' ') : v, imp);
                    continue;
                }
                case 'text-decoration-line':
                    push(out, 'text-decoration', v, imp);
                    push(out, p, v, imp);
                    continue;
                case 'text-shadow': case 'box-shadow': {
                    // a fourth length (spread) in text-shadow is CSS Text Decoration 4: the old parser rejects the whole value
                    if (p === 'text-shadow') {
                        var shadows = splitTop(v, ','), fixedShadows = [];
                        for (var shi = 0; shi < shadows.length; shi++) {
                            var stoks = splitWS(trim(shadows[shi])), lens = [], others = [];
                            for (var sti = 0; sti < stoks.length; sti++) { if (/^-?[\d.]+(px|em|rem|pt|%|vw|vh)?$/.test(stoks[sti]) && lens.length < 3) lens.push(stoks[sti]); else if (/^-?[\d.]+(px|em|rem|pt|%|vw|vh)?$/.test(stoks[sti])) { /* spread dropped */ } else others.push(stoks[sti]); }
                            fixedShadows.push(lens.concat(others).join(' '));
                        }
                        push(out, p, fixedShadows.join(', '), imp);
                        continue;
                    }
                    push(out, p, v, imp);
                    continue;
                }
                case 'list-style-type': {
                    var LST_SAFE = /^(disc|circle|square|decimal|decimal-leading-zero|lower-roman|upper-roman|lower-greek|lower-latin|upper-latin|lower-alpha|upper-alpha|armenian|georgian|none|inherit|initial|hebrew|hiragana|katakana|hiragana-iroha|katakana-iroha|cjk-ideographic|lower-norwegian|upper-norwegian|afar|amharic|arabic-indic|bengali|cambodian|devanagari|gujarati|gurmukhi|kannada|khmer|lao|malayalam|mongolian|myanmar|oriya|persian|telugu|thai|tibetan|urdu)$/;
                    var lst = v;
                    if (!LST_SAFE.test(lv)) lst = /decimal|numeric|formal|informal|hangul|hanja|chinese|japanese|tamil|ethiopic|arabic|persian/.test(lv) ? 'decimal' : 'disc';
                    push(out, p, lst, imp);
                    continue;
                }
                case 'break-before': case 'break-after': {
                    var side = p === 'break-before' ? 'before' : 'after';
                    var pageVal = /^avoid/.test(lv) ? 'avoid' : (lv === 'page' || lv === 'always' || lv === 'recto' || lv === 'verso') ? 'always' : (lv === 'left' || lv === 'right') ? lv : 'auto';
                    var colVal = /^avoid/.test(lv) ? 'avoid' : (lv === 'column' || lv === 'always') ? 'always' : 'auto';
                    push(out, 'page-break-' + side, pageVal, imp);
                    push(out, '-webkit-column-break-' + side, colVal, imp);
                    push(out, p, v, imp);
                    continue;
                }
                case 'min-width': case 'min-height': case 'min-inline-size': case 'min-block-size':
                    // "auto" is the flexbox initial value; the old engine only knows 0 there
                    push(out, p === 'min-inline-size' ? 'min-width' : p === 'min-block-size' ? 'min-height' : p, lv === 'auto' ? '0' : v, imp);
                    continue;
                case 'translate': translate = v; continue;
                case 'rotate': rotate = v; continue;
                case 'scale': scale = v; continue;
                case 'transform': {
                    hasTransform = true;
                    var tfv = v.replace(/\s*perspective\(\s*none\s*\)\s*/gi, ' ').replace(/^\s+|\s+$/g, '') || 'none';
                    push(out, '-webkit-transform', tfv, imp);
                    push(out, p, v, imp);
                    continue;
                }
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
                    if (lv === 'sticky') push(out, p, '-webkit-sticky', imp);   // iOS 6.1 knows the prefixed value
                    push(out, p, v, imp);
                    continue;
                case 'text-rendering':
                    // optimizeLegibility / geometricPrecision force the slow CoreText shaping path in the old engine
                    push(out, p, /speed|auto/i.test(lv) ? v : 'optimizeSpeed', imp);
                    continue;
                case 'container-type': case 'container-name': case 'container': {
                    // container elements are marked through counter-reset (read back from the computed style by the
                    // shim): "br-container 1" for a size container, "br-cn-<name> 1" for each container name
                    var cqMarks = [], cqNames = '', cqType = '';
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    if (p === 'container') { var slash = lv.indexOf('/'); cqNames = trim(slash >= 0 ? lv.slice(0, slash) : lv); cqType = slash >= 0 ? trim(lv.slice(slash + 1)) : ''; }
                    else if (p === 'container-name') cqNames = lv;
                    else cqType = lv;
                    if (cqType === 'size' || cqType === 'inline-size') cqMarks.push('br-container 1');
                    if (cqNames && cqNames !== 'none') { var cqList = cqNames.split(/\s+/); for (var cqi = 0; cqi < cqList.length; cqi++) if (/^[a-z_][\w-]*$/.test(cqList[cqi])) cqMarks.push('br-cn-' + cqList[cqi] + ' 1'); }
                    for (var cqk = 0; cqk < cqMarks.length; cqk++) markers.push(cqMarks[cqk]);
                    push(out, p, v, imp);
                    continue;
                }
                case 'scroll-snap-type': {
                    // "x mandatory", "both proximity", "inline mandatory": the shim snaps the scroll position of marked containers
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    var snapAxis = /\b(x|inline)\b/.test(lv) ? 'x' : /\b(y|block)\b/.test(lv) ? 'y' : /\bboth\b/.test(lv) ? 'both' : null;
                    if (snapAxis && lv !== 'none') {
                        if (snapAxis !== 'y') markers.push('br-snap-x 1');
                        if (snapAxis !== 'x') markers.push('br-snap-y 1');
                        if (/\bmandatory\b/.test(lv)) markers.push('br-snap-m 1');
                    }
                    push(out, p, v, imp);
                    continue;
                }
                case 'scroll-snap-align': case 'scroll-snap-stop': {
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    if (p === 'scroll-snap-align') {
                        var snapAlign = /\bcenter\b/.test(lv) ? 2 : /\bend\b/.test(lv) ? 3 : /\bstart\b/.test(lv) ? 1 : 0;
                        if (snapAlign) markers.push('br-snap-align ' + snapAlign);
                    } else if (lv === 'always') markers.push('br-snap-stop 1');
                    push(out, p, v, imp);
                    continue;
                }
                case 'scroll-padding': case 'scroll-padding-left': case 'scroll-padding-top': case 'scroll-padding-inline-start': case 'scroll-padding-block-start':
                case 'scroll-padding-inline': case 'scroll-padding-block': case 'scroll-padding-right': case 'scroll-padding-bottom': case 'scroll-padding-inline-end': case 'scroll-padding-block-end':
                case 'scroll-margin': case 'scroll-margin-left': case 'scroll-margin-top': case 'scroll-margin-inline-start': case 'scroll-margin-block-start': case 'scroll-margin-inline': case 'scroll-margin-block':
                case 'scroll-margin-right': case 'scroll-margin-bottom': case 'scroll-margin-inline-end': case 'scroll-margin-block-end': {
                    // the start-side value (px, em, rem) becomes the container's snap padding or the item's snap margin
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    var spToks = lv.split(/\s+/), spTok = spToks[(p === 'scroll-padding' || p === 'scroll-margin') && spToks.length > 1 ? 3 : 0] || spToks[0];
                    if ((p === 'scroll-padding' || p === 'scroll-margin') && spToks.length === 2) spTok = spToks[1];
                    if ((p === 'scroll-padding' || p === 'scroll-margin') && spToks.length === 3) spTok = spToks[1];
                    var spv = /^(-?[\d.]+)(px|em|rem)$/.exec(spTok);
                    if (spv && !/-(right|bottom|inline-end|block-end)$/.test(p)) markers.push((p.indexOf('scroll-padding') === 0 ? 'br-snap-pad ' : 'br-snap-margin ') + Math.round(parseFloat(spv[1]) * (spv[2] === 'px' ? 1 : 16)));
                    else if (spv || /^(auto|0)$/.test(spTok)) markers.push('br-snap-end 1');   // end-side values only mark the element as snap-aware
                    push(out, p, v, imp);
                    continue;
                }
                case 'scroll-behavior':
                    if (isGlobalKeyword(lv)) markerKeyword = lv;
                    if (lv === 'smooth') markers.push('br-smooth 1');
                    push(out, p, v, imp);
                    continue;
                case 'border-top-radius': case 'border-right-radius': case 'border-bottom-radius': case 'border-left-radius':
                case 'border-block-start-radius': case 'border-block-end-radius': case 'border-inline-start-radius': case 'border-inline-end-radius': {
                    // css-borders-4 side shorthands: "<h1> <h2>? / <v1> <v2>?" -> the two corner longhands
                    var corners = RADIUS_SIDES[p.replace(/^border-|-radius$/g, '')];
                    if (isGlobalKeyword(lv)) { push(out, corners[0], v, imp); push(out, corners[1], v, imp); continue; }
                    var rSlash = scanUntil(v, 0, v.length, '/');
                    var rh = splitWS(trim(v.slice(0, rSlash))), rv = rSlash < v.length ? splitWS(trim(v.slice(rSlash + 1))) : null;
                    if (!rh.length) { push(out, p, v, imp); continue; }
                    var rh2 = rh.length > 1 ? rh[1] : rh[0], rv1 = rv && rv.length ? rv[0] : null, rv2 = rv && rv.length ? (rv.length > 1 ? rv[1] : rv[0]) : null;
                    push(out, corners[0], rv1 ? rh[0] + ' ' + rv1 : rh[0], imp);
                    push(out, corners[1], rv2 ? rh2 + ' ' + rv2 : rh2, imp);
                    continue;
                }
                case 'line-clamp':
                    // the standard property is the old -webkit-line-clamp idiom (which needs the legacy box)
                    if (/^\d+$/.test(lv)) {
                        push(out, '-webkit-line-clamp', v, imp);
                        if (!hasDisplay) push(out, 'display', '-webkit-box', imp);
                        push(out, '-webkit-box-orient', 'vertical', imp);
                        push(out, 'overflow', 'hidden', imp);
                    }
                    push(out, p, v, imp);
                    continue;
                case 'font-variant-caps':
                    if (/^(all-)?(small|petite)-caps$/.test(lv)) push(out, 'font-variant', 'small-caps', imp);
                    else if (lv === 'normal') push(out, 'font-variant', 'normal', imp);
                    push(out, p, v, imp);
                    continue;
                case 'font-variant':
                    // the engine knows normal and small-caps; the level 4 keyword lists would invalidate the declaration
                    if (/(^|\s)(all-)?(small|petite)-caps(\s|$)/.test(lv)) push(out, p, 'small-caps', imp);
                    else if (/^(normal|none|inherit|initial|small-caps)$/.test(lv)) push(out, p, v, imp);
                    continue;
                case 'font-feature-settings': case '-webkit-font-feature-settings': case 'font-variant-ligatures': case 'font-kerning':
                case '-webkit-font-kerning': case 'font-variant-numeric': case 'font-optical-sizing': case 'font-variation-settings':
                    continue;   // each of these switches on complex text layout for the whole element
                case 'object-fit': case 'object-position':
                    // object-fit-images (in the polyfill bundle) reads the intent from this font-family hack
                    push(out, p, v, imp);
                    if (!ofiDone) {
                        ofiDone = true;
                        push(out, 'font-family', '"' + (objectFit ? 'object-fit: ' + objectFit : '') + (objectFit && objectPosition ? '; ' : '') +
                             (objectPosition ? 'object-position: ' + objectPosition : '') + '"', imp);
                    }
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
            if (translate && translate !== 'none') {
                var tt = splitWS(translate);
                parts.push(tt.length > 2 ? 'translate3d(' + tt[0] + ', ' + tt[1] + ', ' + tt[2] + ')' : tt.length > 1 ? 'translate(' + tt[0] + ', ' + tt[1] + ')' : 'translate(' + tt[0] + ')');
            }
            if (rotate && rotate !== 'none') {
                var rt = splitWS(rotate), rl = rt[0].toLowerCase();
                if (rt.length === 2 && (rl === 'x' || rl === 'y' || rl === 'z')) parts.push(rl === 'z' ? 'rotate(' + rt[1] + ')' : 'rotate' + rl.toUpperCase() + '(' + rt[1] + ')');
                else if (rt.length === 4) parts.push('rotate3d(' + rt[0] + ', ' + rt[1] + ', ' + rt[2] + ', ' + rt[3] + ')');
                else parts.push('rotate(' + rotate + ')');
            }
            if (scale && scale !== 'none') {
                var st = splitWS(scale);
                parts.push(st.length > 2 ? 'scale3d(' + st[0] + ', ' + st[1] + ', ' + st[2] + ')' : st.length > 1 ? 'scale(' + st[0] + ', ' + st[1] + ')' : 'scale(' + st[0] + ')');
            }
            if (parts.length) { push(out, '-webkit-transform', parts.join(' '), false); push(out, 'transform', parts.join(' '), false); }
        }
        if (markers.length) push(out, 'counter-reset', markers.join(' '), false);
        else if (markerKeyword) push(out, 'counter-reset', markerKeyword, false);
        return out;
    }

    // ------------------------------------------------------------------ selectors

    var DROP_SELECTOR = /:has\(|::slotted\(|:host|:state\(|::backdrop|::marker|::file-selector-button|::cue|::view-transition|:autofill|:picture-in-picture|:defined|:current|:past|:future|::highlight|::spelling-error|::grammar-error|::target-text|:xr-overlay|:open|:closed|:volume-locked|>>>|\/deep\/|^\s*&|\s&|&\s|:nth-child\([^)]*\bof\b/i;

    // Pseudo-classes the engine lacks that shims-extra.js maintains as classes on the elements (focus-within,
    // placeholder-shown, user-invalid/valid, blank, target-within, playing/paused/muted, local-link, modal, fullscreen)
    var STATE_CLASSES = { ':focus-within': '.br-focus-within', ':placeholder-shown': '.br-placeholder-shown', ':user-invalid': '.br-user-invalid',
        ':user-valid': '.br-user-valid', ':blank': '.br-blank', ':target-within': '.br-target-within', ':playing': '.br-playing', ':paused': '.br-paused',
        ':muted': '.br-muted', ':local-link': '.br-local-link', ':modal': '.br-modal', ':fullscreen': '.br-fullscreen', ':-webkit-full-screen': '.br-fullscreen', ':popover-open': '.br-popover-open',
        ':seeking': '.br-seeking', ':buffering': '.br-buffering', ':stalled': '.br-stalled' };
    var STATE_CLASS_RE = /:(focus-within|placeholder-shown|user-invalid|user-valid|blank|target-within|playing|paused|muted|local-link|modal|fullscreen|-webkit-full-screen|popover-open|seeking|buffering|stalled)\b/gi;

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

    // ".card:has(> img):hover" -> ".card.br-has-xxxx:hover"; the shim finds the ".card" candidates and checks "> img"
    // inside each. :has() nested in :not()/:is() stays unsupported (the selector is dropped).
    function rewriteHas(sel) {
        var out = '', i = 0, n = sel.length;
        while (i < n) {
            var at = sel.indexOf(':has(', i);
            if (at < 0) { out += sel.slice(i); break; }
            var close = matchParen(sel, at + 4);
            var inner = trim(sel.slice(at + 5, close));
            var prefix = trim(out + sel.slice(i, at));
            if (!inner) return null;
            // ":not(:has(X))" works the same way with the class negated; :has() inside any other function stays unsupported
            var inNot = /:not\($/i.test(prefix);
            var target = inNot ? trim(prefix.slice(0, -5)) : prefix;
            if (!inNot && openParens(prefix) > 0) return null;
            if (!target || /[>+~\s]$/.test(target)) target += '*';
            var h = manifestHash(target + '|' + inner);
            manifestAdd('has', { h: h, target: target, inner: inner });
            out += sel.slice(i, at) + ((/[>+~\s]$/.test(sel.slice(i, at)) || at === i) && !inNot ? '*' : '') + '.br-has-' + h;
            i = close + 1;
        }
        return out;
    }

    function openParens(s) {   // unbalanced "(" outside strings and brackets
        var depth = 0, i = 0, n = s.length;
        while (i < n) {
            var c = s.charCodeAt(i);
            if (c === 34 || c === 39) { i = skipString(s, i, n); continue; }
            if (c === 40) depth++; else if (c === 41) depth--;
            i++;
        }
        return depth;
    }

    function fixSelector(sel) {
        sel = trim(sel);
        if (sel.indexOf(':has(') >= 0 && g_manifest !== false) {
            var rewritten = rewriteHas(sel);
            if (rewritten === null) return [];
            sel = rewritten;
        }
        if (!sel || DROP_SELECTOR.test(sel)) return [];
        sel = sel.replace(/:focus-visible/gi, ':focus')
                 .replace(/::?placeholder(?![\w-])/gi, '::-webkit-input-placeholder')
                 .replace(/:any-link/gi, ':link')
                 .replace(/:scope\b/gi, ':root')
                 .replace(/(\[[^\]]*?)\s+[isIS]\s*\]/g, '$1]')
                 .replace(/:lang\(([^,)]*),[^)]*\)/gi, ':lang($1)')
                 .replace(STATE_CLASS_RE, function (m) { return STATE_CLASSES[m.toLowerCase()] || m; })
                 // shadow DOM is emulated in the light DOM, so exported parts are plain part attributes
                 .replace(/::part\(\s*([^)]*?)\s*\)/gi, function (m, names) { var ps = names.split(/\s+/), s = ''; for (var k = 0; k < ps.length; k++) if (ps[k]) s += '[part~="' + ps[k] + '"]'; return s || m; })
                 .replace(/:read-only\b/gi, '[readonly]')
                 .replace(/:read-write\b/gi, ':not([readonly])')
                 .replace(/:dir\(\s*rtl\s*\)/gi, '[dir="rtl"]')
                 .replace(/:dir\(\s*ltr\s*\)/gi, ':not([dir="rtl"])');
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
        position: /^(static|relative|absolute|fixed|sticky|-webkit-sticky)$/i, transform: 1, '-webkit-transform': 1, transition: 1, animation: 1, filter: 1, '-webkit-filter': 1,
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
            p === 'backdrop-filter' || p === '-webkit-backdrop-filter' ||
            p === 'overflow' && /clip/i.test(v) || p === 'display' && /grid|contents|flow-root/i.test(v) ||
            p === 'writing-mode' || p === 'anchor-name' || p === 'view-transition-name' || p === 'contain' || p === 'content-visibility' ||
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
            if (/^selector\(/i.test(t)) {
                // supported when the rewriter can turn it into something the engine parses (natively or emulated)
                var selInner = trim(t.slice(9, t.lastIndexOf(')') > 9 ? t.lastIndexOf(')') : t.length)), selOk = false, prevSuppress = g_suppressManifest;
                g_suppressManifest = true;
                try { selOk = fixSelectorList(selInner).length > 0; } catch (e) { selOk = false; }
                g_suppressManifest = prevSuppress;
                return selOk;
            }
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

    // Number of columns a grid container would have (0 when the rule is not a grid or the count is unclear).
    // gaps of a grid container rule: [rowGap, columnGap] as plain lengths or null
    function gridGaps(decls, ctx) {
        var row = null, col = null;
        for (var i = 0; i < decls.length; i++) {
            var p = decls[i].p, v = resolveVars(decls[i].v, null, ctx);
            if (v === null) continue;
            var lv = trim(v).toLowerCase();
            if (p === 'gap' || p === 'grid-gap') { var g = splitWS(lv); row = g[0]; col = g.length > 1 ? g[1] : g[0]; }
            else if (p === 'row-gap' || p === 'grid-row-gap') row = lv;
            else if (p === 'column-gap' || p === 'grid-column-gap') col = lv;
        }
        function simple(x) { return x && /^[\d.]+(px|rem|em|vw|vh|%)$/.test(x) && parseFloat(x) > 0 ? x : null; }
        return [simple(row), simple(col)];
    }

    function timesLength(len, n) {
        var m = /^([\d.]+)([a-z%]+)$/.exec(len);
        return m ? (Math.round(parseFloat(m[1]) * n * 100) / 100) + m[2] : null;
    }

    // Number of equal columns a grid container rule asks for (0: not a grid, or nothing to emulate; -1: a
    // container that was a multi-column grid earlier in the sheet goes back to one column, typically in a
    // media query, and the floated children must be reset). `key` identifies the rule's selector list.
    function gridColumns(decls, ctx, key) {
        var isGrid = false, tracks = null, display = null;
        for (var i = 0; i < decls.length; i++) {
            var p = decls[i].p, v = decls[i].v;
            if (p === 'display') { display = trim(v).toLowerCase(); isGrid = /^(inline-)?grid$/.test(display); }
            else if (p === 'grid-template-columns') tracks = v;
            else if (p === 'grid-template' && v.indexOf('/') >= 0) tracks = v.slice(v.lastIndexOf('/') + 1);
            else if (p === 'grid' && v.indexOf('/') >= 0 && !/auto-flow/i.test(v.slice(0, v.indexOf('/')))) tracks = v.slice(v.lastIndexOf('/') + 1);
        }
        if (!ctx.gridSels) ctx.gridSels = {};
        // per selector list: undefined = never a grid, 0 = no longer one, 1 = grid with one column, n = n floated columns
        var state = key ? ctx.gridSels[key] : undefined, known = state > 0, wasColumns = state > 1;
        if (isGrid && key) ctx.gridSels[key] = 1;
        else if (!isGrid && display !== null && known && key) { ctx.gridSels[key] = 0; return wasColumns ? -1 : 0; }   // display:block / none in a media query
        if (!isGrid && !known) return 0;
        if (!tracks) return 0;
        tracks = resolveVars(tracks, null, ctx);
        if (tracks === null) return 0;
        var t = trim(tracks).replace(/\[[^\]]*\]/g, ' ');
        if (/^(none|auto|subgrid|masonry)$/i.test(t)) return wasColumns ? -1 : 0;
        var width = ctx.viewportWidth || 768;
        var rep = /repeat\(\s*(\d+|auto-fill|auto-fit)\s*,\s*([^)]*(?:\([^)]*\))?[^)]*)\)/i.exec(t);
        var count = 0;
        if (rep) {
            var inner = splitWS(trim(rep[2])).length || 1;
            if (/^\d+$/.test(rep[1])) count = parseInt(rep[1], 10) * inner;
            else {
                var px = /minmax\(\s*([\d.]+)(px|rem|em)/i.exec(rep[2]) || /^([\d.]+)(px|rem|em)/i.exec(trim(rep[2]));
                if (!px) return 0;
                var minPx = parseFloat(px[1]) * (px[2] === 'px' ? 1 : 16);
                count = Math.max(1, Math.floor((width - 32) / Math.max(minPx, 40)));
            }
            // tracks before/after the repeat()
            var rest = t.replace(rep[0], ' ');
            count += splitWS(trim(rest)).length;
        } else {
            count = splitWS(t).length;
        }
        // 6+ explicit tracks (12-column systems) are used with spans: stacking the children beats twelve narrow columns
        var autoRepeat = rep && !/^\d+$/.test(rep[1]);
        if (count < 2 || (!autoRepeat && count >= 6)) { if (key) ctx.gridSels[key] = 1; return wasColumns ? -1 : 0; }
        count = Math.min(count, 8);
        if (key) ctx.gridSels[key] = count;
        return count;
    }

    // A fixed row height a grid container rule asks for ("grid-auto-rows: 100px", "minmax(6rem, auto)", "repeat(3, 100px)"),
    // or null. Only rules that are (or were) grid containers count.
    function gridRowHeight(decls, ctx, key) {
        var isGrid = false, rows = null;
        for (var i = 0; i < decls.length; i++) {
            var p = decls[i].p, v = decls[i].v;
            if (p === 'display' && /^(inline-)?grid$/i.test(trim(v))) isGrid = true;
            else if (p === 'grid-auto-rows' || p === 'grid-template-rows') rows = v;
            else if (p === 'grid-template' && v.indexOf('/') >= 0) rows = v.slice(0, v.indexOf('/'));
        }
        if (!rows || (!isGrid && !(ctx.gridSels && ctx.gridSels[key] > 0))) return null;
        rows = resolveVars(rows, null, ctx);
        if (rows === null) return null;
        var t = trim(trim(rows).toLowerCase().replace(/\[[^\]]*\]/g, ' ').replace(/\s+/g, ' '));
        var LEN = '([\\d.]+(?:px|rem|em|vh|vw))';
        // one track, repeat(N, track) or minmax(track, ...) forms; a list of different tracks is not one row height
        var m = new RegExp('^' + LEN + '$').exec(t) ||
                new RegExp('^repeat\\( ?(?:\\d+|auto-fill|auto-fit) ?, ?' + LEN + ' ?\\)$').exec(t) ||
                new RegExp('^minmax\\( ?' + LEN + ' ?,[^)]*\\)$').exec(t) ||
                new RegExp('^repeat\\( ?(?:\\d+|auto-fill|auto-fit) ?, ?minmax\\( ?' + LEN + ' ?,[^)]*\\) ?\\)$').exec(t);
        return m ? m[1] : null;
    }

    // What a flex container rule asks for that the 2009 box model cannot do by itself: wrapping and gaps.
    function flexContainerInfo(decls, ctx) {
        var info = { flex: false, wrap: false, column: false, rowGap: null, colGap: null, justify: null };
        for (var i = 0; i < decls.length; i++) {
            var p = decls[i].p, v = resolveVars(decls[i].v, null, ctx);
            if (v === null) continue;
            var lv = trim(v).toLowerCase();
            if (p === 'display' && /^(inline-)?flex$/.test(lv)) info.flex = true;
            else if ((p === 'flex-wrap' || p === 'flex-flow') && /wrap/.test(lv) && !/nowrap/.test(lv)) info.wrap = true;
            else if ((p === 'flex-direction' || p === 'flex-flow') && /column/.test(lv)) info.column = true;
            else if (p === 'gap') { var g = splitWS(lv); info.rowGap = g[0]; info.colGap = g.length > 1 ? g[1] : g[0]; }
            else if (p === 'row-gap') info.rowGap = lv;
            else if (p === 'column-gap') info.colGap = lv;
            else if (p === 'justify-content') info.justify = lv;
        }
        if (info.rowGap === '0' || info.rowGap === '0px' || info.rowGap === 'normal') info.rowGap = null;
        if (info.colGap === '0' || info.colGap === '0px' || info.colGap === 'normal') info.colGap = null;
        return info;
    }

    function halfLength(v) {
        var m = /^([\d.]+)([a-z%]*)$/i.exec(v);
        return m ? (Math.round(parseFloat(m[1]) * 50) / 100) + m[2] : v;
    }

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
                if (!keyframe) {
                    var fi = flexContainerInfo(r.decls, ctx);
                    if (fi.flex) {
                        var childSel = [], gapSel = [], gs;
                        for (gs = 0; gs < sels.length; gs++) { childSel.push(sels[gs] + ' > *'); gapSel.push(sels[gs] + ' > * + *'); }
                        if (fi.wrap && !fi.column) {
                            // wrapping rows: inline-blocks wrap like flex items sized by their content; justify-content becomes text-align
                            var wrapDecls = [{ p: 'display', v: 'inline-block', imp: false }, { p: 'vertical-align', v: 'top', imp: false }];
                            if (fi.rowGap || fi.colGap) wrapDecls.push({ p: 'margin', v: halfLength(fi.rowGap || '0') + ' ' + halfLength(fi.colGap || '0'), imp: false });
                            out.push({ t: 'q', sel: childSel.join(','), decls: wrapDecls });
                            var ta = fi.justify === 'center' ? 'center' : (fi.justify === 'flex-end' || fi.justify === 'end' || fi.justify === 'right') ? 'right' :
                                     (fi.justify === 'space-between' || fi.justify === 'space-around' || fi.justify === 'space-evenly') ? 'justify' : null;
                            if (ta) out.push({ t: 'q', sel: sels.join(','), decls: [{ p: 'text-align', v: ta, imp: false }] });
                        } else if (fi.column && fi.rowGap) {
                            out.push({ t: 'q', sel: gapSel.join(','), decls: [{ p: 'margin-top', v: fi.rowGap, imp: false }] });
                        } else if (!fi.column && fi.colGap) {
                            out.push({ t: 'q', sel: gapSel.join(','), decls: [{ p: 'margin-left', v: fi.colGap, imp: false }] });
                        }
                    }
                    var gridKey = sels.join(',');
                    var columns = gridColumns(r.decls, ctx, gridKey);
                    var rowHeight = gridRowHeight(r.decls, ctx, gridKey);
                    if (rowHeight) {
                        // fixed row tracks (grid-auto-rows: 120px, minmax(120px, auto), repeat(3, 8rem)): the children get that minimum height
                        var rowSels = [];
                        for (var rh = 0; rh < sels.length; rh++) rowSels.push(sels[rh] + ' > *');
                        out.push({ t: 'q', sel: rowSels.join(','), decls: [{ p: 'min-height', v: rowHeight, imp: false }] });
                    }
                    if (columns === -1) {
                        // the same container goes back to a single column (a media query): the floats are undone
                        var resetSels = [];
                        for (var rs = 0; rs < sels.length; rs++) resetSels.push(sels[rs] + ' > *');
                        out.push({ t: 'q', sel: resetSels.join(','), decls: [{ p: 'float', v: 'none', imp: false }, { p: 'width', v: 'auto', imp: false }, { p: 'margin-right', v: '0', imp: false }] });
                    } else if (columns > 1) {
                        // CSS grid does not exist here: the children float into equal columns instead of piling up;
                        // a column gap is taken out of the widths, a row gap becomes a bottom margin
                        var childSels = [], afterSels = [], lastSels = [];
                        for (var gs = 0; gs < sels.length; gs++) { childSels.push(sels[gs] + ' > *'); afterSels.push(sels[gs] + '::after'); lastSels.push(sels[gs] + ' > *:nth-child(' + columns + 'n)'); }
                        var gaps = gridGaps(r.decls, ctx), colGap = gaps[1], rowGap = gaps[0];
                        var pct = (Math.floor(10000 / columns) / 100) + '%';
                        var childDecls = [{ p: 'float', v: 'left', imp: false }];
                        var total = colGap ? timesLength(colGap, columns - 1) : null;
                        if (total) childDecls.push({ p: 'width', v: '-webkit-calc((100% - ' + total + ') / ' + columns + ')', imp: false });
                        else childDecls.push({ p: 'width', v: pct, imp: false });
                        childDecls.push({ p: '-webkit-box-sizing', v: 'border-box', imp: false }, { p: 'box-sizing', v: 'border-box', imp: false }, { p: 'min-width', v: '0', imp: false });
                        if (total) childDecls.push({ p: 'margin-right', v: colGap, imp: false });
                        if (rowGap) childDecls.push({ p: 'margin-bottom', v: rowGap, imp: false });
                        out.push({ t: 'q', sel: childSels.join(','), decls: childDecls });
                        if (total) out.push({ t: 'q', sel: lastSels.join(','), decls: [{ p: 'margin-right', v: '0', imp: false }] });
                        out.push({ t: 'q', sel: afterSels.join(','), decls: [{ p: 'content', v: '""', imp: false }, { p: 'display', v: 'block', imp: false }, { p: 'clear', v: 'both', imp: false }] });
                    }
                }
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
            } else if (name === 'container') {
                // "@container [name] (cond) { rules }": the rules become descendants of ".br-cq-<hash>", a class the
                // page shim puts on container elements (marked by container-type) whose size satisfies the condition
                if (r.rules && g_manifest !== false) {
                    var cqm = /^([a-zA-Z_][\w-]*)?\s*([\s\S]*)$/.exec(trim(r.prelude));
                    var cqName = cqm && cqm[1] && !/^(not|and|or)$/i.test(cqm[1]) ? cqm[1] : '', cqCond = cqm ? trim(cqm[1] && cqName ? cqm[2] : r.prelude) : r.prelude;
                    var cqh = manifestHash(cqName + '|' + cqCond);
                    manifestAdd('cq', { h: cqh, name: cqName, cond: cqCond });
                    sub = transformRules(r.rules, ctx, keyframe);
                    prefixRules(sub, '.br-cq-' + cqh + ' ');
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

    // every style rule (also inside nested at-rules) gets `prefix` before each of its selectors
    function prefixRules(rules, prefix) {
        for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.t === 'q') {
                var parts = splitTop(r.sel, ','), sels = [];
                for (var k = 0; k < parts.length; k++) sels.push(prefix + trim(parts[k]));
                r.sel = sels.join(',');
            } else if (r.t === 'at' && r.rules && r.name !== '-webkit-keyframes' && r.name !== 'keyframes') prefixRules(r.rules, prefix);
        }
    }

    function makeContext(pageVars) {
        var page = {};
        if (pageVars) {
            if (typeof pageVars === 'string') { try { pageVars = JSON.parse(pageVars); } catch (e) { pageVars = null; } }
            if (pageVars && typeof pageVars === 'object') for (var k in pageVars) if (pageVars.hasOwnProperty(k)) page[k] = pageVars[k];
        }
        return { page: page, root: {}, other: {}, initial: {} };
    }

    function fixCSS(text, ctx) {
        var clean = stripComments(text);
        var rules = [];
        parseRules(clean, 0, clean.length, rules);
        rules = flattenNesting(rules);
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
            if (!opts || !opts.transpile) return all;
            if (ltype === 'importmap') return open.replace(/\btype\s*=\s*("importmap"|'importmap'|importmap)/i, 'type="systemjs-importmap"') + body + close;
            if (!isJavaScriptType(type)) return all;
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

    // Consent dialogs of the common cookie-banner services: hidden, and the scroll lock they put on the page lifted.
    // Only container ids/classes those services generate themselves are listed (no generic words).
    var COOKIE_BANNER_CSS =
        '#onetrust-consent-sdk,#onetrust-banner-sdk,.onetrust-pc-dark-filter,#didomi-host,#didomi-popup,.didomi-popup-backdrop,.didomi-popup-container,' +
        '#CybotCookiebotDialog,#CybotCookiebotDialogBodyUnderlay,#cookiescript_injected,#cookiescript_injected_wrapper,.qc-cmp2-container,#qc-cmp2-container,' +
        '.qc-cmp-ui-container,[id^="sp_message_container_"],#cmpbox,#cmpbox2,.cmpboxBG,#usercentrics-root,#usercentrics-cmp-ui,#iubenda-cs-banner,' +
        '.iubenda-cs-container,#BorlabsCookieBox,#truste-consent-track,.truste_overlay,.truste_box_overlay,#consent_blackbar,#cookie-law-info-bar,' +
        '#cookie-law-info-again,#moove_gdpr_cookie_info_bar,#catapult-cookie-bar,#cookieChoiceInfo,.cc-window.cc-banner,.cc-window.cc-floating,' +
        '#CookieConsent,#cookieconsent,.js-consent-banner,#gdpr-cookie-message,#cookie-notice,#cookie-consent-banner,#cookie_consent_banner,' +
        '.szn-cmp-dialog-container,#szn-cmp-dialog-container,szn-cmp-dialog,.cpex-cmp,#cpexCmp,.seznam-cmp,[id^="sp_message_iframe_"],' +
        '#cookiebanner,#cookieBanner,.cookie-banner,#cookie-bar,#cookieBar,.cookie-bar,#cookies-banner,.cookies-banner,#cookie-modal,.cookie-modal,' +
        '#cookie-popup,.cookie-popup,#cookieNotice,.cookieNotice,#cookie-message,.cookie-message,#cookies-consent,.cookies-consent,#cookie-consent,.cookie-consent' +
        '{display:none !important;visibility:hidden !important}' +
        'html.didomi-popup-open,body.didomi-popup-open,html.sp-message-open,body.sp-message-open,body.cmp-body-lock,body.onetrust-noscroll,' +
        'html.cookiebot-open,body.cookie-modal-open,body.cc-modal-open,body.qc-cmp-ui-showing,html.qc-cmp-ui-showing,body.cmp-open,html.cmp-open' +
        '{overflow:auto !important;position:static !important;height:auto !important}';

    function injectCookieBannerCSS(html) {
        if (!/<html|<head|<body/i.test(html)) return html;
        var tag = '<style id="br-cookie-banners">' + COOKIE_BANNER_CSS + '</style>';
        var m = /<\/head\s*>/i.exec(html);
        if (m) return html.slice(0, m.index) + tag + html.slice(m.index);
        m = /<body\b[^>]*>/i.exec(html);
        if (m) return html.slice(0, m.index + m[0].length) + tag + html.slice(m.index + m[0].length);
        return html + tag;
    }

    function fixHTML(html, ctx, opts) {
        var styleRe = /(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>)/gi;
        // 1. collect variables from every <style> block first (they usually hold the theme)
        var m;
        while ((m = styleRe.exec(html)) !== null) {
            var clean = stripComments(m[2]);
            var rules = [];
            parseRules(clean, 0, clean.length, rules);
            collectVars(flattenNesting(rules), ctx, false);
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
        if (opts && opts.hideCookieBanners) html = injectCookieBannerCSS(html);
        return html;
    }

    function run(kind, text, pageVars, options) {
        var ctx = makeContext(pageVars);
        var opts = null;
        if (options) {
            if (typeof options === 'string') { try { opts = JSON.parse(options); } catch (e) { opts = null; } }
            else opts = options;
        }
        if (opts && opts.viewportWidth > 0) ctx.viewportWidth = opts.viewportWidth;
        g_viewportWidth = (opts && opts.viewportWidth > 0) ? opts.viewportWidth : 768;
        g_viewportHeight = (opts && opts.viewportHeight > 0) ? opts.viewportHeight : Math.round(g_viewportWidth * 4 / 3);
        g_manifest = null;
        var out = kind === 'html' ? fixHTML(text, ctx, opts) : fixCSS(text, ctx);
        var manifest = null;
        if (g_manifest && (g_manifest.has.length || g_manifest.cq.length)) {
            manifest = { has: g_manifest.has, cq: g_manifest.cq };
            // the entries ride along in the output (so a cached copy keeps them); "*/" cannot occur inside
            var json = JSON.stringify(manifest).replace(/\*\//g, '*\\/');
            out += kind === 'html' ? '\n<!--br-manifest:' + json.replace(/--/g, '-\\u002d') + '-->' : '\n/*br-manifest:' + json + '*/';
        }
        g_manifest = null;
        return JSON.stringify({ out: out, vars: ctx.root, manifest: manifest });
    }

    // the manifest comment of a rewritten document or stylesheet, parsed (used by the shim's dev harness and tests)
    function readManifest(text) {
        var m = /br-manifest:(\{[\s\S]*?\})(?:\*\/|-->)\s*$/.exec(text);
        if (!m) return null;
        try { return JSON.parse(m[1]); } catch (e) { return null; }
    }

    return { run: run, fixCSS: fixCSS, fixHTML: fixHTML, fixInlineStyle: fixInlineStyle, makeContext: makeContext, evalSupports: evalSupports,
             fixSelectorList: fixSelectorList, fixMedia: fixMedia, transformFunctions: transformFunctions, parseColor: parseColor, readManifest: readManifest };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = CSSFix;
