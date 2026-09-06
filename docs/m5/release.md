# M5 — Cutting a release (M5-T01, T02, T03, T04, T07)

How a tag becomes a notarized DMG on GitHub Releases and a bumped Homebrew cask, which secrets make that happen, and
what has actually been verified on this machine versus what waits for Developer ID / notarytool credentials and a
tap that does not exist yet.

## Pieces

| File | Job |
|---|---|
| `scripts/build-app.sh [--debug] [--sign=<id>]` | Assembles `build/Sitr.app` from the SwiftPM build, compiles the two `.mlpackage`s in, signs (ad-hoc by default, `--timestamp` for real identities, Hardened Runtime, sandbox entitlement). `VERSION=x.y.z[-pre]` stamps `CFBundleShortVersionString` (full string) and `CFBundleVersion` (numeric part). |
| `scripts/release.sh [--dry-run]` | Wipes `build/`, calls `build-app.sh --sign="$SIGN_ID"`, `codesign --verify --deep --strict`, zips with `ditto`, `notarytool submit --wait`, `stapler staple` + `validate`, `spctl -a -vv --type exec`, `scripts/check-entitlements.sh`. `--dry-run` (implied by `SIGN_ID="-"`, the default) skips notarize/staple and prints the commands; `spctl`'s rejection is reported as expected. |
| `scripts/make-dmg.sh` | `build/Sitr-<version>.dmg`: `hdiutil` UDZO, HFS+, volume `Sitr`, `Sitr.app` + `/Applications` symlink. Mounts it read-only, checks both entries and the app signature, detaches, writes one `shasum -a 256` line to `build/checksums.txt` (replacing an earlier line for the same file) and re-verifies with `shasum -c`. |
| `.github/workflows/release.yml` | On `v*` tags or `workflow_dispatch` (version input): Xcode 26, `swift test`, certificate import into a temporary keychain, `release.sh`, `make-dmg.sh`, draft GitHub release (`gh release create --draft`) with the DMG, `checksums.txt` and the matching `CHANGELOG.md` section. On a `v*` tag it then runs `bump-cask.sh`. |
| `packaging/homebrew-sitr/Casks/sitr.rb` | The Homebrew cask, source of truth. The directory names its destination: repository `homebrew-sitr`, path `Casks/sitr.rb`. `version`/`sha256` here are placeholders (`0.0.0`, 64 zeros) that `bump-cask.sh` rewrites per release. |
| `scripts/bump-cask.sh [--dry-run]` | Renders that cask for `VERSION` with the DMG's SHA-256 (from `build/checksums.txt`, else by hashing `build/Sitr-$VERSION.dmg`, else `SHA256=`) into `build/sitr.rb`, `ruby -c`s it, and pushes it to `$TAP_REPO` as `Casks/sitr.rb`. No `HOMEBREW_TAP_TOKEN` (or `--dry-run`) → prints the rendered cask and exits 0. |
| `CHANGELOG.md` | Keep a Changelog. The `## [X.Y.Z]` section becomes the release notes; `Unreleased` collects work in progress. |
| `Tests/SitrDetectTests/ModelChecksumTests.swift` | CI enforcement of `Models/dist/CHECKSUMS*.txt`: every listed file is re-hashed (CryptoKit) and every file inside every shipped `.mlpackage` must be listed. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/` | Compliance and project hygiene (M5-T07). |

## Cutting a release

1. Move the `Unreleased` entries in `CHANGELOG.md` into a new `## [X.Y.Z] - YYYY-MM-DD` section and commit.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. (Or run the "Release" workflow manually with the
   version input; the tag is then created when the draft is published.)
3. Watch the "Release" workflow. It ends with a **draft** release named `Sitr X.Y.Z` carrying `Sitr-X.Y.Z.dmg` and
   `checksums.txt`, and — on a tag — a cask pushed into the tap. Review the notes, download the DMG once and run the
   verification commands from `SECURITY.md`.
4. Publish the draft. The cask pushed in step 3 points at the release asset, and that URL 404s until the draft is
   published, so publish first, then `brew update && brew install --cask haithamassoli/sitr/sitr`. Once per release
   line, `brew audit --cask --online sitr` too.
5. README (M5-T06) follows on its own track.

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
| `HOMEBREW_TAP_TOKEN` | a token that may push to `haithamassoli/homebrew-sitr` | see "Homebrew tap" below |

The workflow imports the `.p12` into a throw-away keychain (`security create-keychain` / `import` /
`set-key-partition-list`, deleted in the last step), fetches Apple's Developer ID G2 intermediate in case the export
lacked the chain, picks the `Developer ID Application:` identity automatically and hands `release.sh`
`NOTARY_KEY_ID` / `NOTARY_ISSUER` / `NOTARY_KEY_PATH`. `release.sh` also accepts `NOTARY_PROFILE` for the
`notarytool store-credentials` form used locally.

When any of the signing secrets is missing the workflow prints a `::notice::`, signs ad-hoc, skips notarization and
still produces a draft titled `Sitr X.Y.Z (unsigned)` whose notes start with a warning. A tag on a fork therefore
yields an unsigned draft, not a red run. `HOMEBREW_TAP_TOKEN` behaves the same way: without it the cask step prints
the rendered `sitr.rb` and exits 0.

## Homebrew tap (M5-T04)

An own tap rather than the main `homebrew-cask` repo, which has notability requirements Sitr does not meet yet (that
move is in the backlog). `brew install --cask haithamassoli/sitr/sitr` expands to "file `Casks/sitr.rb` in repository
`github.com/haithamassoli/homebrew-sitr`", so the tap is one small repository with one file in it.

**The tap repository does not exist yet.** Steps for the repository owner, once, before the first release:

1. Create a public repository `homebrew-sitr` under the same account that owns `Sitr` — the name must be exactly
   that, `brew tap` derives it from `haithamassoli/sitr`. Give it a README (an empty repository also works, the
   bump script pushes the first commit either way).
2. Create the push token. Either works; the fine-grained one is narrower:
   - Fine-grained PAT (Settings → Developer settings → Personal access tokens → Fine-grained): *Only select
     repositories* → `homebrew-sitr`, Repository permissions → **Contents: Read and write**. Nothing else.
   - Or a classic PAT with the `public_repo` scope.
   The default `GITHUB_TOKEN` cannot be used: it is scoped to the `Sitr` repository and cannot push to another one.
3. In `Sitr` → Settings → Secrets and variables → Actions → New repository secret, name it **`HOMEBREW_TAP_TOKEN`**
   and paste the token. That is the only new secret M5-T04 needs.
4. Optional first fill: `VERSION=X.Y.Z SHA256=<dmg hash> HOMEBREW_TAP_TOKEN=<token> scripts/bump-cask.sh` from a
   checkout does the same thing the workflow step does, or run it with `--dry-run` and copy `build/sitr.rb` into the
   tap by hand.

What the cask says and where each value came from (nothing here is guessed):

| Cask stanza | Source |
|---|---|
| `url .../releases/download/v#{version}/Sitr-#{version}.dmg` | `scripts/make-dmg.sh` names the artifact `Sitr-<version>.dmg`; the tag is `v<version>` |
| `sha256` | the DMG's line in `build/checksums.txt` |
| `livecheck` `:github_latest` + `/^v?(\d+(?:\.\d+)+)$/i` | GitHub releases; the regex ignores pre-release tags such as `v0.1.0-rc1` |
| `depends_on macos: ">= :sequoia"`, `arch: :arm64` | `LSMinimumSystemVersion` 15.0 in `App/Info.plist`; Apple silicon requirement in the README |
| `uninstall quit: "com.goldentik.Sitr"` | `CFBundleIdentifier`; `LSUIElement` means there is no Dock icon to quit through |
| `zap trash: "~/Library/Preferences/com.goldentik.Sitr.plist"` | the `defaults` domain: `Preferences` uses `UserDefaults.standard`, so the domain is the bundle id (`Sources/Sitr/Preferences.swift`) |
| `zap trash: "~/Library/Application Support/Sitr"` | `AppModel.rulesDirectory` (`rules.json`, `rules.json.bak` from `SitrCore.RulesStore`) |
| `zap trash: "~/Library/Containers/com.goldentik.Sitr"` | the app is sandboxed (`App/Sitr.entitlements`), so the two paths above really live inside the container; the plain ones are still listed because an ad-hoc local build writes those instead |
| `zap trash: Caches`, `Saved Application State` | the standard per-bundle-id locations macOS may create |

Not in the cask: the *Launch at login* entry, registered through `SMAppService.mainApp`, which lives in the system
BackgroundItems database — macOS prunes it when the app is deleted, and `zap login_item:` drives System Events and
does not see `SMAppService` registrations. Nor the Screen Recording grant, which is TCC state
(`tccutil reset ScreenCapture com.goldentik.Sitr`). Both are in the README uninstall steps.

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
- Cask and bump script: `ruby -c packaging/homebrew-sitr/Casks/sitr.rb` → Syntax OK; `shellcheck scripts/bump-cask.sh`
  clean, as the other scripts are. `bump-cask.sh` exercised against a throw-away local bare repository standing in for
  the tap (`TAP_URL=file://…`), with a fixture DMG: SHA-256 taken from `build/checksums.txt`, from the DMG itself and
  from `SHA256=`; `VERSION` defaulting to `App/Info.plist`; rendered `build/sitr.rb` re-checked with `ruby -c`; push
  landed exactly `Casks/sitr.rb` with the substituted `version`/`sha256`; a second run detected no change and exited 0;
  no token and `--dry-run` both print the cask and exit 0; a missing or malformed SHA-256 exits 1 before writing.
  A `file://` remote needs no credentials, so the clone/commit/push mechanics are proven but the `GIT_ASKPASS`
  authentication path is not.
- `LICENSE`: the text after the 16-line project notice hashes to `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`,
  the canonical `gpl-3.0.txt`.

## Pending credentials (cannot be exercised on this machine or in CI until the secrets exist)

- `notarytool submit --wait` acceptance, `stapler staple`/`validate`, and `spctl -a -vv --type exec` returning
  `accepted, source=Notarized Developer ID`.
- Certificate import path of the workflow (the `security` commands are the ones from GitHub's own documentation, but
  they have not run against a real `.p12` here).
- The end-to-end draft release (`gh release create`) — no tag was pushed and no release created from this worktree.
- M5-T08 fresh-account Gatekeeper install check.
- Everything about the cask that needs a real published DMG or the tap repository, which does not exist yet:
  `brew audit --cask --online sitr` (it fetches the `url` and compares the `sha256`, so the placeholder values in the
  committed file fail it by construction), `brew install --cask haithamassoli/sitr/sitr`, `brew uninstall --zap`
  actually removing the container, `brew livecheck sitr` (needs at least one published release), and the workflow's
  authenticated push into the tap (`HOMEBREW_TAP_TOKEN` + `GIT_ASKPASS` over HTTPS).
  **M5-T04's "done when" — `brew install --cask <owner>/sitr/sitr` installs the notarized app —
  is therefore not met and cannot be met from here.** What exists is the cask, the bump step, and the manual steps
  above; the first real tag plus a published draft is what turns it green.

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
- The cask lives in this repository and is copied into the tap, rather than being edited in the tap directly: one
  place to review it, and the tap keeps no history worth protecting. `bump-cask.sh` rewrites only the `version` and
  `sha256` lines and refuses if it cannot find them, so a template edit can never be silently dropped. The repository
  copy keeps its `0.0.0` / zeros placeholder — the released values live in the tap, and nothing pushes back here.
- The bump runs during the tagged build, before a human publishes the draft, so for a few minutes the tap points at a
  URL that 404s. Accepted: the alternative is a second workflow on `release: published` that re-downloads the asset to
  hash it. `# ponytail:` marker in `bump-cask.sh`'s header; upgrade path is that second workflow.
- The token reaches `git` through a `GIT_ASKPASS` helper that reads the environment, so it never appears in a remote
  URL, in `.git/config`, or in the process list.
- `git remote` in this worktree points at `haithamassoli-plus-connect/Sitr`, while the app's Check-for-Updates URL
  and these docs use `haithamassoli/Sitr` as instructed. The workflow itself only uses `github.repository`, so it
  works wherever it runs; the URLs in `SECURITY.md`, `CHANGELOG.md`, the issue-template config and the cask's `url` /
  `homepage` need updating if the public repo lives elsewhere. The cask step derives the tap from
  `github.repository_owner`, so a fork would aim at its own `homebrew-sitr` — and skip the push anyway, having no
  token.
