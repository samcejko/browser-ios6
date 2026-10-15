# Surfari

**A modern-web browser for jailbroken iOS 6.**

iOS 6's Safari can no longer open most of today's websites: it cannot make the secure connections they require, and
its 2012 engine does not understand their CSS and JavaScript. Surfari keeps the iOS 6 engine for drawing pages and
does everything around it that the old system cannot:

- **Its own TLS 1.3 and 1.2 stack** (Mbed TLS) with current root certificates and a browser-like hello: sites with
  modern certificates and ciphers open directly, without a proxy or relay server.
- **Modern CSS rewritten** for the old engine: custom properties, flexbox and grid, nesting, modern colours,
  `:has()`, container queries, anchor positioning and much more.
- **Modern JavaScript translated** to the old dialect by its own transpiler (ES2022, ES modules), plus polyfills for
  newer web APIs (fetch, IntersectionObserver, custom elements, IndexedDB, Intl, Web Crypto and others).
- **WOFF2 fonts and WebP images** converted on the device.
- **Ad and tracker blocking** with built-in lists, and hiding of cookie banners.
- **Reader view**, find on page, translate, print and save as PDF, downloads, view source.
- **Saved passwords** (in the device's keychain, for secure sites only), **private browsing**, dark theme and dark
  pages.
- Tabs, bookmarks, history, a choice of search engines with suggestions, swipe gestures, and an English and Czech
  interface.

Surfari is an independent project and is not affiliated with Apple. iOS, iPad and Safari are trademarks of Apple Inc.

## Requirements

- A **jailbroken** device with **iOS 6.x** (armv7).
- Tested on an **iPad 2 with iOS 6.1.2**. Other iOS 6 devices may work, but they are untested, and the memory
  handling is tuned for devices with 512 MB of RAM. The app runs on iPhone too; the tab strip is iPad-only.
- iOS 7 and later are not supported.

## Install

Download the files from the [Releases](https://github.com/samcejko/surfari/releases) page on a computer (iOS 6
cannot open github.com), check them against `SHA256SUMS` if you like, and copy one of them to the device (SSH/SCP,
iFunBox, 3uTools or Filza). There are two kinds of package; **pick one and stay with it**:

| File | How to install |
|---|---|
| `Surfari-<version>.deb` | Open it in Filza or iFile and install it, or over SSH: `dpkg -i Surfari-<version>.deb`. The package refreshes the home screen itself; if the icon does not appear, run `su mobile -c uicache` (or reboot). Remove it with `dpkg -r com.samcejko.browser`. |
| `Surfari-<version>.ipa` | Needs **AppSync Unified** (Cydia repo `https://cydia.akemi.ai/`). Install it with Filza, or over SSH with IPA Installer Console: `ipainstaller Surfari-<version>.ipa`. |
| `Surfari-<version>-nojit.ipa` | The same app without the JavaScript JIT. JavaScript runs about half as fast, but the JIT compiler, where many engine exploits start, is switched off. Use it if the normal IPA does not start, or if you prefer the smaller attack surface. |

The .deb installs Surfari as a system app in `/Applications` and keeps its data in `/var/mobile`; an IPA keeps its
data in its own app container. Both use the same app identity, so **do not install both**: only one of them would
show on the home screen, and bookmarks, history and settings would not carry over between them. The .deb refuses to
install while an IPA copy is on the device. To switch, remove the installed one first. To update, install the new
version the same way over the old one: your data stays.

Surfari cannot update itself and does not check for updates: watch the Releases page.

## Security notice

**The page engine of iOS 6 (WebKit and JavaScriptCore) has not received security updates for years**, and many of
its bugs are publicly known. Surfari's own TLS stack keeps your connections secure and up to date, but Surfari cannot
fix the engine: a malicious page could take over the app, and on a jailbroken device possibly more.

- If that worries you, do not use Surfari for banking or with passwords you also use elsewhere, and prefer sites you
  trust.
- Keep **Settings › Advanced › Verify certificates** on. It is there for troubleshooting only.
- The `-nojit` IPA gives an exploit less to work with, at the cost of speed.
- **Private browsing** keeps no history, writes nothing to the page cache and keeps its cookies apart (they are deleted
  when you turn it off). Only the cookies are kept apart: pages cached before are still used, the engine's own site
  storage (local storage, databases, offline caches) is shared with normal browsing, and downloads go to the app's
  Documents folder, which iTunes file sharing shows.
- Saved passwords stay in this device's keychain (not in backups) and are offered only on verified https pages.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Privacy

Surfari has no account, no analytics and no crash reporting. Pages come straight from the sites you visit. Besides
them, Surfari contacts:

- **Your search engine's suggestion service** while you type in the address bar (Google, Bing, or DuckDuckGo, which
  also serves Seznam and custom engines) - never for an address and never in private browsing. You can turn
  suggestions off in Settings › Privacy.
- **Google Public DNS (8.8.8.8) and Cloudflare (1.1.1.1)**, unencrypted, when your network's DNS server is slow or
  gives no answer.
- **Google Translate**, with the page's address, when you choose Translate Page.

Google's sites get the identity of a modern iPad by default (they refuse iOS 6's). The ad block lists are part of the
app; nothing is downloaded to update them. The small helper servers inside the app (for media and WebSockets) listen
only on the device itself.

## What does not work

- Protected video (DRM): Netflix, Disney+, Spotify and similar services.
- Sites that check the browser before they let you in (for example Cloudflare's "verifying your browser" page);
  Surfari offers to open them in Safari.
- Features the old engine cannot be taught: WebAssembly, video calls (WebRTC), offline web apps (service workers),
  push notifications.
- Very large web apps can load slowly or run out of memory.

## Opening links in Surfari

Other apps (and `uiopen` over SSH) can open a page in Surfari with the `surfari:` scheme followed by the address:
`surfari:https://example.com/page`. A bare host name gets `https://` (`surfari:example.com`), and
`surfari://open?url=<percent-encoded address>` works too. Only http and https pages open this way.

## Building and contributing

Surfari is built by GitHub Actions (Theos, iOS 9.3 SDK, deployment target 6.0); no Mac is needed. How it works, how
to build it, and the developer tools and commands are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes are
listed in [CHANGELOG.md](CHANGELOG.md).

## License

Surfari is free software under the [MIT License](LICENSE). It includes third-party components under their own
licences (MIT, BSD, Apache-2.0 and others; the OISD block list, a separate data file, is GPL-3.0): see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), also shown in the app under Settings › About › Licenses.
