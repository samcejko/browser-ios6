// Runs tools/jsfix-cases.js against Resources/jsfix.js in node (CI): every case, run as written and as lowered by
// JSFix.transpile, must give the same result, and the lowered text must be ES5 without function declarations inside
// blocks of strict code (the iOS 6 JavaScriptCore refuses both).
// Usage: node tools/jsfix-ci.js   (needs the acorn package)
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const acorn = require('acorn');

const ctx = vm.createContext({ acorn, JSFIX_UNICODE: require('./gen-unicode.js')() });
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Resources', 'jsfix.js'), 'utf8'), ctx, { filename: 'jsfix.js' });
vm.runInContext(fs.readFileSync(path.join(__dirname, 'jsfix-cases.js'), 'utf8'), ctx, { filename: 'jsfix-cases.js' });
const JSFix = ctx.JSFix;
const cases = ctx.JSFIX_CASES;

function nestedStrictFunctions(ast) {
    let count = 0;
    (function walk(node, inBlock, strict) {
        if (!node || typeof node.type !== 'string') return;
        if (node.type === 'Program' || node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression') {
            const body = node.type === 'Program' ? node.body : (node.body && node.body.body) || [];
            const s = strict || (body[0] && body[0].type === 'ExpressionStatement' && body[0].directive === 'use strict');
            for (const st of body) walk(st, false, s);
            return;
        }
        for (const key of Object.keys(node)) {
            const v = node[key];
            const childInBlock = inBlock || node.type === 'BlockStatement' || node.type === 'SwitchCase';
            const visit = (c) => {
                if (c && typeof c.type === 'string') {
                    if (c.type === 'FunctionDeclaration' && childInBlock && strict) count++;
                    walk(c, childInBlock, strict);
                }
            };
            if (Array.isArray(v)) v.forEach(visit); else visit(v);
        }
    })(ast, false, false);
    return count;
}

const run = (code) => vm.runInContext('(function () {' + code + '\n})()', vm.createContext({}));

// A webpack chunk with big factories keeps them for later: the skeleton is ES5, its stubs ask __br_lazy, and a factory
// lowered on its own (as the app does for /lazy/<key>/<n>.js) behaves like the original.
function lazyCheck() {
    const pad = (kb) => '/*' + 'x'.repeat(kb * 1024) + '*/';
    const chunk = '(self.webpackChunk_t=self.webpackChunk_t||[]).push([[1],{' +
        '11:(e,t,n)=>{' + pad(60) + 'e.exports={sum:(...a)=>a.reduce((x,y)=>x+y,0),Cls:class{constructor(v){this.v=v}get d(){return this.v*2}},re:/[}{]`/g.source}},' +
        '12:(e,t,n)=>{e.exports=`small ${1+1} }`},' +
        '"./x.js":function(e){' + pad(200) + 'e.exports=[..."ab"].join("-")}}]);';
    const out = JSFix.run(chunk, JSON.stringify({ url: 'https://x/c.js', lazy: 'k-1', force: true }));
    if (!/^\/\*br-lazy:2:k-1\*\//.test(out)) throw new Error('no lazy skeleton: ' + JSFix.last() + ' ' + out.slice(0, 80));
    acorn.parse(out, { ecmaVersion: 5 });
    const parts = JSON.parse(JSFix.lazy());
    const g = vm.createContext({});
    g.self = g;
    g.__br_lazy = function (k, t, a) {
        const i = +k.split('/')[1], part = chunk.slice(parts[i][0], parts[i][1]), wrapped = 'var __br_lazyValue=(' + part + '\n);';
        const low = JSFix.run(wrapped, '{"force":true}') || wrapped;
        acorn.parse(low, { ecmaVersion: 5 });
        return vm.runInContext('(function(){' + low + '\n;return __br_lazyValue;})()', g).apply(t, a);
    };
    vm.runInContext(out, g);
    const mods = g.webpackChunk_t[0][1], req = (id) => { const m = { exports: {} }; mods[id].call(m.exports, m, m.exports, null); return m.exports; };
    const a = req(11), b = req(12), c = req('./x.js');
    const got = JSON.stringify([a.sum(1, 2, 3), new a.Cls(2).d, a.re, b, c, Object.keys(mods)]);
    const want = JSON.stringify([6, 4, '[}{]`', 'small 2 }', 'a-b', ['11', '12', './x.js']]);
    if (got !== want) throw new Error('expected ' + want + ' got ' + got);
}
// A script the engine takes as it is keeps its text, except `delete el.dataset.x` (the old engine throws in strict code
// when there is no such attribute): through the helper; one with such text inside a string stays as it is.
function datasetCheck() {
    const src = "'use strict';var el={dataset:{a:1,b:2,c:{r:1}}},k='b';delete el.dataset.a;var r=!delete el.dataset[k];" +
        'delete el.dataset.c.r;var result=[Object.keys(el.dataset).join(),r,Object.keys(el.dataset.c).length];';
    const out = JSFix.run(src, '{}');
    if (!/__br_dsdel\(el,"a"\)/.test(out) || !/__br_dsdel\(el,\(k\)\)/.test(out) || !/delete el\.dataset\.c\.r/.test(out)) throw new Error('not through the helper: ' + JSFix.last() + ' ' + out);
    acorn.parse(out, { ecmaVersion: 5 });
    const g = vm.createContext({});
    vm.runInContext(out, g);
    const got = JSON.stringify(g.result), want = JSON.stringify(['c', false, 0]);
    if (got !== want) throw new Error('expected ' + want + ' got ' + got);
    const inString = JSFix.run("'use strict';var s=\"delete x.dataset.y\";delete el.dataset.a;", '{}');
    if (inString !== '') throw new Error('a string was changed: ' + inString);
    if (JSFix.run('var a={b:1};delete a.b;', '{}') !== '') throw new Error('an ES5 script without dataset was changed');
}
// A big row of statements with no room for all of it at once goes a group at a time (jsfix.js pieces): the same result
// and ES5 text; a group with a let in a block at its top gives up (as without room). The engine's check is ES5 here.
function piecesCheck() {
    ctx.__brES5Parses = (code) => { try { acorn.parse(code, { ecmaVersion: 5 }); return true; } catch (e) { return false; } };
    try {
        const pad = 'x'.repeat(12 * 1024);
        let src = 'var log = [];\n';
        for (let i = 0; i < 40; i++) src += '(self.q = self.q || []).push([' + i + ', (a = ' + i + ') => ({ v: a * 2, s: `t' + i + '`, p: "' + pad + '".length })]);\n';
        src += 'log.push(self.q.map(function (e) { return e[1]().v + e[1]().s; }).join());\n';
        const shape = JSFix.shape(src, '{}');
        if (shape !== 'pieces') throw new Error('shape ' + JSON.stringify(shape));
        const out = JSFix.run(src, '{}');
        if (!out || !/^pieces:/.test(JSFix.note())) throw new Error('not in pieces: ' + JSFix.last() + ' ' + JSFix.note());
        acorn.parse(out, { ecmaVersion: 5 });
        const a = vm.createContext({}), b = vm.createContext({});
        a.self = a; b.self = b;
        vm.runInContext(src, a);
        vm.runInContext(out, b);
        if (JSON.stringify(a.log) !== JSON.stringify(b.log)) throw new Error('expected ' + JSON.stringify(a.log) + ' got ' + JSON.stringify(b.log));
        const bad = src + '{ let z = 1; log.push(() => z); }\n';
        JSFix.shape(bad, '{}');
        if (JSFix.run(bad, '{}') !== '' || !/memory/.test(JSFix.last())) throw new Error('a let in a block at the top went through: ' + JSFix.last());
    } finally { delete ctx.__brES5Parses; }
}
const settle = (v) => (v && typeof v.then === 'function')
    ? v.then((x) => JSON.stringify(x), (e) => 'rejected: ' + ((e && e.message) || e))
    : Promise.resolve(JSON.stringify(v));

// every case twice: as a small script (the whole tree at once) and with every function lowered while parsing (the
// mode of scripts over 96 KB)
const MODES = [['', {}], [' (early)', { early: 0 }]];
(async () => {
    let failed = 0;
    for (const [mode, opts] of MODES) for (const [caseName, code] of cases) {
        const name = caseName + mode;
        let expected, out, actual;
        try { expected = await settle(run(code)); } catch (e) { console.error(`FAIL ${name}: original threw ${e.message}`); failed++; continue; }
        try { out = JSFix.transpile(code, opts); } catch (e) { console.error(`FAIL ${name}: transpile threw ${e.message || e.what}`); failed++; continue; }
        if (out === null) out = code;
        try {
            acorn.parse(out, { ecmaVersion: 5, allowReturnOutsideFunction: true });
            if (nestedStrictFunctions(acorn.parse(out, { ecmaVersion: 2015, allowReturnOutsideFunction: true }))) throw new Error('function declaration in a block of strict code');
        } catch (e) { console.error(`FAIL ${name}: not ES5: ${e.message}`); failed++; continue; }
        try { actual = await settle(run(out)); } catch (e) { console.error(`FAIL ${name}: lowered threw ${e.message}`); failed++; continue; }
        if (actual !== expected) { console.error(`FAIL ${name}: expected ${expected} got ${actual}`); failed++; continue; }
    }
    console.log(`jsfix: ${cases.length * MODES.length - failed}/${cases.length * MODES.length} cases pass (${JSFix.stats.early} functions lowered while parsing, ${JSFix.stats.fallbacks} fallbacks)`);
    try { lazyCheck(); console.log('jsfix: lazy factories pass'); } catch (e) { console.error('FAIL lazy factories: ' + (e.message || e)); failed++; }
    try { datasetCheck(); console.log('jsfix: dataset deletes in ES5 scripts pass'); } catch (e) { console.error('FAIL dataset deletes: ' + (e.message || e)); failed++; }
    try { piecesCheck(); console.log('jsfix: pieces pass'); } catch (e) { console.error('FAIL pieces: ' + (e.message || e)); failed++; }
    process.exit(failed ? 1 : 0);
})();
