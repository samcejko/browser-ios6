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

    // Candidates: elements with several paragraphs of real text
    var candidates = [], all = doc.body ? doc.body.getElementsByTagName('*') : [];
    for (var i = 0; i < all.length; i++) {
        var el = all[i], tag = el.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NAV' || tag === 'HEADER' || tag === 'FOOTER' || tag === 'ASIDE' || tag === 'FORM') continue;
        var paragraphs = el.getElementsByTagName('p');
        if (paragraphs.length < 2) continue;
        var text = 0, longParas = 0;
        for (var p = 0; p < paragraphs.length; p++) {
            var len = textLength(paragraphs[p]);
            if (paragraphs[p].parentNode === el || paragraphs[p].parentNode.parentNode === el) { text += len; if (len > 80) longParas++; }
        }
        if (longParas < 2) continue;
        var score = text * (1 - linkDensity(el));
        var idClass = (el.id || '') + ' ' + (el.className || '');
        if (NEGATIVE.test(idClass)) score *= 0.4;
        if (POSITIVE.test(idClass)) score *= 1.3;
        if (tag === 'ARTICLE' || tag === 'MAIN') score *= 1.5;
        candidates.push({ el: el, score: score });
    }
    if (!candidates.length) return '';
    candidates.sort(function (a, b) { return b.score - a.score; });
    var best = candidates[0].el;
    // walk up while a parent contains much more text (whole article with several sections)
    var parent = best.parentNode;
    while (parent && parent !== doc.body && parent.nodeType === 1) {
        if (textLength(parent) > textLength(best) * 1.5 && linkDensity(parent) < 0.3 && !NEGATIVE.test((parent.id || '') + ' ' + (parent.className || ''))) best = parent;
        else break;
        parent = parent.parentNode;
    }

    var clone = best.cloneNode(true);
    var junk = clone.querySelectorAll('script,style,iframe,object,embed,form,input,button,select,textarea,nav,aside,footer,noscript,svg,video,audio,canvas,[hidden],[aria-hidden="true"]');
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
    // strip attributes that carry site styling or behaviour
    var nodes = clone.getElementsByTagName('*');
    for (i = 0; i < nodes.length; i++) {
        var n = nodes[i], attrs = n.attributes, keep = { href: 1, src: 1, alt: 1, title: 1, colspan: 1, rowspan: 1 };
        for (var a = attrs.length - 1; a >= 0; a--) if (!keep[attrs[a].name]) n.removeAttribute(attrs[a].name);
        if (n.tagName === 'IMG') {
            var src = n.getAttribute('src') || '';
            if (!src || /^data:/.test(src) || /1x1|pixel|spacer/.test(src)) n.parentNode.removeChild(n);
        }
    }
    var titleEl = doc.querySelector('h1') || doc.querySelector('meta[property="og:title"]');
    var title = titleEl ? (titleEl.content || titleEl.textContent || '') : doc.title;
    var bylineEl = doc.querySelector('[rel="author"], .author, .byline, [itemprop="author"], meta[name="author"]');
    var byline = bylineEl ? (bylineEl.content || bylineEl.textContent || '').replace(/\s+/g, ' ').slice(0, 120) : '';
    var html = clone.innerHTML;
    if (html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').length < 300) return '';
    return JSON.stringify({ title: (title || doc.title || '').replace(/\s+/g, ' ').slice(0, 300), byline: byline, html: html, url: location.href });
})()
