# Contributing to Sitr

Thanks for helping. Sitr is a small GPL-3.0-only macOS app; the rules below keep it buildable and keep its privacy
promise intact. `docs/dev.md` has the longer developer notes, `docs/PRD.md` the product spec, `docs/tasks.md` the plan.

## Requirements

- macOS 15 or later on Apple Silicon, Xcode 26 (Swift 6 toolchain). There is no `.xcodeproj`: open `Package.swift`
  in Xcode or use the command line.
- No third-party dependencies are added without discussion first; the app currently has none.

## Build and test

```
swift build                      # everything
swift test                       # all test targets (Swift Testing)
swift run sitr-spike <rig> ...   # measurement rigs from the spike
scripts/build-app.sh --debug     # assemble build/Sitr.app (ad-hoc signed, sandboxed)
scripts/check-entitlements.sh    # sandbox on, no network entitlement
swift format lint --recursive Sources Tests   # style, config in .swift-format
```

CI (`.github/workflows/ci.yml`) runs build, tests, the app assembly and the entitlement gate on every pull request.

Running the app or the rigs needs Screen Recording permission. Launch binaries from a terminal that already has the
grant (`swift run …`, `build/Sitr.app/Contents/MacOS/Sitr`), never via `open` during automated tests. Rigs and test
binaries must exit on their own and remove every window they create; never drive the user's own apps.

## Rules for every change

- Swift 6 language mode with strict concurrency. Zero warnings in `SitrCore`.
- **No screen pixels on disk or in logs.** Captured frames stay in memory. Logs carry timings and counts only, no
  screenshots, no crops, no debug dumps, not even behind a flag.
- No network code and no `com.apple.security.network.*` entitlement. CI rejects the build otherwise.
- `SitrCore` stays pure Swift (no AppKit, no Vision); `SitrDetect` has no AppKit.
- Non-trivial logic leaves one runnable check behind: a `@Test` or a self-check subcommand.
- Deliberate shortcuts carry a `// ponytail: <ceiling>, <upgrade path>` comment so they can be found later.
- Run `swift format lint` on the files you touched and fix what it reports.
- Bundled models are pinned: changing anything in `Models/dist/` means regenerating `CHECKSUMS*.txt`, updating
  `SOURCE*.md`, the license file and `THIRD_PARTY_NOTICES.md`, and passing `ModelChecksumTests`.
- Only permissively licensed models and data (Apache, MIT, BSD, CC0, CC BY, CC BY-SA). No AGPL or research-only
  weights; every image used for evaluation is recorded in an `ATTRIBUTIONS.md` and never committed.

## Pull requests

- One topic per PR, with the task ID from `docs/tasks.md` in the title when it applies.
- Describe how you verified the change on real hardware (chip, macOS version, display setup) when it touches capture,
  overlay or detection.
- Never attach screenshots or recordings that show people. Use synthetic content or describe what you saw.

## Licensing of contributions

By submitting a contribution you agree that it is licensed under GPL-3.0-only like the rest of the project. No CLA and
no DCO sign-off are required.

## Reporting issues

Use the issue templates in `.github/ISSUE_TEMPLATE/`. Security problems go through GitHub Security Advisories as
described in `SECURITY.md`, not the public tracker.
