# M5 — Cutting a release (M5-T01, T02, T03, T07)

How a tag becomes a notarized DMG on GitHub Releases, which secrets make that happen, and what has actually been
verified on this machine versus what waits for Developer ID / notarytool credentials.

## Pieces

| File | Job |
|---|---|
| `scripts/build-app.sh [--debug] [--sign=<id>]` | Assembles `build/Sitr.app` from the SwiftPM build, compiles the two `.mlpackage`s in, signs (ad-hoc by default, `--timestamp` for real identities, Hardened Runtime, sandbox entitlement). `VERSION=x.y.z[-pre]` stamps `CFBundleShortVersionString` (full string) and `CFBundleVersion` (numeric part). |
| `scripts/release.sh [--dry-run]` | Wipes `build/`, calls `build-app.sh --sign="$SIGN_ID"`, `codesign --verify --deep --strict`, zips with `ditto`, `notarytool submit --wait`, `stapler staple` + `validate`, `spctl -a -vv --type exec`, `scripts/check-entitlements.sh`. `--dry-run` (implied by `SIGN_ID="-"`, the default) skips notarize/staple and prints the commands; `spctl`'s rejection is reported as expected. |
| `scripts/make-dmg.sh` | `build/Sitr-<version>.dmg`: `hdiutil` UDZO, HFS+, volume `Sitr`, `Sitr.app` + `/Applications` symlink. Mounts it read-only, checks both entries and the app signature, detaches, writes one `shasum -a 256` line to `build/checksums.txt` (replacing an earlier line for the same file) and re-verifies with `shasum -c`. |
| `.github/workflows/release.yml` | On `v*` tags or `workflow_dispatch` (version input): Xcode 26, `swift test`, certificate import into a temporary keychain, `release.sh`, `make-dmg.sh`, draft GitHub release (`gh release create --draft`) with the DMG, `checksums.txt` and the matching `CHANGELOG.md` section. |
| `CHANGELOG.md` | Keep a Changelog. The `## [X.Y.Z]` section becomes the release notes; `Unreleased` collects work in progress. |
| `Tests/SitrDetectTests/ModelChecksumTests.swift` | CI enforcement of `Models/dist/CHECKSUMS*.txt`: every listed file is re-hashed (CryptoKit) and every file inside every shipped `.mlpackage` must be listed. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/` | Compliance and project hygiene (M5-T07). |

## Cutting a release

1. Move the `Unreleased` entries in `CHANGELOG.md` into a new `## [X.Y.Z] - YYYY-MM-DD` section and commit.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. (Or run the "Release" workflow manually with the
   version input; the tag is then created when the draft is published.)
3. Watch the "Release" workflow. It ends with a **draft** release named `Sitr X.Y.Z` carrying `Sitr-X.Y.Z.dmg` and
   `checksums.txt`. Review the notes, download the DMG once and run the verification commands from `SECURITY.md`,
   then publish the draft.
4. Homebrew cask bump (M5-T04) and README (M5-T06) follow on their own tracks.

Locally, the same thing with real credentials:

```
xcrun notarytool store-credentials sitr-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer uuid>
VERSION=0.1.0 SIGN_ID="Developer ID Application: Haitham Assoli (TEAMID)" NOTARY_PROFILE=sitr-notary scripts/release.sh
scripts/make-dmg.sh
```

and without credentials (what runs here and on forks):

```
VERSION=0.1.0 scripts/release.sh --dry-run && scripts/make-dmg.sh
```

## Secrets to add (repository → Settings → Secrets and variables → Actions)

| Secret | Content | How to produce it |
|---|---|---|
| `DEVELOPER_ID_P12` | base64 of the "Developer ID Application" certificate + private key, `.p12` | Keychain Access → export the certificate (with its key) as `.p12` with a password → `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password | chosen at export |
| `NOTARY_KEY_ID` | App Store Connect API key ID (10 characters) | App Store Connect → Users and Access → Integrations → App Store Connect API → Team key with the Developer role |
| `NOTARY_ISSUER` | Issuer ID (UUID) of that key | same page |
| `NOTARY_KEY_P8` | the full contents of `AuthKey_<KEY_ID>.p8` | downloaded once when the key is created |

The workflow imports the `.p12` into a throw-away keychain (`security create-keychain` / `import` /
`set-key-partition-list`, deleted in the last step), fetches Apple's Developer ID G2 intermediate in case the export
lacked the chain, picks the `Developer ID Application:` identity automatically and hands `release.sh`
`NOTARY_KEY_ID` / `NOTARY_ISSUER` / `NOTARY_KEY_PATH`. `release.sh` also accepts `NOTARY_PROFILE` for the
`notarytool store-credentials` form used locally.

When any of the signing secrets is missing the workflow prints a `::notice::`, signs ad-hoc, skips notarization and
still produces a draft titled `Sitr X.Y.Z (unsigned)` whose notes start with a warning. A tag on a fork therefore
yields an unsigned draft, not a red run.

## Verified here (macOS 26.6.2, Xcode 26.6, ad-hoc identity)

- `swift build`, `swift test` (106 tests, 10 suites), `scripts/build-app.sh --debug` + `scripts/check-entitlements.sh`.
- `VERSION=0.1.0-rc1 scripts/release.sh --dry-run`: plist stamped `0.1.0-rc1` / `0.1.0`; `codesign --verify --deep
  --strict` valid; `build/Sitr-0.1.0-rc1.zip` produced; notarize/staple commands printed; `spctl` rejection reported
  as expected; entitlement gate OK. Second run wipes and rebuilds `build/` identically (idempotent). Both credential
  forms are rendered correctly in the printed command; a real `SIGN_ID` without credentials exits 2 before building.
- `scripts/make-dmg.sh`: `Sitr-0.1.0.dmg` (91 MB, UDZO, HFS+, volume `Sitr`), mount check passes, `shasum -c` OK,
  running it twice leaves exactly one line in `checksums.txt`, nothing left mounted. First attempt with the default
  filesystem failed with "No space left on device" (APFS auto-sizing), hence the explicit `-fs HFS+`.
- Clean checkout: the worktree commit cloned into a temp directory, `VERSION=0.1.0 scripts/release.sh --dry-run &&
  scripts/make-dmg.sh` produced `build/Sitr.app`, `build/Sitr-0.1.0.zip`, `build/Sitr-0.1.0.dmg`, `build/checksums.txt`.
- `ModelChecksumTests`: passes on the shipped models (0.3–0.7 s); proven red by corrupting one hex digit in
  `Models/dist/CHECKSUMS.txt` (`SHA-256 mismatch for GenderClassifier.mlpackage/.../model.mlmodel`), then restored.
- `actionlint` 1.7.12 on `release.yml`: clean (the shared Xcode-select line carries a `shellcheck disable=SC2012`).
  Issue templates and the workflow parse with PyYAML.
- `LICENSE`: the text after the 16-line project notice hashes to `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`,
  the canonical `gpl-3.0.txt`.

## Pending credentials (cannot be exercised on this machine or in CI until the secrets exist)

- `notarytool submit --wait` acceptance, `stapler staple`/`validate`, and `spctl -a -vv --type exec` returning
  `accepted, source=Notarized Developer ID`.
- Certificate import path of the workflow (the `security` commands are the ones from GitHub's own documentation, but
  they have not run against a real `.p12` here).
- The end-to-end draft release (`gh release create`) — no tag was pushed and no release created from this worktree.
- M5-T08 fresh-account Gatekeeper install check.

## Decisions and shortcuts

- No `xcodebuild archive`: the app is a SwiftPM package with no `.xcodeproj`, so `build-app.sh` is the archive step
  and `codesign` on the bundle is the export. Nothing nested needs signing (no frameworks, models are resources).
- Only the app is notarized and stapled; the DMG is not. Gatekeeper assesses the app at launch, so the stapled ticket
  inside the image is what matters offline. Upgrade path: `notarytool submit Sitr-x.dmg` + `stapler staple` on the DMG
  (add to `release.sh` after `make-dmg.sh`, or a second workflow step).
- `release.sh` wipes `build/` but not `.build/`; CI checkouts are clean anyway, and a local `swift package clean`
  buys nothing. `# ponytail:` markers sit in both scripts.
- `CFBundleVersion` gets the numeric prefix of `VERSION` because Apple wants one to three integers there; the full
  string, pre-release suffix included, goes into `CFBundleShortVersionString`.
- The draft release uses `gh` (preinstalled on runners) rather than a marketplace action; re-running a workflow for
  an existing draft edits it and re-uploads with `--clobber` instead of failing.
- `git remote` in this worktree points at `haithamassoli-plus-connect/Sitr`, while the app's Check-for-Updates URL
  and these docs use `haithamassoli/Sitr` as instructed. The workflow itself only uses `github.repository`, so it
  works wherever it runs; the URLs in `SECURITY.md`, `CHANGELOG.md` and the issue-template config need updating if
  the public repo lives elsewhere.
