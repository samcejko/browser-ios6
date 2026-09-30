// Runs in a worker for workershims-test.html: the browser's own TextEncoder/TextDecoder/AbortController kept aside and
// taken away, worker-shims.js loaded, the results posted back.
var NTE = self.TextEncoder, NTD = self.TextDecoder, NAC = self.AbortController;
delete self.TextEncoder; delete self.TextDecoder; delete self.AbortController; delete self.AbortSignal;
var results = [];
var check = function (name, ok, info) { results.push((ok ? 'PASS ' : 'FAIL ') + name + (!ok && info !== undefined ? ' (' + info + ')' : '')); };
try { importScripts('../Resources/worker-shims.js'); } catch (e) { check('load', false, String(e)); }
check('installed', self.TextDecoder && self.TextDecoder !== NTD && self.AbortController && self.AbortController !== NAC && self.WebSocket.__brLocal === true);
// a Czech text cut inside its characters, decoded as a stream
var bytes = new NTE().encode('﻿Příliš žluťoučký kůň 😀'), d = new TextDecoder(), out = '';
for (var i = 0; i < bytes.length; i += 3) out += d.decode(bytes.subarray(i, i + 3), { stream: true });
out += d.decode();
check('streamed decode', out === 'Příliš žluťoučký kůň 😀', out);
check('encode', Array.prototype.join.call(new TextEncoder().encode('ř\ud800'), ',') === Array.prototype.join.call(new NTE().encode('ř\ud800'), ','));
var c = new AbortController(), heard = 0;
c.signal.addEventListener('abort', function () { heard++; });
c.abort();
check('AbortController', heard === 1 && c.signal.reason && c.signal.reason.name === 'AbortError');
try {
    var w = new WebSocket('/br-no-socket');
    check('WebSocket relative URL', w.url === 'ws://' + location.host + '/br-no-socket', w.url);
    w.onerror = function () {};
    w.close();
    var w2 = new WebSocket('sock');
    check('WebSocket path-relative URL', w2.url === 'ws://' + location.host + '/tools/sock', w2.url);
    w2.onerror = function () {};
    w2.close();
} catch (e) { check('WebSocket', false, String(e)); }
postMessage(results);
