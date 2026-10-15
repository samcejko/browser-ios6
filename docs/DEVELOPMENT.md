# Developing Surfari

How Surfari works, how it is built and released, and the tools and commands for working on it with a device.
The user-facing description is in the [README](../README.md).

## How it works

The rendering engine is the system WebKit (UIWebView) of iOS 6. Everything the 2012 engine cannot do is done by the
app around it:

- **Networking**: every http/https request the page makes is routed through an `NSURLProtocol` into the
  app's own TLS 1.3/1.2 stack (Mbed TLS) with a current CA bundle, so sites with Let's Encrypt certificates,
  modern cipher suites or SNI work without any relay server. Its ClientHello follows a browser's
  (`src/Net/BRTLSHello.h`), with Mbed TLS's own TLS 1.2 hello as a second try for servers that refuse it;
  `tools/tls-probe` builds the same hello on Linux to check it against a list of sites. gzip/deflate/brotli,
  cookies, redirects and an HTTP cache are handled by the app.
- **JavaScript speed**: the binary is signed with the `dynamic-codesigning` entitlement, which enables
  the Nitro JIT inside UIWebView on jailbroken devices (the `-nojit` IPA is signed without it).
- **WebGL**: the iOS 6 engine ships WebGL switched off for apps; Surfari turns it on through the
  web view's WebKit preferences (WebGL 1.0 on the iPad 2's SGX543).
- **Ad and tracker blocking** by host name: OISD small (fetched at build time, shipped as
  `adblock-oisd.txt` with its header) plus the bundled base list `Resources/adblock-base.txt`; it also keeps
  memory use down on 512 MB devices.
- **CSS rewriting** (`Resources/cssfix.js`, run in JavaScriptCore inside the app): custom properties
  (including `@property` initial values), CSS nesting flattened into plain rules (`&`, relative
  selectors, nested `@media`/`@supports` hoisted), flexbox (2009 syntax), vendor prefixes, gradients
  (conic gradients become linear ones with the same stops), modern colours (`oklch()`, `color-mix()`,
  relative colour syntax `rgb(from …)`, `contrast-color()`, `light-dark()`), `image()` and
  `cross-fade()`, two-value `display`, `line-clamp`, `:is()`/`:where()`, `@supports`, `@layer`,
  logical properties, css-text-4 `white-space`/`text-wrap` keywords, `lh`/`cap`/`ic` units, alignment
  qualifiers (`safe`, `first baseline`) and more, so that 2012 WebKit renders modern stylesheets.
  Pseudo-classes the engine lacks (`:focus-within`, `:placeholder-shown`, `:user-invalid`/`:user-valid`,
  `:blank`, `:target-within`, `:playing`/`:paused`/`:muted`, `:local-link`, `:modal`, `:fullscreen`,
  `:popover-open`) become classes that a shim keeps up to date on the elements. `:has()` selectors and
  `@container` queries become classes too: the rewriter leaves their definitions in a manifest comment
  at the end of the stylesheet, the app collects the manifests of every stylesheet served for a page
  (`https://ios6-browser.invalid/manifest?doc=…`), and the shim evaluates them on the live DOM
  (relative selectors inside each candidate, container sizes from the elements marked by
  `container-type`). The same marker channel drives shims for `scroll-snap-type`/`scroll-snap-align`
  (carousels snap after the scroll settles), `scroll-behavior: smooth` (anchor links and
  `scrollTo({behavior: "smooth"})` glide), `text-wrap: balance` (headings get the narrowest width
  that keeps their line count) and scroll-driven animations (`animation-timeline: scroll()`/`view()`
  with `animation-range`: the animation is paused and seeked by the scroll position). `clip-path`
  basic shapes (circle, ellipse, inset, polygon, path) render through `-webkit-mask-image` SVG data
  URLs, and the css-borders-4 `border-<side>-radius` shorthands expand into the corner longhands.
- **Deferred values**: declarations whose value depends on the element are recorded in the page manifest
  with the rule's selectors, their specificity and the media queries around them, and a shim computes
  them per element and sets them inline. This covers **CSS anchor positioning** (`anchor-name`,
  `anchor()`, `anchor-size()`, `position-anchor` including a popover's implicit anchor, `position-area`,
  `position-try-fallbacks` with flips and `@position-try` rules, `position-try-order`,
  `position-visibility`, `anchor-scope`, `anchor-center`), typed `attr()`, `calc-size()` of intrinsic
  sizes, `sibling-index()`/`sibling-count()`, `container-progress()`, `toggle()`, `field-sizing:
  content`, the SVG geometry properties and `mix()`/`calc-mix()`/`color-mix()`/`cross-fade()` driven by
  a scroll or view timeline. `if()` is resolved by the rewriter (`supports()`/`style()` statically,
  `media()` branches as `@media` rules), as are `first-valid()`, `ident()`, `inherit()`,
  `random-item()`, `media-progress()` and request modifiers inside `url()`. `tools/dv-test.html` checks
  the whole chain in a desktop browser with its native implementations stripped.
- **WOFF2 and WOFF fonts** are converted to TrueType on the device (google/woff2 + brotli, zlib) and
  **WebP images** are decoded to PNG (libwebp). Variable fonts become static instances, and fonts with
  very large OpenType layout tables lose them: the old CoreText spent a minute shaping Inter on MDN's
  home page, which now loads in nine seconds.
- **Layout rescue**: column flex containers become blocks (deeply nested 2009 flexbox layout never finished on
  some pages), wrapping flex rows become inline-blocks with `justify-content` mapped to
  `text-align`, flex `gap` becomes margins between the items, a lone `margin-left: auto` on a flex
  item becomes 0 (the 2009 model hands that margin all the free space, which left Google's result
  text 0 px wide), `position: sticky` is prefixed, `text-rendering: optimizeLegibility` and
  `font-feature-settings` are dropped, `clamp()`/`min()`/`max()` are evaluated when their units
  are px, vw, vh, rem or em, `aspect-ratio` travels through a `counter-reset` marker that a shim
  turns into a height for media elements and empty boxes, and `fit-content`/`max-content`/
  `min-content` widths become shrink-to-fit tables. CSS grid is laid out by the page shim from the grid
  rules the rewriter records in the manifest.
  A bundled **CSS3 test** page (`https://ios6-browser.invalid/csstest.html`, served through the rewriter;
  type the address) measures what the engine really renders after the rewrite; css3test.com itself no longer
  runs on ES5 engines. A second page, **Browserscore** (`https://ios6-browser.invalid/browserscore.html`),
  runs the feature definitions of browserscore.dev (the css3test successor; `browserscore/features`, MIT,
  flattened at build time by `tools/browserscore-convert.mjs`) with an ES5 runner that reports three states per
  test: accepted natively, accepted after the CSS rewriter, missing. `tools/browserscore-dev.html`
  runs the same thing in a desktop browser against a checkout served as `/repo/`, and
  `tools/browserscore-estimate.html` takes a result JSON from the device and estimates what the current
  rewriter would add to it, grouping what is still missing.
- **JavaScript polyfills** (trimmed core-js, fetch, IntersectionObserver, ResizeObserver, many small
  shims) are put in front of every page as one bundle (`BRCSSRewriter polyfillBundle`).
- **Modern JavaScript on the old engine**: `Resources/jsfix.js` is the app's own ES2015–ES2022 to ES5
  transpiler (Babel and TypeScript ran at about 0.1 KB/s on an iPad 2 and were dropped). It parses with
  acorn and prints ES5 straight from the tree, lowering while it prints and copying subtrees without newer
  syntax verbatim: let/const with renames and a function per loop iteration where closures capture the
  loop variables, arrows (this/arguments aliases), classes (fields, private members, static blocks,
  `super`, subclasses of built-ins and custom elements), destructuring, default/rest/spread, template
  literals and tagged templates, for-of, optional chaining, `??`, logical assignment, `**`, numeric
  separators, regular expression flags s/u and named groups, block functions of strict code, and
  generators and async functions as state machines on a small regenerator-compatible runtime. Scripts
  the engine already parses pass through untouched (checked with `new Function`), the rest is lowered on
  a second JavaScriptCore thread (about 50–100 KB/s on the iPad 2; Bootstrap 5 in 1.3 s) and kept in
  `Caches/transpiled` by content; inline scripts of documents are lowered by the HTML rewriter. ES
  modules work too: `<script type="module">` (when the page has no `nomodule` fallback) goes to a loader
  in the page shim that fetches the graph with an internal marker the network layer strips, gets each
  module lowered to a registration with live export getters, and links and runs it (import maps, cycles,
  `export *`, dynamic `import()`, `import.meta`). `tools/jsfix-test.html` (also run in CI by
  `tools/jsfix-ci.js`), `tools/jsfix-bundles.html` (Bootstrap, Vue, Alpine, htmx, Swiper, Chart.js, d3,
  three.js, mathjs, KaTeX, mermaid...) and `tools/module-test.html` check it in a desktop browser.
- **Robust connections** on home networks: IPv4 addresses are tried first, the system resolver gets
  a few seconds before the name is asked directly from public DNS servers (8.8.8.8, 1.1.1.1), answers are
  cached, every address has a short connect budget and the TLS handshake has its own timeout. Main documents
  never queue behind subresource connections.
- **Browser UI** in the iOS 6 look (light and dark theme, drawn artwork): address bar with reload/stop,
  back/forward chevrons, book icon for bookmarks and history, Safari-like tab strip under the address
  bar on iPad (tab list with snapshots on iPhone), settings with a "page version" choice that changes
  the User-Agent (iOS 6, desktop Safari 6, modern iPad).
- **Web platform shims** (`Resources/shims.js`, `shims-extra.js`, ES5 only): pointer events, page
  visibility, fullscreen, streams, shadow DOM emulated in the light DOM, custom elements (v0 and v1),
  `<dialog>`, `<picture>`/srcset, `<progress>`/`<meter>`, WebRTC/speech/payment/credential stubs that
  fail cleanly, Web Crypto (digests, HMAC, AES, PBKDF2, HKDF), canvas helpers, a lazily loaded
  WebSQL-backed IndexedDB, `window.open` and `target="_blank"` into new tabs, `navigator.share`,
  a working subset of the CSS Typed OM (`computedStyleMap()`, `attributeStyleMap`, `CSS.px()` and the
  other unit functions, numeric math, transform and colour values), `document.startViewTransition`
  (the callback runs at once), `ontransitionend`/`onanimationend` handler attributes wired to the
  prefixed events, the CSSOM rule classes newer specs expect, the Popover API, and an `Intl`
  implementation for Czech, Slovak, English, German and Polish (numbers, currencies, dates, plural
  rules, relative times, lists, collation) that `toLocaleDateString()` and friends use as well.
- **Everyday browser features**: address suggestions from history and bookmarks, find on page,
  downloads with an "open in" menu, loading progress in the address field, padlock with connection
  details, search engine choice, text size, start page with most visited sites and bookmarks, favicons
  in the tab strip, long press on links (new tab, copy, share, save image, open in Safari), long press
  on reload (desktop/mobile version remembered per site, reload without cache), "Add bookmark" in the share
  sheet, private browsing, search suggestions from the chosen engine, a reader view, long press on a tab
  (close others, duplicate, reopen a closed tab), pull to refresh, swipe in from the screen edge for
  back/forward, long press on the arrows for the history behind them, "Search" and "Share" in the text
  selection menu, `javascript:` bookmarklets in the address bar, international domain names (punycode), HTTP
  Basic authentication dialogs, saved passwords, printing (AirPrint, also from a page's own `window.print()`)
  and "Save as PDF", "View source" and "Translate page" (Google Translate's website proxy), popup blocking
  (`window.open` only after a tap), the clipboard APIs, "Open in background", recently closed tabs, a chosen
  home page, bookmark editing, a search box over bookmarks and history, a custom search engine (address with
  `%s`), keyword searches (`g`, `b`, `s`, `d`, `w`, `we`), a page screenshot into Photos, an offer to open
  Cloudflare-style "verifying your browser" pages in Safari, the bundled start page (`Resources/home.html`) and
  help (`Resources/help.html`, English and Czech) and "Reset settings".
- **Privacy settings**: third-party cookies blocked (like Safari), Do Not Track / Global Privacy
  Control headers, cookie banners of the common consent services hidden by injected CSS, search suggestions
  (on by default), an image switch for slow connections, per-site "allow ads on this site", and a forced dark
  stylesheet for pages (the engine skips CSS filters on areas as large as a page, so inverting was not an option).
- Google search refuses the Safari 6 identity ("browser no longer supported"), so google.* hosts are
  fetched as a current iPad unless the user chooses otherwise.
- Not done yet: tab strip on iPhone.

## Project layout

- `src/Net` - Mbed TLS socket with resolver fallback, HTTP/1.1 client and connection pool,
  `NSURLProtocol` bridge with cache, cookies, ad blocking and body rewriting, CSS rewriter host,
  JavaScriptCore engine wrapper, WOFF2 and WebP converters, the local media/WebSocket proxy
- `src/UI` - browser view controller, tab strip, theme (drawn artwork), settings, bookmarks/history,
  tab list
- `src/Model` - bookmarks, history and saved passwords
- `Resources` - Info.plist, entitlements, start page, help and licences pages, `cssfix.js`, `jsfix.js`, the page
  shims, localizations (`en.lproj`, `cs.lproj`)
- `vendor` - Mbed TLS config and platform glue (Mbed TLS, woff2, brotli and libwebp are fetched at
  build time)
- `tools` - asset generator, PowerShell helpers, the `brmem` tool, desktop test pages for the rewriters and
  shims

## Building

No Mac is needed: `.github/workflows/build.yml` builds on Ubuntu with Theos, the iOS 9.3 SDK (deployment
target 6.0) and an LLVM toolchain. Before the build it fetches Mbed TLS, woff2, brotli, libwebp, the CA bundle,
the OISD list and the JavaScript polyfills, builds the trimmed core-js, minifies the page shims into
`Resources/js/`, checks every page script for ES5 (`tools/check-es5.js`) and runs the transpiler tests
(`tools/jsfix-ci.js`).

- Pushes to `main` and pull requests build the packages; they are Actions artifacts, kept for 14 days:
  `Surfari-packages` (`Surfari-<version>.ipa`, `Surfari-<version>-nojit.ipa`, `Surfari-<version>.deb`,
  `SHA256SUMS`), `brmem` and `build-log`.
- A tag `v<version>` builds the same and publishes a GitHub Release with the packages, `SHA256SUMS`, `LICENSE`,
  `THIRD_PARTY_NOTICES.md` and the notes of that version from `CHANGELOG.md`.
- The version is `CFBundleShortVersionString` in `Resources/Info.plist`; `control` must say the same (the build
  fails otherwise, and when a tag names another version). `CFBundleVersion` is set to the Actions run number, so
  every build can be told apart (Settings › About).
- What the build fetches is pinned (the `env` block at the top of `build.yml`): Theos by commit, the toolchain and
  the SDK by release and SHA-256, Mbed TLS and the npm files from jsDelivr by SHA-256, woff2, brotli, libwebp and the
  browserscore tests by commit. The Theos cache key names the Theos, toolchain and SDK pins, so a new pin makes a new
  cache. While `TOOLCHAIN_SHA256` or `SDK_SHA256` is empty, a build prints the value to pin as a warning, and a
  release build refuses to start. The CA bundle and the OISD list are taken as they are on the day of the build:
  the log shows the date of the CA bundle, and the release notes name it.
- The IPAs are made from the staged app: the normal one is signed with `Resources/entitlements.plist`, the `-nojit`
  one with the same entitlements minus `dynamic-codesigning` (keychain access needs `application-identifier` and
  `keychain-access-groups`).
- The Makefile's `after-stage` leaves out of the package what users do not need: the unminified root copies of the
  page shims (the app takes `js/<name>.js` first; `cssfix.js` and `jsfix.js` stay, the rewriters load them),
  `entitlements.plist` and `brmem` (moved to `packages/brmem`; `make package KEEP_BRMEM=1` keeps it in
  `/usr/bin`). It adds `LICENSE` and `THIRD_PARTY_NOTICES.md` under `/usr/share/doc/com.samcejko.browser/`, a
  `postinst` that runs `uicache`, and a `preinst` that refuses to install the .deb while an IPA copy of the app is on
  the device (both use one bundle id, and only one of them would show on the home screen, without the other's data).

A local build with Theos (macOS or Linux) needs what the workflow fetches and generates first: run the same steps
by hand (they are plain shell), then `make package FINALPACKAGE=1`. `make install` installs on the device named
by `THEOS_DEVICE_IP` or by `"ipad"` in `tools/local.json`.

## Releasing

Surfari's public repository starts at 1.0.0 with a history of its own. The private repository the project was
developed in before that stays private for good: its commits, Actions runs and artifacts hold third-party pages and
site bundles saved for tests, which must not be published. So, once, before the first release:

- Create the new, empty public repository and a fine-grained token for that repository only (permissions below).
  Revoke the token of the old repository.
- Point `repo` and `token` in `tools/local.json` at the new repository, and push into it with `gh-push.ps1`: the
  first commit holds the current tree and nothing of the old history.
- Never change the visibility of the old repository, and never push its history into the new one.
- The first build there has no Theos cache and prints the SHA-256 of the toolchain and the SDK as warnings: set
  `TOOLCHAIN_SHA256` and `SDK_SHA256` in `build.yml` to them and push (a release build refuses to start without
  them).

`gh-push.ps1` checks this itself: it refuses to tag, and to push into a public repository, when the repository holds
commits of the old history (`-AllowOldHistory` overrides it, for a test in a private repository only).

Then, for each release:

1. Set the new version in `Resources/Info.plist` (`CFBundleShortVersionString`) and in `control` (`Version`).
2. Add a section `## [<version>] - <date>` at the top of `CHANGELOG.md`: it becomes the release notes.
3. If a fetched component or its version changed, update `THIRD_PARTY_NOTICES.md` and `Resources/licenses.html`
   (the same text: `LICENSE`, then the notices from "Components" on, as HTML).
4. Push, then tag: `.\tools\gh-push.ps1 -Message "Surfari <version>" -Tag v<version>` (or tag in the GitHub UI).
5. The workflow checks that the tag matches the version, builds, and publishes the release.

## Local helpers (Windows PowerShell)

The helpers need no git. Copy `tools/local.example.json` to `tools/local.json` (ignored by git and never pushed) and
fill it in: `repo` (owner/name), `token` (a fine-grained token for that repository only, with Contents read and
write, Workflows read and write, and Actions read and write: write is needed only by `gh-build.ps1 -Trigger`),
`ipad` (the device's address) and `debugKey` (see below). Copies of the file (`tools/local*.json*`) are ignored
too.

```powershell
.\tools\gh-push.ps1 -Message "change"                   # push the working tree via the REST API
.\tools\gh-build.ps1 -Download -Install [-NoJIT] [-Brmem] # wait for the run, fetch, install over SSH
. .\tools\ipad.ps1; Get-IPadCrashLogs; Get-IPadSyslog     # debugging
```

`gh-push.ps1` pushes everything `.gitignore` does not ignore, and deletes from the remote branch what is gone or
ignored locally. Into a new, empty repository it makes a first commit with the whole tree. `-Tag` tags the pushed
commit. It uploads nothing while a file it would upload holds something that looks like a GitHub token (or the
configured token itself), and names the file.

`tools/ipad.ps1` (dot-source it) talks to the device over SSH as root with the key `~/.ssh/ipad_ios6`:
`Invoke-IPad`, `Copy-ToIPad`, `Copy-FromIPad`, `Install-IPadPackage`, `Set-IPadDebugKey`, `Invoke-Surfari`,
`Get-IPadCrashLogs` and `Get-IPadSyslog`. `Install-IPadPackage` keeps the kind of package the device has: it updates
an installed .deb instead of adding the IPA, and never falls back to the .deb while an IPA copy is there.

## Developer mode

Release builds are quiet: the app writes nothing to the system log and ignores developer commands. Developer mode
is on when the device has a **debug key**: the trimmed content of `Library/surfari-debug-key` in the app's home
directory, at least 16 characters (letters and digits are safest: the key travels in URLs). The app's home is
`/var/mobile` for the .deb and `/var/mobile/Applications/<UUID>` for an IPA. Over SSH:

```sh
APP_HOME=/var/mobile                                          # the .deb
APP_HOME=$(dirname /var/mobile/Applications/*/Surfari.app)    # or an IPA
echo 'your-own-long-random-key' > "$APP_HOME/Library/surfari-debug-key"
chown mobile:mobile "$APP_HOME/Library/surfari-debug-key"
chmod 600 "$APP_HOME/Library/surfari-debug-key"
killall -9 Surfari
```

`Set-IPadDebugKey` in `tools/ipad.ps1` does this with `debugKey` from `tools/local.json`. The app checks for the
file at launch. Delete the file (and restart the app) to leave developer mode.

With the key file present (or the `BRDebugLog` user default set to YES), the app logs to the system log with the
prefix `[Surfari]`: main documents, DNS fallbacks, connect timeouts, load times, memory. Install `syslogd` from
Cydia to get `/var/log/syslog`; `Get-IPadSyslog` shows the app's lines. Developer mode also turns on WebKit's
developer extras and the watchdog that samples WebKit's thread during slow loads. Other developer switches are
user defaults set with the `set` command below, for example `BRDebugJSErrors` (the page shim logs the real errors of
callbacks and promises; it slows pages down), `BRDumpRewriteInputs` and `BRDevPages`. The page shim's own
diagnostics (load timing, page errors, refused popups) reach the log in developer mode only: the app then puts
`window.__brDebugLog` at the start of the polyfill bundle.

The **safe start** (after two runs in a row that ended while the app was on screen, the start page opens instead of
the last tab) is off in developer mode, where the app is ended with `killall` all the time. To try it, delete the key
file, end the app twice while it shows a page (`killall -9 Surfari`), then launch it by tapping its icon.

### Developer commands

A developer command is a `surfari:` link whose first parameter is the debug key:
`surfari:<command>?key=<debug key>&<other parameters>`. Without a key file on the device, or with a wrong key,
the app ignores the command without a trace. Web pages can never open `surfari:` links. Over SSH:

```sh
uiopen 'surfari:snapshot?key=K'
uiopen 'surfari:eval?key=K&js=document.title'
```

or from Windows: `Invoke-Surfari snapshot`, `Invoke-Surfari eval @{ js = 'document.title' }`.
Results go to the app's `tmp/` directory and to the log.

| Command | What it does |
|---|---|
| `home` | opens the start page |
| `eval?js=<code>` | evaluates JavaScript in the current page, result to `tmp/eval.txt` |
| `evalfile?path=<file>` | checks that a script file parses and runs in the current page |
| `set?key=<name>&value=<v>&type=bool\|int\|string\|remove` | sets a user default (the setting's name is the second `key=`, or `name=`) |
| `ua?host=<host>&mode=<0-2, -1 removes>` | the identity (page version) of a site |
| `dump` | writes the current DOM to `tmp/dump.html` |
| `snapshot` | writes the screen to `tmp/screen.png` |
| `screen` | the same through the system's screen grab (videos included) |
| `reader`, `pdf`, `source`, `translate` | the share-menu actions |
| `history` | the tab's back/forward lists, to `tmp/eval.txt` |
| `goback?n=<index>` | goes to an entry of the last `history` list |
| `type?text=<text>` | types into the address bar and goes |
| `auth?user=<u>&password=<p>` | answers the pending HTTP authentication dialog |
| `press?n=<index>` or `press?title=<text>` | presses a button of the alert, action sheet or screen |
| `pasteboard` | the pasteboard's text, to `tmp/eval.txt` |
| `forgetpasswords` | deletes the saved passwords |
| `mem`, `mem?relieve=1`, `mem?types=1` | WebKit's memory numbers (after freeing memory; with object counts) |
| `requests` | the requests the page still waits for |
| `profile?secs=<s>&thread=<name>` | samples a thread (default WebThread), report to `tmp/profile.txt` |
| `symbols?addrs=<a,b,...>` | names addresses of a crash report from the same boot, to `tmp/symbols.txt` |
| `jsfixtest?input=<file>&opts=<json>&jsfix=<file>` | measures the transpiler on a file |

The public form, `surfari:<address>` (also `surfari://open?url=<percent-encoded address>`), only opens http and
https pages and needs no key.

### brmem

`tools/brmem/brmem.c` is a command-line tool for the device (run over SSH as root) that lists every process's
resident memory and the system's free/active/inactive/wired pages: jetsam kills the browser when the system as a
whole runs short. CI publishes it as the `brmem` artifact; it is not in the packages. `gh-build.ps1 -Install
-Brmem` copies it to `/usr/bin/brmem`.

### Mapping a reported line

iOS 6 reports script errors with a line and no column. `tools/bundle-line.ps1 -Line <n>` shows the line of the page
polyfill bundle (`__br_polyfills-<crc>.js`) that an error names, from the minified copies in a downloaded .deb.

## Tests

The rewriters and shims have desktop test pages in `tools/` (`cssfix-test.html`, `jsfix-test.html`,
`jsfix-bundles.html`, `module-test.html`, `dv-test.html`, `shims-test.html` and many more; `run-desktop-tests.html`
runs a set of them). Serve the repository with `tools/serve.ps1` and open them in a desktop browser; several of them
emulate the old engine's limits. CI runs `tools/jsfix-ci.js` and `tools/check-es5.js`.

The JavaScript in `Resources/` must stay ES5 and fast on iOS 6: no closures or `try` in hot paths, no named function
expressions where they are called often (see the comments in the files and in `tools/minify-page-scripts.js`).

## Third-party code and licences

Everything bundled is listed in `THIRD_PARTY_NOTICES.md` with its version, source and licence, and shown in the app
by `Resources/licenses.html`. When `build.yml` fetches a new version or a new component, update both. The minifier
keeps licence comments (`/*!`, `@license`, `@preserve`, copyright lines).

Do not add third-party web pages, saved site bundles or other copyrighted material to the repository: test material
of that kind belongs in `tools/babel-test/` or `tools/samples/local/`, which git ignores (and `gh-push.ps1` never
pushes).
