/* reader.js - extracts the main article of the current page (a small readability heuristic).
 * Evaluated by the app; returns JSON {title, byline, html, url} or an empty string when no article
 * was found. ES5 only. */
(function () {
    'use strict';
    var doc = document;
    function textLength(el) { return (el.textContent || '').replace(/\s+/g, ' ').length; }
    function linkDensity(el) {
        var links = el.getElementsByTagName('a'), linkText = 0;
        for (var i = 0; i < links.length; i++) linkText += textLength(links[i]);
        var total = textLength(el);
        return total ? linkText / total : 0;
    }
    var NEGATIVE = /comment|footer|footnote|header|menu|nav|sidebar|share|social|sponsor|widget|promo|related|breadcrumb|cookie|banner|advert|ad-|-ad|popup|modal|newsletter|login|subscribe/i;
    var POSITIVE = /article|body|content|entry|main|page|post|text|story|blog|column/i;

    // Paragraph text per element (descendants included), then the smallest element that still holds the article
    function paragraphText(el) {
        var paragraphs = el.getElementsByTagName('p'), text = 0, longParas = 0;
        for (var p = 0; p < paragraphs.length; p++) {
            var len = textLength(paragraphs[p]);
            text += len;
            if (len > 80) longParas++;
        }
        return { text: text, longParas: longParas };
    }
    function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
    function words(s) { var m = String(s).match(/\S+/g); return m ? m.length : 0; }
    // the article as the page describes it for search engines (JSON-LD articleBody): plain text, paragraphs by line
    function structuredArticle() {
        var scripts = doc.querySelectorAll('script[type="application/ld+json"]'), found = null;
        var visit = function (o, depth) {
            if (!o || typeof o !== 'object' || depth > 4 || found) return;
            if (o instanceof Array) { for (var k = 0; k < o.length; k++) visit(o[k], depth + 1); return; }
            var type = String(o['@type'] || '');
            if (/Article|BlogPosting|Report|NewsArticle/.test(type) && typeof o.articleBody === 'string' && o.articleBody.length > 500) { found = o; return; }
            if (o['@graph']) visit(o['@graph'], depth + 1);
            if (o.mainEntity) visit(o.mainEntity, depth + 1);
        };
        for (var s = 0; s < scripts.length && !found; s++) {
            try { visit(JSON.parse(scripts[s].textContent || ''), 0); } catch (e) {}
        }
        if (!found) return null;
        var paras = found.articleBody.replace(/\r/g, '').split(/\n+/), out = '';
        for (var q = 0; q < paras.length; q++) { var t = paras[q].replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, ''); if (t) out += '<p>' + esc(t) + '</p>'; }
        var author = found.author, name = '';
        if (author instanceof Array) author = author[0];
        if (author) name = typeof author === 'string' ? author : (author.name || '');
        return { title: String(found.headline || found.name || ''), byline: String(name), html: out, text: found.articleBody };
    }
    var structured = null;
    try { structured = structuredArticle(); } catch (eS) { structured = null; }
    var fromStructured = function () {
        if (!structured) return '';
        return JSON.stringify({ title: (structured.title || doc.title || '').replace(/\s+/g, ' ').slice(0, 300), byline: structured.byline.slice(0, 120),
                                html: structured.html, url: location.href, minutes: Math.max(1, Math.round(words(structured.text) / 200)) });
    };
    var candidates = [], all = doc.body ? doc.body.getElementsByTagName('*') : [];
    for (var i = 0; i < all.length; i++) {
        var el = all[i], tag = el.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NAV' || tag === 'HEADER' || tag === 'FOOTER' || tag === 'ASIDE' || tag === 'FORM' || tag === 'P') continue;
        var pt = paragraphText(el);
        if (pt.longParas < 2) continue;
        var score = pt.text * (1 - linkDensity(el));
        var idClass = (el.id || '') + ' ' + (el.className || '');
        if (NEGATIVE.test(idClass)) score *= 0.4;
        if (POSITIVE.test(idClass)) score *= 1.3;
        if (tag === 'ARTICLE' || tag === 'MAIN') score *= 1.5;
        candidates.push({ el: el, score: score, text: pt.text });
    }
    if (!candidates.length) return fromStructured();
    candidates.sort(function (a, b) { return b.score - a.score; });
    var best = candidates[0].el;
    // descend while one child still holds nearly all of the paragraph text (drops page wrappers)
    for (var guard = 0; guard < 30; guard++) {
        var total = paragraphText(best).text, next = null;
        for (var c = 0; c < best.children.length; c++) {
            var child = best.children[c];
            if (child.tagName === 'P') continue;
            if (paragraphText(child).text >= total * 0.85) { next = child; break; }
        }
        if (!next) break;
        best = next;
    }

    var clone = best.cloneNode(true);
    var junk = clone.querySelectorAll('script,style,iframe,frame,frameset,object,embed,applet,base,link,meta,template,form,input,button,select,textarea,nav,aside,footer,noscript,svg,video,audio,canvas,[hidden],[aria-hidden="true"]');
    for (i = junk.length - 1; i >= 0; i--) if (junk[i].parentNode) junk[i].parentNode.removeChild(junk[i]);
    var blocks = clone.querySelectorAll('div,section,ul,ol,table,figure,p,span,a');
    for (i = blocks.length - 1; i >= 0; i--) {
        var b = blocks[i];
        if (!b.parentNode) continue;
        var idc = (b.id || '') + ' ' + (b.className || '');
        var t = b.tagName;
        if (t !== 'P' && t !== 'A' && t !== 'SPAN' && NEGATIVE.test(idc) && textLength(b) < 400) { b.parentNode.removeChild(b); continue; }
        if ((t === 'DIV' || t === 'SECTION') && textLength(b) === 0 && !b.getElementsByTagName('img').length) { b.parentNode.removeChild(b); continue; }
        if (t !== 'P' && t !== 'A' && t !== 'SPAN' && linkDensity(b) > 0.5 && textLength(b) < 300) { b.parentNode.removeChild(b); continue; }
    }
    // links and pictures keep absolute http(s) addresses only (pictures data:image too): no javascript: or data:
    // documents, and nothing that the reader page's own address would resolve differently
    var resolver = doc.createElement('a');
    var safeURL = function (v, image) {
        v = String(v).replace(/^\s+|\s+$/g, '');
        if (image && /^data:image\//i.test(v)) return v;
        resolver.href = v;
        return /^https?:\/\//i.test(resolver.href) ? resolver.href : '';
    };
    // strip attributes that carry site styling or behaviour (a static copy: removals must not skip elements)
    var nodes = Array.prototype.slice.call(clone.getElementsByTagName('*'));
    for (i = 0; i < nodes.length; i++) {
        var n = nodes[i], attrs = n.attributes, keep = { href: 1, src: 1, alt: 1, title: 1, colspan: 1, rowspan: 1 };
        if (n.tagName === 'IMG') {
            // lazy-loaded images: the real picture is in srcset or data-src, src is only a placeholder
            var src = n.getAttribute('src') || '';
            var placeholder = !src || /^data:/.test(src) || /1x1|pixel|spacer|blank|placeholder/.test(src);
            var real = n.getAttribute('data-src') || n.getAttribute('data-original') || n.getAttribute('data-lazy-src') || '';
            var srcset = n.getAttribute('srcset') || n.getAttribute('data-srcset') || '';
            if (srcset) {
                var bestURL = '', bestW = 0, parts = srcset.split(',');
                for (var s = 0; s < parts.length; s++) {
                    var m = /^\s*(\S+)\s*(?:(\d+)w)?/.exec(parts[s]);
                    if (!m) continue;
                    var w = m[2] ? parseInt(m[2], 10) : 800;
                    if (w <= 1100 && w > bestW) { bestW = w; bestURL = m[1]; }
                }
                if (bestURL && (placeholder || bestW > 400)) real = bestURL;
            }
            if (real) { n.setAttribute('src', real); src = real; placeholder = false; }
            if (placeholder) { if (n.parentNode) n.parentNode.removeChild(n); continue; }
        }
        for (var a = attrs.length - 1; a >= 0; a--) {
            var an = attrs[a].name;
            if (!keep[an]) { n.removeAttribute(an); continue; }
            if (an === 'href' || an === 'src') {
                var safe = safeURL(attrs[a].value, n.tagName === 'IMG' && an === 'src');
                if (safe) n.setAttribute(an, safe); else n.removeAttribute(an);
            }
        }
    }
    var titleEl = doc.querySelector('h1') || doc.querySelector('meta[property="og:title"]');
    var title = titleEl ? (titleEl.content || titleEl.textContent || '') : doc.title;
    // the headline is shown by the reader itself: drop a copy at the top of the article
    var heads = clone.getElementsByTagName('h1');
    for (i = heads.length - 1; i >= 0; i--) {
        if ((heads[i].textContent || '').replace(/\s+/g, ' ').trim() === (title || '').replace(/\s+/g, ' ').trim()) heads[i].parentNode.removeChild(heads[i]);
    }
    // inline elements that touch each other without whitespace ("Name" + "Role") get a space between them
    var inlines = clone.querySelectorAll('span,a,time,b,strong,em,i');
    for (i = 0; i < inlines.length; i++) {
        var cur = inlines[i], nxt = cur.nextSibling;
        if (!nxt || nxt.nodeType !== 1 || !cur.parentNode || !/^(SPAN|A|TIME|B|STRONG|EM|I)$/.test(nxt.tagName)) continue;
        var left = cur.textContent || '', right = nxt.textContent || '';
        if (!left || !right || /\s$/.test(left) || /^\s/.test(right) || /[,.;:!?)\-]$/.test(left) || /^[,.;:!?)\-]/.test(right)) continue;
        cur.parentNode.insertBefore(doc.createTextNode(' '), nxt);
    }
    var bylineEl = doc.querySelector('[rel="author"], .author, .byline, [itemprop="author"], meta[name="author"]');
    var byline = bylineEl ? (bylineEl.content || bylineEl.textContent || '').replace(/\s+/g, ' ').slice(0, 120) : '';
    var html = clone.innerHTML, text = clone.textContent || '';
    // (what the page found is short next to the article it describes: the described one, which is whole)
    if (structured && words(text) < words(structured.text) * 0.6) return fromStructured();
    if (html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').length < 300) return fromStructured();
    return JSON.stringify({ title: (title || doc.title || '').replace(/\s+/g, ' ').slice(0, 300), byline: byline, html: html, url: location.href,
                            minutes: Math.max(1, Math.round(words(text) / 200)) });
})()
