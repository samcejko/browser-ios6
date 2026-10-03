# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | yes |
| test builds called "Browser" (0.x) | no |

Fixes go into the newest release; there are no backports.

## Reporting a vulnerability

Please report security problems privately through GitHub's private vulnerability reporting: on
https://github.com/samcejko/surfari open the **Security** tab and choose **Report a vulnerability**. If that is not
possible, open an issue that says only that you have a security report and how to reach you, without the details.

Please include the Surfari version and build (Settings › About), the device and iOS version, whether the IPA, the
`-nojit` IPA or the .deb is installed, and the steps or a page that shows the problem. You will get an answer within
two weeks. Surfari is a hobby project maintained by one person, so a fix may take a while; you will be told what is
planned, and credited in the release notes if you wish.

## What is in scope

Surfari's own code: its TLS and certificate handling, the HTTP client and cache, the URL scheme and the developer
commands, the local proxies, saved passwords, private browsing, the CSS and JavaScript rewriters and the page shims,
and the build and release pipeline.

## Known limitations

The page engine is the WebKit and JavaScriptCore of iOS 6, which have not received security updates for years.
Their many public bugs are known and out of reach of this project: Surfari cannot patch the system's engine. Reports
about them are welcome only where Surfari makes them worse or could reasonably work around them. The README's
security notice describes what this means for users.
