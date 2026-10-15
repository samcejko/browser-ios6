# Changelog

The changes of each Surfari release. Versions follow [Semantic Versioning](https://semver.org/); the newest is at
the top. (The section of a version becomes the notes of its GitHub Release.)

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
