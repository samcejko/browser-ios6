/*
 * RegExp flags and syntax the old engine refuses, for pages (polyfill bundle, before shims-extra.js) and for workers
 * (worker-polyfills.js): see the comment below. G is the global object of either.
 */
(function (G) {
// ---- RegExp flags and syntax the engine refuses. new RegExp(pattern, flags) asks the engine first; what it rejects
// is lowered: s (the dot matches everything), u and v (\u{...}, \p{...} and astral characters become surrogate
// pairs: the Unicode tables and jsfix.js are loaded once when a pattern needs them, otherwise the flag just goes),
// named groups (numbered; .groups on the results), y (exec/test only match at lastIndex) and d (.indices).
// Such expressions carry __brRe, and String.prototype.match/replace/matchAll go through their exec (as ES2015
// does), so .groups, $<name> and sticky matching work there too. The flag getters and RegExp.escape are added.
(function () {
    var Native = G.RegExp;
    if (!Native || Native.__brFlags) return;
    var proto = Native.prototype, nativeExec = proto.exec, hasOwnR = Object.prototype.hasOwnProperty;
    var nativeReplace = String.prototype.replace, nativeMatch = String.prototype.match;
    var hidden = function (o, k, v) { try { Object.defineProperty(o, k, { value: v, writable: true, configurable: true }); } catch (e) { o[k] = v; } };
    var ORDER = 'dgimsuvy';
    var flagsOf = function (re) {
        if (re.__brRe && re.__brRe.flags !== undefined) return re.__brRe.flags;
        return (re.global ? 'g' : '') + (re.ignoreCase ? 'i' : '') + (re.multiline ? 'm' : '');
    };
    // jsfix.js (and the Unicode tables for \p{...}) from the app, once
    var unicodeLowering = function (tables) {
        var load = function (name) {
            var x = new XMLHttpRequest();
            x.open('GET', 'https://ios6-browser.invalid/' + name, false);
            x.send(null);
            if (x.status === 200 && x.responseText) (0, eval)(x.responseText);
        };
        try {
            if (tables && !G.JSFIX_UNICODE && !unicodeLowering.triedTables) { unicodeLowering.triedTables = true; load('unicode-props.js'); }
            if (!G.JSFix && !unicodeLowering.tried) { unicodeLowering.tried = true; load('jsfix.js'); }
        } catch (e) {}
        return !!(G.JSFix && G.JSFix.lowerUnicode);
    };
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
    // named groups: the names go, \k<name> becomes a numbered backreference; name -> group number(s)
    var namedGroups = function (p) {
        var names = {}, count = 0, out = '', inClass = false, i, c, e, k;
        for (i = 0; i < p.length; i++) {
            c = p.charAt(i);
            if (c === '\\') {
                if (!inClass && p.charAt(i + 1) === 'k' && p.charAt(i + 2) === '<') {
                    e = p.indexOf('>', i);
                    k = e > 0 ? p.slice(i + 3, e) : '';
                    if (e > 0 && hasOwnR.call(names, k)) { out += '\\' + (typeof names[k] === 'number' ? names[k] : names[k][0]); i = e; continue; }
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
                    k = p.slice(i + 3, e);
                    // (duplicate names in alternatives: the first group that took part)
                    if (hasOwnR.call(names, k)) names[k] = [].concat(names[k], count); else names[k] = count;
                    out += '(';
                    i = e;
                    continue;
                }
            }
            out += c;
        }
        return { pattern: out, names: names };
    };
    // what makes a u pattern differ from the same pattern without u: \p{...}, \u{...}, astral characters, and the
    // dot (which takes a whole surrogate pair)
    var NEEDS_UNICODE = /\\[pP]\{|\\u\{|[\ud800-\udfff]/;
    var hasDot = function (p) {
        var inClass = false;
        for (var i = 0; i < p.length; i++) {
            var c = p.charAt(i);
            if (c === '\\') { i++; continue; }
            if (inClass) { if (c === ']') inClass = false; continue; }
            if (c === '[') inClass = true;
            else if (c === '.') return true;
        }
        return false;
    };
    // A lookbehind at the very start of the pattern, (?<=X)rest or (?<!X)rest, with no alternation after it and no
    // groups of its own: {neg, behind: X, rest} (the engine has no lookbehind at all; the rest is searched and X tested
    // against the text before each candidate), else null. Other lookbehinds are not lowered.
    var leadingLookbehind = function (p) {
        if (!/^\(\?<[=!]/.test(p)) return null;
        var depth = 0, inClass = false, i, c, close = -1;
        for (i = 0; i < p.length; i++) {
            c = p.charAt(i);
            if (c === '\\') { i++; continue; }
            if (inClass) { if (c === ']') inClass = false; continue; }
            if (c === '[') { inClass = true; continue; }
            if (c === '(') depth++;
            else if (c === ')') { depth--; if (!depth) { close = i; break; } }
        }
        if (close < 0) return null;
        var behind = p.slice(4, close), rest = p.slice(close + 1);
        // (groups of its own would shift the numbers; alternatives after it would lose it; a second lookbehind)
        if (/\((?!\?)/.test(behind.replace(/\\./g, '')) || /\(\?<[=!]/.test(rest)) return null;
        depth = 0; inClass = false;
        for (i = 0; i < rest.length; i++) {
            c = rest.charAt(i);
            if (c === '\\') { i++; continue; }
            if (inClass) { if (c === ']') inClass = false; continue; }
            if (c === '[') inClass = true;
            else if (c === '(') depth++;
            else if (c === ')') depth--;
            else if (c === '|' && !depth) return null;
        }
        return { neg: p.charAt(3) === '!', behind: behind, rest: rest };
    };
    // {pattern, flags (for the engine), info} or null when it cannot be lowered
    var lower = function (source, flags) {
        var p = source, all = '', i, c, names = null, lb = null;
        for (i = 0; i < flags.length; i++) {
            c = flags.charAt(i);
            if (ORDER.indexOf(c) < 0 || all.indexOf(c) >= 0) return null;
            all += c;
        }
        var has = function (f) { return all.indexOf(f) >= 0; };
        if (has('u') && has('v')) return null;
        if (/\(\?<[=!]/.test(p)) {
            lb = leadingLookbehind(p);
            if (!lb) return null;
            p = lb.rest;
        }
        var unicode = function (q) {
            if (!(has('u') || has('v')) || !(NEEDS_UNICODE.test(q) || hasDot(q))) return q;
            if (!unicodeLowering(/\\[pP]\{/.test(q))) return null;
            try { return G.JSFix.lowerUnicode(q); } catch (e) { return null; }
        };
        if (has('s')) p = dotAll(p);
        if (/\(\?<[A-Za-z_$]/.test(p)) { var r = namedGroups(p); p = r.pattern; names = r.names; }
        p = unicode(p);
        if (p === null) return null;
        var behind = null;
        if (lb) {
            behind = unicode(has('s') ? dotAll(lb.behind) : lb.behind);
            if (behind === null) return null;
            // (without a quantifier that repeats without end, what it matches is short: only the last 256 characters
            // before a candidate are tested)
            behind = { re: new Native('(?:' + behind + ')$', has('i') ? 'i' : ''), neg: lb.neg, bounded: !/[*+]|\{\d*,\}/.test(behind.replace(/\\./g, '')) };
        }
        var sorted = '';
        for (i = 0; i < ORDER.length; i++) if (has(ORDER.charAt(i))) sorted += ORDER.charAt(i);
        return { pattern: p, flags: (has('g') ? 'g' : '') + (has('i') ? 'i' : '') + (has('m') ? 'm' : ''),
                 info: { source: source, flags: sorted, names: names, sticky: has('y'), indices: has('d'), behind: behind } };
    };
    var groupsOf = function (m, names) {
        var g = {};
        for (var k in names) if (hasOwnR.call(names, k)) {
            var n = names[k];
            if (typeof n === 'number') { g[k] = m[n]; continue; }
            g[k] = undefined;
            for (var j = 0; j < n.length; j++) if (m[n[j]] !== undefined) { g[k] = m[n[j]]; break; }
        }
        return g;
    };
    // (until an expression with its own exec exists, String.prototype.match/replace/split go straight to the engine:
    // every replace of a page, 220,000 on nextjs.org, looked the property up on its expression)
    var anyLowered = false;
    hidden(G, '__brNoteLowered', function () { anyLowered = true; });
    var decorate = function (re, l) {
        var info = l.info, anchored = null, scan = null, behind = info.behind;
        hidden(re, '__brRe', info);
        if (info.names || info.sticky || info.indices || behind) anyLowered = true;
        // a leading lookbehind: candidates of the rest, each kept when the text before it does (not) end in X
        if (behind) scan = new Native(l.pattern, l.flags.indexOf('g') >= 0 ? l.flags : l.flags + 'g');
        // sticky: (?:pattern)|() always matches at lastIndex; the empty alternative taking it means no match there
        else if (info.sticky) anchored = new Native('(?:' + l.pattern + ')|()', l.flags.indexOf('g') >= 0 ? l.flags : l.flags + 'g');
        if (!anchored && !scan && !info.names && !info.indices) return re;
        hidden(re, 'exec', function (s) {
            s = String(s);
            var m;
            if (scan) {
                var moving = this.global || info.sticky, from = moving ? this.lastIndex : 0, c;
                m = null;
                while (from <= s.length) {
                    scan.lastIndex = from;
                    c = nativeExec.call(scan, s);
                    if (!c || (info.sticky && c.index !== from)) break;
                    if (behind.re.test(s.slice(behind.bounded ? Math.max(0, c.index - 256) : 0, c.index)) !== behind.neg) { m = c; break; }
                    if (info.sticky) break;
                    from = c.index + 1;
                }
                if (moving) this.lastIndex = m ? m.index + m[0].length : 0;
                if (!m) return null;
            } else if (anchored) {
                anchored.lastIndex = this.lastIndex;
                m = nativeExec.call(anchored, s);
                if (!m || m[m.length - 1] !== undefined) { this.lastIndex = 0; return null; }
                m.length--;
                this.lastIndex = anchored.lastIndex;
            } else m = nativeExec.call(this, s);
            if (!m) return m;
            if (info.names) m.groups = groupsOf(m, info.names);
            if (info.indices) {
                // (group positions: the first occurrence of the group's text within the match)
                var ind = [[m.index, m.index + m[0].length]];
                for (var i = 1; i < m.length; i++) {
                    var at = m[i] === undefined ? -1 : m[0].indexOf(m[i]);
                    ind.push(at < 0 ? undefined : [m.index + at, m.index + at + m[i].length]);
                }
                if (info.names) ind.groups = groupsOf(ind, info.names);
                m.indices = ind;
            }
            return m;
        });
        hidden(re, 'test', function (s) { return this.exec(s) !== null; });
        return re;
    };
    // (debugging, BRDebugJSErrors: a pattern the engine refuses even after lowering goes to the app's log)
    var logRefused = function (e, source, f) {
        if (!G.__brDebugErrors || !G.document) return;
        try {
            var fr = G.document.createElement('iframe');
            fr.style.display = 'none';
            fr.src = 'brlog:' + encodeURIComponent('RegExp refused (' + e.message + '): /' + String(source).slice(0, 400) + '/' + f);
            (G.document.body || G.document.documentElement).appendChild(fr);
            setTimeout(function () { if (fr.parentNode) fr.parentNode.removeChild(fr); }, 100);
        } catch (x) {}
    };
    var BRRegExp = function RegExp(pattern, flags) {
        var isRe = pattern instanceof Native;
        if (!(this instanceof BRRegExp) && isRe && flags === undefined) return pattern;   // RegExp(re) is re
        var source = isRe ? (pattern.__brRe ? pattern.__brRe.source : pattern.source) : pattern === undefined ? '' : String(pattern);
        var f = flags === undefined ? (isRe ? flagsOf(pattern) : '') : String(flags);
        try { return new Native(source, f); } catch (e) {
            if (!(e instanceof SyntaxError)) throw e;
            var l = lower(source, f);
            if (!l) { logRefused(e, source, f); throw e; }
            try { return decorate(new Native(l.pattern, l.flags), l); } catch (e2) { logRefused(e2, source, f); throw e2; }
        }
    };
    BRRegExp.prototype = proto;
    hidden(proto, 'constructor', BRRegExp);
    hidden(BRRegExp, '__brFlags', true);
    // the legacy statics ($1..$9, lastMatch...) stay the engine's
    var statics = ['$1', '$2', '$3', '$4', '$5', '$6', '$7', '$8', '$9', 'input', '$_', 'lastMatch', '$&', 'lastParen', '$+', 'leftContext', '$`', 'rightContext', "$'", 'multiline', '$*'];
    for (var si = 0; si < statics.length; si++) (function (k) {
        try { Object.defineProperty(BRRegExp, k, { get: function () { return Native[k]; }, set: function (v) { try { Native[k] = v; } catch (e) {} }, configurable: true }); } catch (e) {}
    })(statics[si]);
    if (!BRRegExp.escape) hidden(BRRegExp, 'escape', function escape(s) {
        if (typeof s !== 'string') throw new TypeError('RegExp.escape requires a string');
        var out = '', hex = function (c, w) { var h = c.toString(16); while (h.length < w) h = '0' + h; return h; };
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i), c = s.charCodeAt(i);
            if (i === 0 && /[0-9A-Za-z]/.test(ch)) { out += '\\x' + hex(c, 2); continue; }
            if ('^$\\.*+?()[]{}|/'.indexOf(ch) >= 0) { out += '\\' + ch; continue; }
            var ctl = { 9: 't', 10: 'n', 11: 'v', 12: 'f', 13: 'r' }[c];
            if (ctl) { out += '\\' + ctl; continue; }
            var lone = c >= 0xD800 && c <= 0xDFFF && !(c <= 0xDBFF && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xDC00 && s.charCodeAt(i + 1) <= 0xDFFF) &&
                       !(c >= 0xDC00 && i > 0 && s.charCodeAt(i - 1) >= 0xD800 && s.charCodeAt(i - 1) <= 0xDBFF);
            if (",-=<>#&!%:;@~'`\"".indexOf(ch) >= 0 || /\s/.test(ch) || lone) { out += c <= 0xFF ? '\\x' + hex(c, 2) : '\\u' + hex(c, 4); continue; }
            out += ch;
        }
        return out;
    });
    var getter = function (name, fn) {
        if (name in proto) return;
        try { Object.defineProperty(proto, name, { get: fn, configurable: true }); } catch (e) {}
    };
    var flagGetter = function (f) { return function () { return flagsOf(this).indexOf(f) >= 0; }; };
    getter('flags', function () { return flagsOf(this); });
    getter('sticky', flagGetter('y'));
    getter('unicode', flagGetter('u'));
    getter('unicodeSets', flagGetter('v'));
    getter('dotAll', flagGetter('s'));
    getter('hasIndices', flagGetter('d'));
    try { G.RegExp = BRRegExp; } catch (e) { return; }

    // String methods over lowered expressions: through their exec, as ES2015 specifies
    // (only expressions whose exec does more than the engine's: named groups, sticky, indices, a lookbehind; a
    // pattern that only lost its u or s flag is matched by the engine itself)
    var isLowered = function (re) {
        if (typeof re !== 'object' || re === null) return false;
        var i = re.__brRe;
        return i !== undefined && !!(i.names || i.sticky || i.indices || i.behind);
    };
    var substitute = function (text, m, s, pos) {
        if (text.indexOf('$') < 0) return text;
        return nativeReplace.call(text, /\$([$&`']|\d\d?|<[^>]*>)/g, function (all, t) {
            if (t === '$') return '$';
            if (t === '&') return m[0];
            if (t === '`') return s.slice(0, pos);
            if (t === "'") return s.slice(pos + m[0].length);
            if (t.charAt(0) === '<') { if (!m.groups) return all; var v = m.groups[t.slice(1, -1)]; return v === undefined ? '' : String(v); }
            var n = parseInt(t, 10), caps = m.length - 1;
            if (n >= 1 && n <= caps) return m[n] === undefined ? '' : m[n];
            if (t.length === 2) { var n1 = parseInt(t.charAt(0), 10); if (n1 >= 1 && n1 <= caps) return (m[n1] === undefined ? '' : m[n1]) + t.charAt(1); }
            return all;
        });
    };
    String.prototype.match = function match(re) {
        'use strict';
        if (!anyLowered || !isLowered(re) || this === null || this === undefined) return nativeMatch.apply(this, arguments);
        var s = String(this);
        if (!re.global) return re.exec(s);
        var all = [], m;
        re.lastIndex = 0;
        while ((m = re.exec(s))) { all.push(m[0]); if (m[0] === '') re.lastIndex++; }
        return all.length ? all : null;
    };
    String.prototype.replace = function replace(re, rep) {
        'use strict';
        if (!anyLowered || !isLowered(re) || this === null || this === undefined) return nativeReplace.apply(this, arguments);
        var s = String(this), found = [], m, i;
        if (re.global) re.lastIndex = 0;
        while ((m = re.exec(s))) {
            found.push(m);
            if (!re.global) break;
            if (m[0] === '') re.lastIndex++;
        }
        var out = '', next = 0, fn = typeof rep === 'function', text = fn ? '' : String(rep);
        for (i = 0; i < found.length; i++) {
            m = found[i];
            var pos = m.index, r;
            if (fn) {
                var args = Array.prototype.slice.call(m);
                args.push(pos, s);
                if (m.groups) args.push(m.groups);
                r = String(rep.apply(undefined, args));
            } else r = substitute(text, m, s, pos);
            if (pos >= next) { out += s.slice(next, pos) + r; next = pos + m[0].length; }
        }
        return out + s.slice(next);
    };
    // split by a lowered expression (a lookbehind's is only right through its exec): the ES2015 algorithm, with a
    // global search standing in for the sticky one (a match found further on is the sticky match at that position)
    var nativeSplit = String.prototype.split;
    String.prototype.split = function split(sep, limit) {
        'use strict';
        if (!anyLowered || !isLowered(sep) || this === null || this === undefined) return nativeSplit.apply(this, arguments);
        var s = String(this), out = [], lim = limit === undefined ? 4294967295 : limit >>> 0;
        if (!lim) return out;
        var rx = new BRRegExp(sep.__brRe.source, sep.__brRe.flags.replace(/[gy]/g, '') + 'g'), m, p = 0, q = 0, e, i;
        if (!s.length) return rx.exec(s) ? out : [s];
        while (q < s.length) {
            rx.lastIndex = q;
            m = rx.exec(s);
            if (!m || m.index >= s.length) break;
            e = m.index + m[0].length;
            if (e === p) { q = m.index + 1; continue; }
            out.push(s.slice(p, m.index));
            if (out.length === lim) return out;
            for (i = 1; i < m.length; i++) { out.push(m[i]); if (out.length === lim) return out; }
            p = q = e;
        }
        out.push(s.slice(p));
        return out;
    };
    if (!String.prototype.matchAll) {
        hidden(String.prototype, 'matchAll', function matchAll(re) {
            'use strict';
            if (this === null || this === undefined) throw new TypeError('String.prototype.matchAll called on null or undefined');
            var s = String(this), rx;
            if (re instanceof Native) {
                var fl = flagsOf(re);
                if (fl.indexOf('g') < 0) throw new TypeError('String.prototype.matchAll called with a non-global RegExp argument');
                rx = new BRRegExp(re, fl);
                rx.lastIndex = re.lastIndex;
            } else rx = new BRRegExp(re === undefined ? '' : String(re), 'g');
            var done = false, it = {
                next: function () {
                    var m = done ? null : rx.exec(s);
                    if (!m) { done = true; return { value: undefined, done: true }; }
                    if (m[0] === '') rx.lastIndex++;
                    return { value: m, done: false };
                }
            };
            if (G.Symbol && Symbol.iterator) it[Symbol.iterator] = function () { return this; };
            it['@@iterator'] = function () { return this; };
            return it;
        });
    }
    // test through the expression's exec when a script put another one there, as ES2015 has it: a page's own core-js
    // checks exactly that and, failing, put a test written in JS (an exec and a match array per call) on every
    // regular expression of the page. Ordinary ones still take the engine's test.
    var nativeTest = proto.test;
    hidden(proto, 'test', function test(s) {
        var ex = this.exec;
        if (ex === nativeExec || typeof ex !== 'function') return nativeTest.call(this, s);
        var r = ex.call(this, String(s));
        if (r !== null && typeof r !== 'object') throw new TypeError('The result of exec must be an object or null');
        return r !== null;
    });
})();
})(typeof window !== 'undefined' ? window : this);
