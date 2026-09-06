# Changelog

All notable changes to Sitr are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). When a tag `vX.Y.Z` is pushed,
`.github/workflows/release.yml` copies the `[X.Y.Z]` section below into the draft release notes, so keep one section
per version and move `Unreleased` entries into it before tagging.

## [Unreleased]

## [0.1.1] - 2026-09-06

### Added
- **Use Default Settings** on the first onboarding screen: one click applies the defaults (hide everyone with Strict
  Mode on, the recommended app rules, launch at login) and leaves only the Screen Recording permission, which is then
  the last step. **Customize** still walks the five steps, and Back from the shortened path restores the full flow.

## [0.1.0] - 2026-09-06

First public release.

### Added
- Menu bar app that detects people on screen and covers them, fully on-device: App Sandbox with no network
  entitlement, Hardened Runtime, no telemetry, no screen pixels written to disk or logs.
- Person detector (YOLOX-S, Apache-2.0) and face-gender classifier (FairFace ViT, Apache-2.0) as bundled Core ML
  models, with a checksum test that fails CI if a shipped model file changes.
- Three protection modes with a Default Rule and per-app overrides: Blur, Curtain (fail-closed pre-cover for
  browsers and messaging apps) and Off (the app is excluded from capture entirely).
- Recommended preset for eight common apps, and a Rules tab to add apps from the running list or from Finder.
- Reveal Hold (⌃⌥Space by default) to uncover the screen while the shortcut is held.
- Five-step onboarding, Settings (Protection, Appearance, Shortcuts, General, About), and a menu bar with pause,
  disable and auto-resume.
- English and Arabic throughout, including right-to-left layout, with a CI gate on translation completeness.
- Low Power Mode support (capture drops to 8 fps) and a Degraded state when detection stops keeping up.
- Robustness: sleep/wake, screen lock, fast user switching, display hot-plug and mirroring reconciliation, with
  capped restart backoff.
- Release tooling: `scripts/release.sh` (Developer ID signing, notarization, stapling, Gatekeeper and entitlement
  checks), `scripts/make-dmg.sh` (UDZO DMG with `/Applications` link and `checksums.txt`), and a tag-driven
  `release.yml` workflow that publishes a draft GitHub release.
- Homebrew cask `packaging/homebrew-sitr/Casks/sitr.rb` (livecheck on GitHub releases, `zap` for the defaults domain,
  the sandbox container and Application Support) and `scripts/bump-cask.sh`, which the release workflow runs on a `v*`
  tag to push the version and checksum into the `homebrew-sitr` tap.
- `LICENSE` (GPL-3.0-only), `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, `CONTRIBUTING.md`, GitHub issue templates.

### Known limitations
- Detection recall is 84.5 % overall and 88.5 % for bodies at least 80 px tall; gender misclassification is 5.6 %.
  Both are short of the PRD's 95 % / 2 % targets — see `docs/bench.md` for the measured tables.
- CPU during full-screen video with people on it is 26–28 % of one core against a 25 % target; browsing and
  near-static screens are well inside budget (5.6 % and 0.5 %). See `docs/perf.md`.
- A person inside a monitored window is not covered when an Off window sits over the middle of their detection box,
  because attribution uses the box centre. Described in `docs/behaviour.md`.
- Measured on an M3; the 8 GB M1 floor in the PRD has not been re-measured.

[Unreleased]: https://github.com/haithamassoli/Sitr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/haithamassoli/Sitr/releases/tag/v0.1.0
