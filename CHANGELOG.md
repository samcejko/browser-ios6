# Changelog

The changes of each Surfari release. Versions follow [Semantic Versioning](https://semver.org/); the newest is at
the top. (The section of a version becomes the notes of its GitHub Release.)

## [1.2.0] - 2026-10-16

### Added

- Play in the background (Settings > Pages, on by default): music and videos of a page go on when you leave the app
  or lock the screen - an internet radio, a YouTube video, a live stream. The buttons of the lock screen and of a
  headset pause and resume them, and the lock screen shows the page's title.

## [1.1.1] - 2026-10-15

### Fixed

- Log in with cookies keeps the cookies for the page's own host and its subdomains (a leading "www." dropped), no
  longer for the last two labels of its name: for a site under co.uk, com.au, github.io and the like that is a public
  suffix, and the cookies would have gone to every site under it. A service whose subdomains are other people's pages
  (neocities.org, wordpress.com...) keeps them to its own host; on a subdomain such as old.reddit.com, a cookie that the
  site keeps for its whole domain is replaced there.
- Cookies of the same name that the site had set before (the logged-out session) are replaced, instead of going out
  next to the imported ones, where many servers read only the first. If the jar does not take the import, the dialog
  says so and everything is put back as it was.
- The clipboard is no longer read when the dialog opens: the Paste button above the keyboard puts it in. (A page can
  write to the clipboard after a tap.)
- The cookies are for the page the menu was opened on, with that page's Secure flag, and that page is the one loaded
  again. Pages of the site that the cache kept from before the login, also after a relaunch, are no longer shown.
- More of what people paste is understood: document.cookie copied in quotes, a Set-Cookie line (its HttpOnly is kept,
  its other attributes are not cookies; one that deletes a cookie is left out), a block of request headers or a table
  of them, "Copy as cURL" (bash or cmd, also several commands at once), a JSON export (Cookie-Editor, EditThisCookie),
  rows of a browser's cookie table or of a cookies.txt file. Of a file or table with many sites only the cookies the
  page would get are taken, of cURL commands only those sent to the page's site, the page's own host winning (another
  site's session no longer goes to this one); if none are left, the dialog says so. Within one Cookie header or document.cookie line the first of two cookies of a name counts, as on
  the server.
- A site's own subdomains keep their cookies when the login is for a host that keeps them to itself (neocities.org,
  an IP address), and a login moves up to a parent domain only where that is no shared suffix (uk.com, blogspot.*,
  cloud hosts) on which another page could have planted a cookie of the same name.
- Emptying the cache (also with "Clear cookies") forgets the list of sites logged in with cookies.
- On an iPhone the text box and its caret stay above the keyboard; in private browsing the dialog says that the login
  lasts until private browsing is turned off. The help page describes the feature.

### Changed

- The package itself asks for iOS 6.x (`firmware (<< 7.0)`), as the Cydia repository already did, so the GitHub
  release and the repository hand out the same file.

## [1.1.0] - 2026-10-15

### Added

- **Log in with cookies**: on sites whose login needs a CAPTCHA the iOS 6 engine cannot run (Cloudflare Turnstile and
  the like), log in to the site in another browser and paste its cookies into Surfari — long press the reload button,
  then "Log in with cookies". Surfari stores them for the site, so the logged-in page loads without ever showing the
  CAPTCHA. The box pre-fills from the clipboard, and the cookies are kept for the site and its subdomains.

## [1.0.0] - 2026-10-03

The first public release. Test builds before it were called "Browser"; Surfari keeps their app identity
(`com.samcejko.browser`), so installing it over one of them keeps bookmarks, history and settings.

### Highlights

- Today's websites on iOS 6: Surfari's own TLS 1.2 stack (Mbed TLS 3.6) with current root certificates, a CSS
  rewriter for the 2012 engine, its own ES2022-to-ES5 transpiler with ES module support, and polyfills for newer web
  APIs.
- WOFF2 and WOFF fonts and WebP images converted on the device.
- Ad and tracker blocking (OISD small and a built-in list) and hiding of cookie banners.
- Reader view, find on page, Translate Page, print and Save as PDF, downloads, view source.
- Saved passwords in the device's keychain, offered on verified https pages only.
- Private browsing with cookies of its own.
- Tabs, bookmarks, history, search engines with suggestions, gestures, a dark theme and dark pages.
- English and Czech, including the start page and the help.

### Security and privacy

- The `surfari:` scheme opens web pages (`surfari:https://example.com`); developer commands work only with a debug
  key that is on the device. Web pages can no longer open the app's own scheme, and links to other apps (phone,
  messages, Cydia...) ask before they leave Surfari.
- No browsing data in the system log: the app logs only in developer mode.
- Saved passwords are filled only on https pages with certificate verification on, matched to the page's real
  address, and kept on this device only (not in backups).
- Search suggestions can be turned off (Settings › Privacy).
- Turning certificate verification or private browsing on or off drops the open connections and TLS sessions.
- A WebSocket whose certificate Surfari's TLS rejects is no longer retried over iOS 6's own TLS.
- `crypto.getRandomValues` in web workers uses the system's secure random generator.
- Hardening of the HTTP client and the font converter against malformed and oversized responses; a response cut off
  by a broken connection is neither cached nor saved as a complete download.
- What the rewriters keep for later (lowered scripts, rewritten styles, large inline scripts) is found by a SHA-256 of
  its text, so a page can no longer put its own code under the name of another site's script.
- Release builds carry no debugging entitlement and no WebKit developer extras.

### Packages

- `Surfari-<version>.ipa`, `Surfari-<version>-nojit.ipa` (without the JIT, now with the same keychain access, so
  saved passwords work in it too) and `Surfari-<version>.deb`, published as GitHub Releases with `SHA256SUMS`.
- The .deb carries the licence files and refreshes the home screen after installing; the developer tool `brmem` is
  no longer in it. It refuses to install while an IPA copy of Surfari is on the device (the two share one app
  identity, and only one of them would show).
- Release builds are made from pinned sources and tools, checked by commit or SHA-256; the release notes name the
  date of the root certificates.
- Licences of all included components under Settings › About › Licenses and in `THIRD_PARTY_NOTICES.md`.
- Peter Lowe's ad server list is no longer included (its terms do not allow redistribution in an app); OISD covers
  its domains.
