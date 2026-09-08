# Changelog

All notable changes to Sitr are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). When a tag `vX.Y.Z` is pushed,
`.github/workflows/release.yml` copies the `[X.Y.Z]` section below into the draft release notes, so keep one section
per version and move `Unreleased` entries into it before tagging.

## [Unreleased]

## [0.1.3] - 2026-09-08

### Added
- Menu bar and Settings now name the actual protection state instead of only "Protected": preparing, no apps
  configured, waiting for a protected app, recovering capture, limited detection, detection failed, applying rules —
  each with one line saying what is and is not covered right now.
- A recovery action next to that state: **Open Screen Recording Settings**, **Retry Protection**, or **Configure
  Protected Apps**, the same in the menu and in Settings.
- **Protection scope** line (all apps / all apps except overrides / selected apps), so the Default Rule's effect is
  readable without opening the Rules table.
- Rules failures are visible and recoverable: an unreadable rules file leaves the original untouched and offers
  **Retry Reading Rules** or **Reset Rules…**; a failed save says the change applies until quit and offers a retry.
- Launch-at-login and **Relaunch now** failures report instead of silently doing nothing.
- Setup summary after onboarding, an appearance reset, and an empty-state line in the Rules table.

### Fixed
- Curtain: a frame whose only changes were too small to be a person no longer skipped verification while a pre-cover
  was up, which could leave a Curtain window covered after the content under it was already verified safe.
- Onboarding, degraded-state and permission copy now matches the state the app is actually in.

### Changed
- Hiding **Everyone** skips face detection and the gender classifier entirely — no per-frame work whose answer cannot
  change a cover.
- Detection models can be swapped at runtime, so a model that finishes loading late upgrades protection in place
  instead of requiring a relaunch.
- Amended targets recorded in the docs: Curtain exposure p95 ≤ 60 ms (was 50), bench recall ≥ 90 % for bodies ≥ 80 px
  and misclassification ≤ 6 % for the v1 classifier. `docs/improvement-plan.md` records the measurement protocol and
  the remaining gaps; the M1 8 GB re-take is still outstanding.

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
