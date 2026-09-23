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
- **Ad and tracker blocking** by host name (Peter Lowe's list fetched at build time plus a bundled
  base list), which also keeps memory use down on 512 MB devices.
- **CSS rewriting** (`Resources/cssfix.js`, run in JavaScriptCore inside the app): custom properties,
  flexbox (2009 syntax), vendor prefixes, gradients, modern colours, `:is()`/`:where()`, `@supports`,
  `@layer`, logical properties and more, so that 2012 WebKit renders modern stylesheets.
- **WOFF2 fonts** are converted to TrueType on the device (google/woff2 + brotli) and **WebP images**
  are decoded to PNG (libwebp).
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
- Planned: sticky/object-fit polyfills, favicons in tabs, tab strip on iPhone.

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
lines (`[Browser]`: main documents, DNS fallbacks, connect timeouts, load times, memory).
