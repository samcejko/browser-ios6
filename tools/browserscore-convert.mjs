// Flattens the feature definitions of browserscore/features (MIT, Lea Verou and contributors) into plain
// test lists that the ES5 runner Resources/browserscore.js can evaluate on the iOS 6 engine.
//
// Node (CI):   node tools/browserscore-convert.mjs <clone of browserscore/features> Resources/js/browserscore-features.js
// Browser:     import { convertAll } from './browserscore-convert.mjs' (see tools/browserscore-dev.html)
//
// The shapes mirror browserscore/app (Feature.js and the Feature/* classes) and browserscore/supports:
// a feature has an optional gating test (the property, the @-rule, the global itself) and leaf tests
// (values, preludes, descriptors, members). A feature with neither gets its own single test.
//
// Test shapes (k = kind):
//   {k:'prop', p}                     property recognised
//   {k:'val', p, v}                   value accepted for a property
//   {k:'sel', s}                      selector parses
//   {k:'at', code, contents, parent, before}   @-rule (code includes the prelude) parses; contents string | false
//   {k:'desc', at, d}                 descriptor recognised inside the @-rule `at`
//   {k:'descval', at, d, v}           descriptor value accepted
//   {k:'mq', q}                       media query recognised
//   {k:'global', g}                   global exists
//   {k:'member', g, m, path, fn}      member on the global (path '' or 'prototype'); fn: must be a function
//   {k:'extends', g, s}               global's prototype chain reaches s
//   {k:'instanceof', g, c}            global is an instance of c

// browserscore/supports src/types/css/type.js
export const dataTypes = {
	length: { name: 'width' },
	percentage: { name: 'width' },
	time: { name: 'transition-duration' },
	angle: { name: 'transform', wrap: v => `rotate(${v})` },
	integer: { name: 'z-index' },
	number: { name: 'line-height' },
	resolution: { name: 'image-resolution' },
	image: { name: 'background-image' },
	url: { name: 'background-image' },
	string: { name: 'content' },
	'custom-ident': { name: 'animation-name' },
	color: { name: 'color' },
	'length-percentage': { name: 'width' },
};

function toArray (x) {
	if (x === undefined || x === null) return [];
	return Array.isArray(x) ? x : [x];
}

// tests / values given as an array of strings, an object keyed by value, or a single string
function listValues (def) {
	const out = [];
	for (const key of ['tests', 'values']) {
		const t = def[key];
		if (!t) continue;
		if (Array.isArray(t)) for (const v of t) { if (typeof v === 'string') out.push(v); else if (v && v.value) out.push(v.value); else if (v && v.id) out.push(v.id); }
		else if (typeof t === 'string') out.push(t);
		else if (typeof t === 'object') for (const k of Object.keys(t)) out.push(k);
	}
	if (def.value !== undefined && typeof def.value === 'string') out.push(def.value);
	return out;
}

// A property entry. `children` lists concrete properties of a template such as "border-<side>-radius"
// (strings, or an object of property -> def); they inherit the parent's values (Feature._createChildren).
function propertyFeature (prop, def, features, inheritedValues) {
	def = typeof def === 'object' && def ? def : {};
	let values = listValues(def);
	if (!values.length && inheritedValues) values = inheritedValues;
	if (def.children) {
		const kids = Array.isArray(def.children)
			? def.children.map(c => (typeof c === 'string' ? [c, {}] : [c.id || c.value || prop, c]))
			: Object.entries(def.children);
		for (const [kidProp, kidDef] of kids) {
			const merged = { ...def, ...(kidDef || {}) };
			delete merged.children;
			delete merged.isGroup;
			if (kidDef && kidDef.children) merged.children = kidDef.children;
			propertyFeature(kidProp, merged, features, values);
		}
		return;
	}
	const feature = { type: 'properties', code: prop, gate: { k: 'prop', p: prop }, tests: [] };
	for (const v of values) feature.tests.push({ k: 'val', p: prop, v });
	features.push(feature);
}

function convertProperties (group, features) {
	for (const [prop, rawDef] of Object.entries(group)) {
		if (prop === 'properties') continue;
		propertyFeature(prop, rawDef, features, null);
	}
}

// the value a feature or child tests with (CSSValueFeature.value / Feature.testValue)
function valueTests (id, def, fnName) {
	const fn = /\(\)$/.test(id) ? id : fnName;
	if (def.args) return toArray(def.args).map(arg => fn ? fn.replace(/\(\)$/, `(${arg})`) : arg);
	const explicit = listValues(def);
	if (explicit.length) return explicit;
	return [id];
}

function convertValues (group, features) {
	const groupProps = Array.isArray(group.properties) ? group.properties : null;
	for (const [name, rawDef] of Object.entries(group)) {
		if (name === 'properties') continue;
		const def = typeof rawDef === 'object' && rawDef ? rawDef : {};
		const feature = { type: 'values', code: name, gate: null, tests: [] };
		const targets = (childDef) => {
			const props = childDef.properties || def.properties || groupProps;
			if (props) return props.map(p => ({ name: p }));
			const t = childDef.dataType || def.dataType;
			return dataTypes[t] ? [dataTypes[t]] : [];
		};
		const add = (values, childDef) => {
			for (const target of targets(childDef)) {
				for (const v of values) feature.tests.push({ k: 'val', p: target.name, v: target.wrap ? target.wrap(v) : v });
			}
		};
		if (def.children) {
			const kids = Array.isArray(def.children)
				? def.children.map(c => (typeof c === 'string' ? { id: c } : c))
				: Object.entries(def.children).map(([id, d]) => ({ ...(d || {}), id }));
			for (const kid of kids) {
				const kidId = kid.id || kid.value || name;
				add(valueTests(kidId, kid, /\(\)$/.test(kidId) ? kidId : name), kid);
			}
		}
		else {
			add(valueTests(name, def, name), def);
		}
		if (feature.tests.length) features.push(feature);
	}
}

function convertUnits (group, features) {
	for (const [unit, rawDef] of Object.entries(group)) {
		const def = rawDef || {};
		const target = dataTypes[def.dataType || 'length'];
		if (!target) continue;
		features.push({ type: 'units', code: unit, gate: null, tests: [{ k: 'val', p: target.name, v: target.wrap ? target.wrap('1' + unit) : '1' + unit }] });
	}
}

function convertSelectors (group, features) {
	for (const [sel, rawDef] of Object.entries(group)) {
		const def = typeof rawDef === 'object' && rawDef ? rawDef : {};
		const tests = toArray(def.tests).filter(t => typeof t === 'string');
		features.push({ type: 'selectors', code: sel, gate: null, tests: (tests.length ? tests : [sel]).map(s => ({ k: 'sel', s })) });
	}
}

function atruleCode (name, prelude) {
	const base = name.replace(/^@?/, '@');
	return prelude ? base + ' ' + prelude : base;
}

function convertAtrule (name, def, features, parentCode, inheritedPrelude, inheritedContents) {
	def = def || {};
	const prelude = def.prelude !== undefined ? def.prelude : (inheritedPrelude || '');
	const contents = def.contents !== undefined ? def.contents : inheritedContents;
	const code = atruleCode(name, prelude);
	const before = def.contentBefore;
	const feature = { type: 'atrules', code, gate: null, tests: [] };
	const gating = !def.preludeRequired || Boolean(prelude);
	if (gating && !def.isGroup) feature.gate = { k: 'at', code, contents, parent: parentCode, before };
	for (const p of toArray(def.preludes)) feature.tests.push({ k: 'at', code: atruleCode(name, p), contents, parent: parentCode, before });
	if (def.children) {
		const kids = Array.isArray(def.children) ? def.children : Object.entries(def.children).map(([id, d]) => ({ ...(d || {}), prelude: id }));
		for (const kid of kids) {
			const k = typeof kid === 'string' ? { prelude: kid } : kid;
			const kidPrelude = k.prelude !== undefined ? k.prelude : prelude;
			const kidContents = k.contents !== undefined ? k.contents : contents;
			feature.tests.push({ k: 'at', code: atruleCode(name, kidPrelude), contents: kidContents, parent: parentCode, before });
		}
	}
	if (def.descriptors) {
		const list = Array.isArray(def.descriptors) ? def.descriptors.map(d => [d, {}]) : Object.entries(def.descriptors);
		for (const [d, ddef] of list) {
			feature.tests.push({ k: 'desc', at: code, d });
			for (const v of listValues(ddef || {})) feature.tests.push({ k: 'descval', at: code, d, v });
		}
	}
	if (def.atrules) {
		for (const [n2, d2] of Object.entries(def.atrules)) {
			const inner = d2 || {};
			feature.tests.push({ k: 'at', code: atruleCode(n2, inner.prelude || ''), contents: inner.contents, parent: code, before: inner.contentBefore });
		}
	}
	if (!feature.gate && !feature.tests.length) feature.tests.push({ k: 'at', code, contents, parent: parentCode, before });
	features.push(feature);
}

function convertAtrules (group, features) {
	for (const [name, def] of Object.entries(group)) convertAtrule(name, def, features, undefined, undefined, undefined);
}

function convertMediaQueries (group, features) {
	for (const [name, rawDef] of Object.entries(group)) {
		const def = typeof rawDef === 'object' && rawDef ? rawDef : {};
		const tests = toArray(def.tests).filter(t => typeof t === 'string');
		features.push({ type: 'mediaqueries', code: name, gate: null, tests: (tests.length ? tests : [name]).map(q => ({ k: 'mq', q })) });
	}
}

function convertGlobals (group, features) {
	for (const [g, rawDef] of Object.entries(group)) {
		const def = typeof rawDef === 'object' && rawDef ? rawDef : {};
		const feature = { type: 'globals', code: g, gate: { k: 'global', g }, tests: [] };
		const members = (list, path, fn) => { for (const m of toArray(list)) if (typeof m === 'string') feature.tests.push({ k: 'member', g, m, path, fn }); };
		members(def.tests, 'prototype', false);
		members(def.members, 'prototype', false);
		members(def.methods, 'prototype', true);
		members(def.properties, '', false);
		members(def.functions, '', true);
		for (const s of toArray(def.extends)) if (typeof s === 'string') feature.tests.push({ k: 'extends', g, s });
		for (const c of toArray(def.instanceof)) if (typeof c === 'string') feature.tests.push({ k: 'instanceof', g, c });
		features.push(feature);
	}
}

const converters = {
	properties: convertProperties,
	values: convertValues,
	units: convertUnits,
	selectors: convertSelectors,
	atrules: convertAtrules,
	mediaqueries: convertMediaQueries,
	globals: convertGlobals,
};

export function convertSpec (spec) {
	const out = { id: spec.id, title: spec.title || spec.id, status: spec.status || '', group: spec.group || 'csswg', features: [] };
	for (const type of Object.keys(converters)) {
		if (spec[type] && typeof spec[type] === 'object') converters[type](spec[type], out.features);
	}
	out.total = out.features.reduce((n, f) => n + (f.gate ? 1 : 0) + f.tests.length, 0);
	return out;
}

export function convertAll (specs) {
	const list = [];
	for (const key of Object.keys(specs)) {
		const spec = specs[key];
		if (!spec || typeof spec !== 'object' || !spec.id) continue;
		list.push(convertSpec(spec));
	}
	list.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
	return list;
}

// Node entry point
if (typeof process !== 'undefined' && process.argv && process.argv[1] && /browserscore-convert\.mjs$/.test(process.argv[1])) {
	const [, , repoDir, outFile] = process.argv;
	if (!repoDir || !outFile) {
		console.error('usage: node tools/browserscore-convert.mjs <features repo> <output .js>');
		process.exit(2);
	}
	const { pathToFileURL } = await import('node:url');
	const { writeFileSync } = await import('node:fs');
	const path = await import('node:path');
	const specs = await import(pathToFileURL(path.resolve(repoDir, 'specs.js')).href);
	const data = convertAll(specs);
	const tests = data.reduce((n, s) => n + s.total, 0);
	writeFileSync(outFile, 'window.BROWSERSCORE_FEATURES=' + JSON.stringify(data) + ';\n');
	console.log(`browserscore features: ${data.length} specs, ${tests} tests -> ${outFile}`);
}
