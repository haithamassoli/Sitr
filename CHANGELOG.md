# Changelog

All notable changes to Sitr are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). When a tag `vX.Y.Z` is pushed,
`.github/workflows/release.yml` copies the `[X.Y.Z]` section below into the draft release notes, so keep one section
per version and move `Unreleased` entries into it before tagging.

## [Unreleased]

### Added
- Release tooling: `scripts/release.sh` (Developer ID signing, notarization, stapling, Gatekeeper and entitlement
  checks), `scripts/make-dmg.sh` (UDZO DMG with `/Applications` link and `checksums.txt`), and a tag-driven
  `release.yml` workflow that publishes a draft GitHub release.
- Homebrew cask `packaging/homebrew-sitr/Casks/sitr.rb` (livecheck on GitHub releases, `zap` for the defaults domain,
  the sandbox container and Application Support) and `scripts/bump-cask.sh`, which the release workflow runs on a `v*`
  tag to push the version and checksum into the `homebrew-sitr` tap.
- `LICENSE` (GPL-3.0-only), `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, `CONTRIBUTING.md`, GitHub issue templates.
- `ModelChecksumTests`: CI fails if any shipped Core ML model file differs from `Models/dist/CHECKSUMS*.txt`.

## [0.1.0] - Unreleased

Placeholder for the first public release. Fill in before tagging `v0.1.0`.

### Added
- Menu bar app that detects people on screen and covers them with a blur, fully on-device: App Sandbox with no
  network entitlement, Hardened Runtime, no telemetry.
- Person detector (YOLOX-S, Apache-2.0) and face-gender classifier (FairFace ViT, Apache-2.0) as bundled Core ML models.

[Unreleased]: https://github.com/haithamassoli/Sitr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/haithamassoli/Sitr/releases/tag/v0.1.0
