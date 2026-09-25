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
    process.exit(failed ? 1 : 0);
})();
