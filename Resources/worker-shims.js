/*
 * What a worker scope of the old engine lacks and page scripts expect there (served with core-js, regenerator and
 * fetch as https://ios6-browser.invalid/worker-polyfills.js; the Worker shim of shims-extra.js imports it into blob
 * workers): TextEncoder / TextDecoder, crypto.getRandomValues and crypto.subtle.digest (SHA-1, SHA-256; proof of
 * work pages hash in workers).
 */
(function (self) {
    'use strict';
    if (!self.TextEncoder) {
        var utf8 = function (str) {
            var out = [], i, c, c2;
            for (i = 0; i < str.length; i++) {
                c = str.charCodeAt(i);
                if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length && (c2 = str.charCodeAt(i + 1)) >= 0xDC00 && c2 <= 0xDFFF) {
                    c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                    i++;
                } else if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
                if (c < 0x80) out.push(c);
                else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
                else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
                else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            }
            return out;
        };
        self.TextEncoder = function TextEncoder() { this.encoding = 'utf-8'; };
        self.TextEncoder.prototype.encode = function (str) { return new Uint8Array(utf8(str === undefined ? '' : String(str))); };
        self.TextEncoder.prototype.encodeInto = function (str, dest) {
            var bytes = utf8(String(str)), n = Math.min(bytes.length, dest.length);
            for (var i = 0; i < n; i++) dest[i] = bytes[i];
            return { read: String(str).length, written: n };
        };
        self.TextDecoder = function TextDecoder(label, options) {
            this.encoding = String(label || 'utf-8').toLowerCase().replace('utf8', 'utf-8');
            this.fatal = !!(options && options.fatal);
            this.ignoreBOM = !!(options && options.ignoreBOM);
        };
        self.TextDecoder.prototype.decode = function (input) {
            if (!input) return '';
            var b = input instanceof Uint8Array ? input : input.buffer ? new Uint8Array(input.buffer, input.byteOffset || 0, input.byteLength) : new Uint8Array(input);
            var out = '', i = 0, c, n, cp;
            if (this.encoding !== 'utf-8') {
                for (i = 0; i < b.length; i++) out += String.fromCharCode(b[i]);
                return out;
            }
            if (!this.ignoreBOM && b.length >= 3 && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF) i = 3;
            var chunk = [];
            for (; i < b.length; i++) {
                c = b[i];
                if (c < 0x80) { cp = c; n = 0; } else if (c >= 0xF0) { cp = c & 7; n = 3; } else if (c >= 0xE0) { cp = c & 15; n = 2; } else if (c >= 0xC0) { cp = c & 31; n = 1; } else { cp = 0xFFFD; n = 0; }
                for (var k = 0; k < n; k++) {
                    var nb = b[i + 1];
                    if (nb === undefined || (nb & 0xC0) !== 0x80) { cp = 0xFFFD; break; }
                    cp = (cp << 6) | (nb & 63);
                    i++;
                }
                if (cp === 0xFFFD && this.fatal) throw new TypeError('The encoded data was not valid');
                if (cp > 0xFFFF) { cp -= 0x10000; chunk.push(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)); } else chunk.push(cp);
                if (chunk.length > 4096) { out += String.fromCharCode.apply(null, chunk); chunk = []; }
            }
            return out + String.fromCharCode.apply(null, chunk);
        };
    }
    var crypto = self.crypto;
    if (!crypto) { crypto = {}; try { self.crypto = crypto; } catch (e) {} }
    if (!crypto.getRandomValues) crypto.getRandomValues = function (arr) { for (var i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256); return arr; };
    if (!crypto.subtle && self.Promise) {
        var rotr = function (x, n) { return (x >>> n) | (x << (32 - n)); };
        var rotl = function (x, n) { return (x << n) | (x >>> (32 - n)); };
        var pad = function (bytes) {
            var l = bytes.length, len = ((l + 9 + 63) >> 6) << 6, msg = new Uint8Array(len), bits = l * 8, hi = Math.floor(bits / 4294967296), lo = bits >>> 0;
            msg.set(bytes);
            msg[l] = 0x80;
            msg[len - 8] = (hi >>> 24) & 255; msg[len - 7] = (hi >>> 16) & 255; msg[len - 6] = (hi >>> 8) & 255; msg[len - 5] = hi & 255;
            msg[len - 4] = (lo >>> 24) & 255; msg[len - 3] = (lo >>> 16) & 255; msg[len - 2] = (lo >>> 8) & 255; msg[len - 1] = lo & 255;
            return msg;
        };
        var words = function (msg, off, w) { for (var i = 0; i < 16; i++) w[i] = (msg[off + i * 4] << 24) | (msg[off + i * 4 + 1] << 16) | (msg[off + i * 4 + 2] << 8) | msg[off + i * 4 + 3]; };
        var bytesOf = function (H) { var out = new Uint8Array(H.length * 4); for (var i = 0; i < H.length; i++) { out[i * 4] = H[i] >>> 24; out[i * 4 + 1] = (H[i] >>> 16) & 255; out[i * 4 + 2] = (H[i] >>> 8) & 255; out[i * 4 + 3] = H[i] & 255; } return out; };
        var K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
                 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
                 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
                 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
        var sha256 = function (bytes) {
            var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19], msg = pad(bytes), w = new Array(64), i;
            for (var off = 0; off < msg.length; off += 64) {
                words(msg, off, w);
                for (i = 16; i < 64; i++) w[i] = (w[i - 16] + (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) + w[i - 7] + (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10))) | 0;
                var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
                for (i = 0; i < 64; i++) {
                    var t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0;
                    var t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
                    h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
                }
                H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
                H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
            }
            return bytesOf(H);
        };
        var sha1 = function (bytes) {
            var H = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0], msg = pad(bytes), w = new Array(80), i;
            for (var off = 0; off < msg.length; off += 64) {
                words(msg, off, w);
                for (i = 16; i < 80; i++) w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
                var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4];
                for (i = 0; i < 80; i++) {
                    var f = i < 20 ? (b & c) | (~b & d) : i < 40 ? b ^ c ^ d : i < 60 ? (b & c) | (b & d) | (c & d) : b ^ c ^ d;
                    var k = i < 20 ? 0x5A827999 : i < 40 ? 0x6ED9EBA1 : i < 60 ? 0x8F1BBCDC : 0xCA62C1D6;
                    var t = (rotl(a, 5) + f + e + k + w[i]) | 0;
                    e = d; d = c; c = rotl(b, 30); b = a; a = t;
                }
                H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0; H[4] = (H[4] + e) | 0;
            }
            return bytesOf(H);
        };
        var toBytes = function (data) {
            if (data instanceof ArrayBuffer) return new Uint8Array(data);
            if (data && data.buffer instanceof ArrayBuffer) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
            return new Uint8Array(0);
        };
        var unsupported = function () { return self.Promise.reject(new Error('NotSupportedError: this operation is not available')); };
        crypto.subtle = {
            digest: function (algorithm, data) {
                var name = String(typeof algorithm === 'string' ? algorithm : (algorithm && algorithm.name) || '').toUpperCase().replace('-', '');
                try {
                    if (name === 'SHA256') return self.Promise.resolve(sha256(toBytes(data)).buffer);
                    if (name === 'SHA1') return self.Promise.resolve(sha1(toBytes(data)).buffer);
                } catch (e) { return self.Promise.reject(e); }
                return unsupported();
            },
            encrypt: unsupported, decrypt: unsupported, sign: unsupported, verify: unsupported, generateKey: unsupported, deriveKey: unsupported,
            deriveBits: unsupported, importKey: unsupported, exportKey: unsupported, wrapKey: unsupported, unwrapKey: unsupported
        };
    }
})(typeof self !== 'undefined' ? self : this);
