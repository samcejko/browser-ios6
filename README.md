# Browser for iOS 6

Universal (iPhone + iPad) web browser for **jailbroken iOS 6.x** devices (armv7, e.g. iPad 2).

The rendering engine is the system WebKit (UIWebView). Everything the 2012 engine cannot do is done by
the app around it:

- **Networking**: every http/https request the page makes is routed through an `NSURLProtocol` into the
  app's own TLS 1.2 stack (mbedTLS) with a current CA bundle, so sites with Let's Encrypt certificates,
  modern cipher suites or SNI work without any relay server. gzip/deflate, cookies, redirects and an
  HTTP cache are handled by the app.
- **JavaScript speed**: the binary is signed with the `dynamic-codesigning` entitlement, which enables
  the Nitro JIT inside UIWebView on jailbroken devices.
- **WebGL**: the iOS 6 engine ships WebGL switched off for apps; the browser turns it on through the
  web view's WebKit preferences (WebGL 1.0 on the iPad 2's SGX543).
- **Ad and tracker blocking** by host name (Peter Lowe's list fetched at build time plus a bundled
  base list), which also keeps memory use down on 512 MB devices.
- **CSS rewriting** (`Resources/cssfix.js`, run in JavaScriptCore inside the app): custom properties,
  flexbox (2009 syntax), vendor prefixes, gradients, modern colours, `:is()`/`:where()`, `@supports`,
  `@layer`, logical properties and more, so that 2012 WebKit renders modern stylesheets.
- **WOFF2 and WOFF fonts** are converted to TrueType on the device (google/woff2 + brotli, zlib) and
  **WebP images** are decoded to PNG (libwebp). Variable fonts become static instances, and fonts with
  very large OpenType layout tables lose them: the old CoreText spent a minute shaping Inter on MDN's
  home page, which now loads in nine seconds.
- **Layout rescue**: `display: grid` becomes floated equal-width columns (12-column systems stack
  instead), column flex containers become blocks (deeply nested 2009 flexbox layout never finished on
  some pages), wrapping flex rows become inline-blocks with `justify-content` mapped to
  `text-align`, flex `gap` becomes margins between the items, a lone `margin-left: auto` on a flex
  item becomes 0 (the 2009 model hands that margin all the free space, which left Google's result
  text 0 px wide), `position: sticky` is prefixed, `text-rendering: optimizeLegibility` and
  `font-feature-settings` are dropped. The start page links a bundled **CSS3 test** page
  (`https://ios6-browser.invalid/csstest.html`, served through the rewriter) that measures what the
  engine really renders after the rewrite; css3test.com itself no longer runs on ES5 engines.
- **JavaScript polyfills** (trimmed core-js, fetch, IntersectionObserver, ResizeObserver, many small
  shims) are injected into every page. Transpiling modern syntax on the device was tried with Babel and
  TypeScript and measured at roughly 0.1 KB/s with 300 MB of RAM on an iPad 2, so pages that ship
  ES2015+ bundles without an ES5 fallback do not work.
- **Robust connections** on home networks: IPv4 addresses are tried first, the system resolver gets
  a few seconds before the name is asked directly from public DNS servers, answers are cached, every
  address has a short connect budget and the TLS handshake has its own timeout. Main documents never
  queue behind subresource connections.
- **Browser UI** in the iOS 6 look (light and dark theme, drawn artwork): address bar with reload/stop,
  back/forward chevrons, book icon for bookmarks and history, Safari-like tab strip under the address
  bar on iPad (tab list with snapshots on iPhone), settings with a "page version" choice that changes
  the User-Agent (iOS 6, desktop Safari 6, modern iPad).
- **Web platform shims** (`Resources/shims.js`, `shims-extra.js`, ES5 only): pointer events, page
  visibility, fullscreen, streams, shadow DOM emulated in the light DOM, custom elements (v0 and v1),
  `<dialog>`, `<picture>`/srcset, `<progress>`/`<meter>`, WebRTC/speech/payment/credential stubs that
  fail cleanly, SHA-1/SHA-256 for `crypto.subtle.digest`, canvas helpers, a lazily loaded
  WebSQL-backed IndexedDB, `window.open` and `target="_blank"` into new tabs, `navigator.share`.
  html5test.com went from 290 to 458 of 555 points with these (the remaining points are ES2015
  syntax, codecs and other things an old engine cannot fake).
- **Everyday browser features**: address suggestions from history and bookmarks, find on page,
  downloads with an "open in" menu, loading progress in the address field, padlock with connection
  details, search engine choice, text size, start page with most visited sites and bookmarks, favicons
  in the tab strip, long press on links (new tab, copy, share, save image, open in Safari), long press
  on reload (desktop/mobile version remembered per site, reload without cache), "Add bookmark" in the share sheet,
  private browsing (no history or cache, cookies restored afterwards), search suggestions from
  DuckDuckGo while typing, a reader view that extracts the article of a page into a clean layout,
  long press on a tab (close others, duplicate, reopen a closed tab), pull to refresh, swipe in
  from the screen edge for back/forward, long press on the arrows for the history behind them,
  "Search" and "Share" in the text selection menu, `javascript:` bookmarklets in the address bar,
  international domain names (punycode), HTTP Basic authentication dialogs, printing (AirPrint, also
  from a page's own `window.print()`) and "Save as PDF" from the share sheet, "Find on page",
  "View source" and "Translate page" (Google Translate's website proxy, which serves pages already
  translated) in the share sheet, a reader button in the address field when a page looks like an
  article, popup blocking (`window.open` only after a tap), `navigator.clipboard.writeText` and
  `execCommand('copy')` into the system pasteboard, "Open in background" for links, recently closed
  tabs on a long press of the plus button, a chosen home page, bookmark editing (rename, address,
  reorder), a search box over bookmarks and history, a custom search engine (address with `%s`),
  "Download link" in the link menu, "Open" in the selection menu when the selected text is an
  address, "Paste and Go" in the address field, search suggestions from the chosen engine, and
  keyword searches typed into the address field (`g dotaz` Google, `b` Bing, `s` Seznam, `d`
  DuckDuckGo, `w` / `we` Czech / English Wikipedia), a page screenshot into Photos, "Open in
  Safari" in the share sheet and on the error page, an offer to open Cloudflare-style "verifying
  your browser" pages in Safari, a bundled help page (Settings > Help and gestures, also on the
  start page) and "Reset settings".
- **Privacy settings**: third-party cookies blocked (like Safari), Do Not Track / Global Privacy
  Control headers, cookie banners of the common consent services hidden by injected CSS, an image
  switch for slow connections, per-site "allow ads on this site", and a forced dark stylesheet for
  pages (the engine skips CSS filters on areas as large as a page, so inverting was not an option).
- Google search refuses the Safari 6 identity ("browser no longer supported"), so google.* hosts are
  fetched as a current iPad unless the user chooses otherwise.
- Planned: tab strip on iPhone.

## Building (GitHub Actions)

No Mac needed. Pushing to `main` runs `.github/workflows/build.yml` on Ubuntu with Theos, the
iOS 9.3 SDK (deployment target 6.0) and mbedTLS. Artifacts: `Browser-<version>.ipa`,
`Browser-<version>-nojit.ipa` (without the JIT entitlement, for troubleshooting) and a `.deb`.

Local helpers (Windows PowerShell, no git required; settings in `tools/local.json`):

```powershell
.\tools\gh-push.ps1 -Message "change"                 # push via REST API
.\tools\gh-build.ps1 -Download -Install                 # wait, fetch, install over SSH
. .\tools\ipad.ps1; Get-IPadCrashLogs; Get-IPadSyslog   # debugging
```

## Installing on the device

1. Cydia: **AppSync Unified** (repo `https://cydia.akemi.ai/`) and **IPA Installer Console** (BigBoss),
   plus OpenSSH for the helper scripts.
2. Copy the `.ipa` to the device and run `ipainstaller -f Browser.ipa`, or use iFunBox / 3uTools.
   The `.deb` works too (`dpkg -i`, then `uicache`) and installs into `/Applications`.

## Project layout

- `src/Net` - mbedTLS socket with resolver fallback, HTTP/1.1 client and connection pool,
  `NSURLProtocol` bridge with cache, cookies, ad blocking and body rewriting, CSS rewriter host,
  JavaScriptCore engine wrapper, WOFF2 and WebP converters
- `src/UI` - browser view controller, tab strip, theme (drawn artwork), settings, bookmarks/history,
  tab list
- `src/Model` - bookmarks and history store
- `Resources` - Info.plist, entitlements, start page, `cssfix.js`, `shims.js`, localizations
- `vendor` - mbedTLS config and platform glue (mbedTLS, woff2, brotli and libwebp are fetched at
  build time)
- `tools` - asset generator, PowerShell helpers, local test pages for the CSS rewriter

Debugging over SSH: `uiopen browser:https://example.com` opens a page, `uiopen browser:snapshot`
writes the current screen to the app's `tmp/screen.png`, and `/var/log/syslog` carries the app's log
lines (`[Browser]`: main documents, DNS fallbacks, connect timeouts, load times, memory). More
commands: `browser:eval?js=`, `browser:evalfile?path=`, `browser:dump`, `browser:set?key=&value=&type=`,
`browser:reader`, `browser:pdf`, `browser:source`, `browser:translate`, `browser:history`,
`browser:goback?n=`, `browser:type?text=`, `browser:auth?user=&password=`, `browser:pasteboard`.
