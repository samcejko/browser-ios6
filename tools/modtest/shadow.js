import { u as e } from './utils.js';
// a function around a function lowered while parsing declares the imported name again (minified bundles, denik.cz)
var extend = function () {
    var e = function (t, r) { return e = Object.setPrototypeOf || function (o, p) { o.__proto__ = p; return o; }, e(t, r); };
    return function (t, r) { e(t, r); return typeof Object.getPrototypeOf(t); };
}();
export var shadow = [e, extend({}, {}), typeof e].join(',');
