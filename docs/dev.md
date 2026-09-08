# Sitr — developer notes

## Layout
- `Package.swift` — one SwiftPM package. No `.xcodeproj` is committed; open `Package.swift` in Xcode or use the CLI.
  - `Sources/SitrCore` — pure Swift (Policy, Tracker, Curtain, geometry, state machines). No AppKit, no Vision.
  - `Sources/SitrDetect` — Vision / CoreML / CoreImage wrappers. No AppKit.
  - `Sources/SitrSpike` — `sitr-spike` M1 measurement rigs, one file per rig.
  - `Sources/Sitr` — the app (added in M2). Bundle assembled by `scripts/build-app.sh`.
  - `Tests/` — Swift Testing (`import Testing`).
  - `Models/` — classifier research and conversion scripts; `Models/dist/` holds the shipped model + LICENSE.
  - `Bench/` — evaluation manifests and scripts. Images are downloaded by script, never committed.
  - `docs/` — PRD, tasks, spike notes (`docs/spike/*.md`), reports.

## Commands
```
swift build                      # everything
swift test                       # SitrCore + SitrDetect tests
swift run sitr-spike <rig> ...   # M1 rigs
```

For a timed check over a real browser, run `build/Sitr.app/Contents/MacOS/Sitr --selftest live --mode curtain --seconds 60`
(or `--mode blur`), then switch the video between windowed and fullscreen playback. This uses temporary rules and test
preferences, hides Everyone, prints health/layer counts and pipeline timings, and exits automatically. It does not change
the user's protection settings. A passing exit confirms capture and processing, not complete person-detection recall.

## Rules for every change
- Swift 6 language mode, strict concurrency, zero warnings in `SitrCore`.
- Never write screen pixels to disk or logs. Logs carry timings and counts only.
- Deliberate shortcuts carry `// ponytail: <ceiling>, <upgrade path>`.
- Do not edit `Package.swift` or `Sources/SitrSpike/main.swift` from a task; ask the orchestrator (report the need).
- Non-trivial logic leaves one runnable check behind (a `@Test` or a self-check subcommand).

## Testing on this machine
- Screen Recording: this terminal already has the grant, and child processes inherit it. Run binaries directly
  from the shell (`swift run …`, `.build/debug/...`, `build/Sitr.app/Contents/MacOS/Sitr`). Never launch via `open`
  during automated tests — that makes the app its own TCC subject and blocks on a dialog nobody can click.
- Hardware: Apple M3, 24 GB, one built-in display 2560×1664 Retina (scale 2). Two-display checks are recorded as pending.
- Every rig and test binary must exit on its own (`--seconds N`) and remove every window/panel it created.
- Never open, close, or type into the user's own apps (Safari, Telegram, …). Use a window the rig creates itself.
- Performance numbers are collected in a dedicated quiet phase with nothing else running. Numbers taken while other
  agents build or download are marked "noisy".
