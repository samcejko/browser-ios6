// Patches object-fit-images 3.2.4 (downloaded by the build) for the iOS 6 engine; fails when the text changed.
//   node tools/patch-ofi.js Resources/js/object-fit-images.js
var fs = require('fs');
var file = process.argv[2];
var s = fs.readFileSync(file, 'utf8');

function replace(from, to) {
    if (s.indexOf(from) < 0) {
        console.error('patch-ofi: not found: ' + from);
        process.exit(1);
    }
    s = s.split(from).join(to);
}

// Its wait for a picture's size polled every 100 ms forever when the picture had no address yet (lazy pictures:
// dozens of endless timers on YouTube); the shim gives the copy its address when the picture loads (the attribute:
// an empty src property reads as the page's own address).
replace('setTimeout(n,100,t,e)', 't.getAttribute("src")&&setTimeout(n,100,t,e)');
// The placeholder comes from the shim (window.__brOfiPH in shims-extra.js): the library's SVG placeholder made
// WebKit skip the element's background, which carries the picture.
replace('var n=t(i||1,r||0)', 'var n=window.__brOfiPH?window.__brOfiPH(e,i||1,r||0):t(i||1,r||0)');

fs.writeFileSync(file, s);
console.log('patch-ofi: ' + file + ' patched (' + s.length + ' bytes)');
