// (the worker of tools/worker-url-test.html)
var r = [];
try { console.log('from the worker'); r.push('console ok'); } catch (e) { r.push('console FAIL'); }
try { r.push(typeof performance.now() === 'number' ? 'performance ok' : 'performance FAIL'); } catch (e2) { r.push('performance FAIL'); }
try { r.push(new TextEncoder().encode('é').length === 2 ? 'TextEncoder ok' : 'TextEncoder FAIL'); } catch (e3) { r.push('TextEncoder FAIL'); }
r.push(location.hash === '#params=abc' ? 'hash ok' : 'hash FAIL ' + location.hash);
postMessage(r.join(', '));
