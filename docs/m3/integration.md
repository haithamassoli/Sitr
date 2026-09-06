# M3 integration — filters (M3-T03), Curtain fast path (M3-T05), fail-closed (M3-T06), overlap (M3-T09)

Wires the M3 building blocks (`Rules`, `Curtain`, `WindowTracker`) into the running app and proves them with selftests that use
a **second process** as the stimulus. Behaviour decisions for overlapping windows are in `docs/behaviour.md`.

## Files
- `Sources/Sitr/Capture/FilterBuilder.swift` (new) — `FilterPlan` (pure: rules + app list → include / exclude pid list) and
  `FilterBuilder` (`SCShareableContent` → one `SCContentFilter` per display → `CaptureSession.updateFilter`, live).
- `Sources/Sitr/Pipeline/Pipeline.swift` — `CoverID` (reserved layer-id ranges), `captureFPS`, `failClosedSpecs`, the Curtain fast
  path, per-detection attribution, the fail-closed merge, new metrics (`pre_applies`, `pre_layers`, `pre_solid`, `fast_ms`,
  `pre_render_ms`, `clear_ms`), `onPreCover` hook, `trustedCurtainWindows`.
- `Sources/Sitr/SitrApp.swift` — `Runtime` owns a `WindowTracker` and a `FilterBuilder`; pushes window snapshots to the pipelines;
  switches the capture rate per display; stall watch, fail-closed rects, `isStalled` (pure).
- `Sources/Sitr/Windows/WindowTracker.swift` (additive) — `[WindowRect].topmost(at:on:)`, `occluders(of:)`, `subtract(_:holes:)`.
- `Sources/Sitr/Overlay/OverlayPanel.swift` (additive) — `coverFrames` read hook.
- `Sources/Sitr/Selftest.swift` — `--selftest stimulus --remote`, `filter`, `curtain [--trials N | --scroll | --video S]`,
  `overlap`, the Curtain half of `failstate`; `bootRuntime` now uses a throwaway rules directory and the builder's selftest mode.
- `Tests/SitrTests/M3IntegrationTests.swift` — 11 tests (plan decisions, id ranges, attribution, clip, fail-closed rects, fps rule, stall).

## How it works

### Filters (M3-T03)
`FilterPlan.compute(rules:apps:ownPID:)`: Default Rule Off → `.include(pids of apps whose override is Blur / Curtain)`, our own
process never included; Default Rule on → `.exclude(pids of Off apps + our own)`. `FilterBuilder.refresh()` fetches
`SCShareableContent` once, builds the plan, and installs `SCContentFilter(display:including:exceptingWindows:)` or
`(display:excludingApplications:exceptingWindows:)` on every display whose signature changed (`CaptureSession.updateFilter`, no
restart). Triggers: `rules` (set from `AppModel.onPolicyChanged`) and `NSWorkspace` launch / terminate, both debounced 300 ms; the
first install and a change in the set of window-owning pids (`Runtime.windowsChanged`, from the 10 Hz tracker) refresh at once —
`SCShareableContent.applications` lists an app only once it owns a window, so a launch notification alone can come too early.

Selftest mode (`capturesOwnWindows`): our process stays excluded (the overlay panels must never feed back), every own window that is
not an overlay panel is excepted back in (`exceptingWindows`), so the in-process `Stimulus` panels of the M2 selftests are still
captured. `Harness.track` → `filters.schedule()` re-fetches when a selftest creates a window.

**Connect race (needs a `CaptureSession` fix, reported):** `updateFilter` while `connect()` is between `SCStream(...)` and
`stream = s` only stores the filter — `stream` is still nil — so the very first install could be lost and the stream ran with the
default own-process exclusion. `Runtime.sessionBecameOK` re-installs on every stopped → ok edge (250 ms health poll + one fetch);
`filter_off_excluded … leak_until_plan` below counts the frames that slipped through at startup.

### Curtain fast path (M3-T05)
Per frame, before detection (`Pipeline.run` step 0): the tracker snapshot is filtered to this display's Curtain windows
(`rules.mode(for:) == .curtain`), fed to one `Curtain` per bundle id (`windowChanged` / `windowClosed`), `dirty(rects: frame.
dirtyRectsInDisplayPoints, seq:, now:)`, `preCovers()` → each rect clipped to its window's visible region (`subtract` against the
windows above it) → `CoverRenderer.render` in the active style, no padding → one `panel.apply` with the current person covers.
Rendering past 5 ms in a frame makes the remaining pre-covers Solid (`pre_solid` counts). After detection (step 5): `verified(seq:,
hiddenRects: person cover frames)` → pre-covers recomputed → one commit with person covers + pre-covers. Pre-cover layer ids are
`CoverID.preCover(n)` = -1, -2, …; fail-closed ids sit below `-(1 << 40)`; track ids are ≥ 1.

Attribution: `PersonObservation.bundleID = snapshot.topmost(at: box centre, on: display)?.bundleID`; `Policy.covers` resolves Blur
vs Curtain per app. Capture rate: `captureFPS` → `Runtime.curtainFPS` (30; `SITR_CURTAIN_FPS` overrides) while the display shows
≥ 1 Curtain window, 15 otherwise (`CaptureSession.fps`, live).

### Fail-closed (M3-T06)
`Runtime.refreshFailClosed()` → `failClosedSpecs(windows:rules:displayID:color:)` (one Solid spec per visible piece of every Curtain
window; Blur apps nothing) → `Pipeline.update(failClosed:)`, which re-applies at once and carries the specs along with every later
apply, so the pipeline stays the panel's only writer. Active while `health == .needsPermission` or the display is `stalled`; refreshed
on every tracker change (10 Hz), so the covers follow window moves; the first committed frame lifts them. Stall: a Curtain window
changed (`curtainChangedAt`) and no frame was committed within 1 s (`Runtime.isStalled`) → `.degraded` (warning icon, one
notification) + fail-closed covers; the next frame clears both. A stall is *not* reported as `.needsPermission`: that would reopen
onboarding and drop every Blur cover for what may be a hiccup (`// ponytail:` in `checkStall`; M4-T07 owns the degraded strings).

## Stimulus.app (the second process)
```
scripts/build-app.sh --debug
S=/path/to/scratch
rm -rf $S/Stimulus.app && cp -R build/Sitr.app $S/Stimulus.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.goldentik.SitrStimulus" -c "Set :CFBundleName Stimulus" $S/Stimulus.app/Contents/Info.plist
cp Sources/SitrSpike/Fixtures/person.jpg $S/Stimulus.app/Contents/Resources/   # the sandboxed copy cannot read the checkout
codesign --force --sign - --options runtime --timestamp=none --entitlements App/Sitr.entitlements $S/Stimulus.app
# Stimulus2.app: same with com.goldentik.SitrStimulus2
```
`Stimulus.app/Contents/MacOS/Sitr --selftest stimulus --remote [--seconds N]` shows a 600×640 pt normal-level window (magenta
marker, text column, person photo at 0.8, block "video") and takes commands as distributed notifications
`<bundleID>.cmd.<person_on|person_off|scroll|video_on|video_off|move|front|origin|quit>` (fixed names — a sandboxed app cannot
observe all names; `origin` takes "x,y" in `object`), answering `<bundleID>.done.<command>.<CACurrentMediaTime>` after its flushed
transaction. The tests pass `--stimulus <path>` / `--stimulus2 <path>` (or `SITR_STIMULUS_APP` / `SITR_STIMULUS2_APP`), run from
`.build/debug/Sitr` (models via the `#filePath` fallback), and terminate the stimulus on exit. Every run needs the screen to itself:
another process's window over the stimulus changes what the pixel checks see.

## Results (Apple M3, macOS 26.6.2, 1470×956 pt @2×; load1 per line; "shared screen" where noted)

RESULTS_PLACEHOLDER

## Pending / manual
- Real TCC revoke with Safari as Curtain (Finder-launched build, `tccutil reset ScreenCapture com.goldentik.Sitr`): the code path is
  the one the selftest drives through `session.stop()` + `markRevoked()`.
- A real stream stall (frames stop while the stream stays `.ok`) cannot be forced from outside `CaptureSession`; `isStalled` is unit-tested.
- Two displays (a Curtain window on one display only → 30 fps there, 15 on the other): rule unit-tested, no hardware.
- Quiet-phase numbers: every run below happened with other agents building (load1 noted).

## Needs from other owners
- `CaptureSession.connect()`: after `stream = s`, apply `customFilter` when it changed during the connect (the race above); and
  `updateFilter` could skip the stream call when `stream == nil` explicitly. Until then `Runtime.sessionBecameOK` re-installs.
- `CaptureSession` env overrides (another agent): `Runtime.windowsChanged` sets `fps` on every tracker change; a Low Power / env
  override should win there or the two will fight (suggest: `CaptureSession` clamps `fps` internally).
- `Notifier` / M4-T07: a stall reads as "Detection is running slowly" — a "Screen capture stalled" string would be right.
- `docs/tasks.md`: tick M3-T03, M3-T05, M3-T06, M3-T09 per the results.
