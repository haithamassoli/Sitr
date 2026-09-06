# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub Security Advisories:
https://github.com/haithamassoli/Sitr/security/advisories/new ("Report a vulnerability").
Do not open a public issue for anything that could expose screen content or defeat the protections below.

You should get an acknowledgement within 7 days. Sitr is a solo, open-source project, so fixes are best effort; the
advisory is published together with the fixed release.

Never include screenshots or screen recordings that show people in a report. Describe the situation or use synthetic
content instead.

## Supported versions

Only the latest release on https://github.com/haithamassoli/Sitr/releases receives fixes.

## Scope

Sitr's promise is that everything stays on the Mac: frames are analysed in memory and never written to disk or logs,
and the app cannot open a network socket. The following are in scope:

- Any path by which captured screen pixels reach disk, logs, another process, or the network.
- The app gaining or using a network entitlement, or any outbound connection.
- Sandbox or Hardened Runtime bypasses, code-signing or notarization problems in released builds.
- Overlay integrity: a way for another app or page to hide, move, or click through the covers in a way the user did
  not request (Reveal Hold is a user action and is not a vulnerability).
- Tampering vectors in the release pipeline (`scripts/release.sh`, `.github/workflows/release.yml`).

Out of scope: detection or classification misses (people the model does not cover), model bias, and issues in
third-party datasets. Report those as normal bug reports.

## Verifying a release

```
codesign -d --entitlements :- --xml /Applications/Sitr.app   # must contain com.apple.security.app-sandbox and nothing under com.apple.security.network.*
codesign --verify --deep --strict --verbose=2 /Applications/Sitr.app
spctl -a -vv --type exec /Applications/Sitr.app              # "accepted", source=Notarized Developer ID
shasum -a 256 -c checksums.txt                                 # from the GitHub release, next to the downloaded DMG
```

The absence of `com.apple.security.network.client` and `.server` means the kernel refuses every socket the process
could try to open. CI enforces this on every build with `scripts/check-entitlements.sh`, and the bundled models are
pinned by SHA-256 in `Models/dist/CHECKSUMS*.txt` and checked by `swift test`.
