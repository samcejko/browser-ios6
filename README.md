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
- Planned: on-device transpiling (ES2020 to ES5) and polyfills, CSS rewriting, WOFF2/WebP conversion.

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

- `src/Net` - mbedTLS socket, HTTP/1.1 client, `NSURLProtocol` bridge with cache and cookies
- `src/UI` - browser view controller (address bar, navigation, error pages)
- `Resources` - Info.plist, entitlements, start page, localizations
- `vendor` - mbedTLS config and platform glue (mbedTLS itself is fetched at build time)
- `tools` - asset generator and PowerShell helpers
