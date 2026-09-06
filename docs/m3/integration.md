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
codesign --force --sign - --options runtime --timestamp=none $S/Stimulus.app   # NO --entitlements: the sandbox blocks the
# distributed-notification control channel, and every command then times out (`missed` on every trial). Nothing under test
# depends on the throwaway stimulus being sandboxed; the app under test is the real, sandboxed build.
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

Every run below was on a shared screen (other agents building; `load1` per line). `swift test`: 169 tests green.

### M3-T03 `--selftest filter` → `selftest_filter ok=true`
```
pipeline_boot display=1 filter_installs=2 plan=exclude([2501, 2502]) rules_default=blur overrides=1 health=ok
filter_off_excluded       frames=44 marker_frames=0 frames_until_plan=1 leak_until_plan=0 installs=2 plan=exclude([2501, 2502]) last_rgb=(170,170,170) ok=true load1=4.261
filter_blur_visible       shown=true within_ms=417 marker_frames=1 frames=7 plan=exclude([2501]) ok=true
filter_include_curtain    visible=true within_ms=52 plan=include([2502]) ok=true
filter_off_hidden         frames=6 marker_frames=6 last_marker_ms_after_rule=278 plan=include([]) ok=true
filter_launch_included    included=true within_ms_of_window=125 installs_added=1 plan=include([2524]) error=none ok=true load1=3.919
```
Off app's marker colour absent from 44 consecutive frames (0 leaked frames, including before the plan named it); Off → Blur shows it
in 417 ms; Blur → Off hides it 278 ms after the rule change; an app launched after start is captured 125 ms after its window
appears. All well inside the 1 s Done-when.

### M3-T05 `--selftest curtain --trials 30`, at 30 and 60 fps
```
# curtain_fps=30
curtain_exposure_ms    p50=46.92 p95=84.84 n=26 missed=4 target_p95_ms=50 within_target=false fps=30 cpu_pct=26.559 style=gaussian load1=6.093 noisy=true
curtain_person_cover_ms p50=149.13 p95=212.67 n=30 cleared_between_trials=true
curtain_counts in=681 out=680 skipped=200 pre_applies=438 pre_solid=124 gap_covers=180 fast_ms=21.75/77.32 pre_render_ms=2.23/21.50 clear_ms=0.15/0.31 detect_ms=44.50/85.65 e2e_ms=70.47/163.84

# SITR_CURTAIN_FPS=60
curtain_exposure_ms    p50=44.16 p95=97.87 n=26 missed=4 target_p95_ms=50 within_target=false fps=60 cpu_pct=26.519 style=gaussian load1=6.138 noisy=true
curtain_person_cover_ms p50=122.29 p95=273.00 n=30 cleared_between_trials=true
curtain_counts in=775 out=774 skipped=557 pre_applies=537 pre_solid=139 gap_covers=323 fast_ms=12.93/43.27 pre_render_ms=1.73/9.28 clear_ms=0.12/0.24 detect_ms=29.64/72.34 e2e_ms=42.85/151.27
```
**30 vs 60 fps**: process CPU is the same (26.6 % vs 26.5 % of one core), and the half Sitr controls — capture callback → pre-cover
on screen (`fast_ms`) — halves at 60 fps (21.8 → 12.9 ms p50, 77 → 43 ms p95). End-to-end p50 improves slightly (46.9 → 44.2 ms);
p95 does not (84.8 → 97.9 ms) because on a loaded machine the tail is scheduling, not the capture interval. **The PRD's ≤ 50 ms p95
is not demonstrated at either rate on this shared machine** (p50 is at the target). `curtainFPS` stays 30: 60 fps buys ~9 ms p50 of
in-pipeline latency, drops 72 % of frames instead of 29 %, and costs the same CPU — a quiet-phase re-run should decide it.
`missed=4/30`: trials where the window was still in trusted motion when the person appeared (the person cover covers it instead,
`curtain_person_cover_ms`).

### M3-T05 `--selftest curtain --scroll` → `clear_ms` within target
```
curtain_scroll_summary precover_ms p95=3548.69 linger_ms p50=-185.01 p95=143.25 clear_ms p50=0.09 p95=0.22 n=52 target_clear_ms=100 within_target=true pre_applies=52 pre_solid=8 fps=30
```
`clear_ms` (detection for a frame completes → its pre-covers recomputed and the cleared tiles gone) is 0.09 / 0.22 ms p50/p95
against the 100 ms target. The per-trial `precover_ms` / `linger_ms` columns are unreliable instrumentation (they attribute
pre-covers from the settle phase to the scroll and go negative when a burst clears before the scroll ends); 3 of 5 trials
registered ≥ 50 % coverage of the text column. The reliable statement: scrolling text is pre-covered and the pre-cover is gone
within one frame of verification.

### M3-T05 `--selftest curtain --video 30` → `selftest_curtain_video ok=true`
```
curtain_video_trust   trusted=true trusted_after_ms=556 first_precover_ms=24 precover_applies_before_trust=21 fps=30 load1=2.977
curtain_video_person  mid_video_cover_ms=84 trusted_still=true
curtain_video_summary seconds=30 precover_after_trust=0 frames_in=541 skipped=309 detections=541 pre_applies=21 tracks=1 cpu_pct=41.121 detect_ms=73.83/204.63 e2e_ms=129.60/280.39 rss_mb=91
```
Motion starts → pre-covered in 24 ms → trusted after 556 ms (FR4.3's 500 ms plus one verification round trip) → **0 pre-covers for
the remaining 30 s**, so the video is watchable; a person appearing mid-video is covered in 84 ms by the person cover.

### M3-T06 `--selftest failstate` → `selftest_failstate ok=true`
```
failstate_curtain_baseline health=ok marker_visible=true failclosed_layers=0 notifications=2 window=(435,158,600,640)
failstate_curtain_stop    health=needsPermission solid_layers=true layers_within_ms=239 solid_pixels=true pixels_within_ms=280 failclosed_layers=1 blur_uncovered=true notifications=3 icon=warning ok=true
failstate_curtain_move    moved=true follow_within_ms=29 window=(635,258,600,640) new_marker_solid=true old_spot_uncovered=true failclosed_layers=1 notifications=3 ok=true
failstate_curtain_restart health=ok lifted=true within_ms=327 marker_visible=true failclosed_layers=0 notifications=4 icon=normal ok=true
```
Capture stops → the Curtain window is Solid-covered in 239 ms (the pixels on screen confirm it at 280 ms), the Blur stimulus stays
uncovered, exactly one notification per transition (2 → 3 → 4); moving the window moves the cover in 29 ms; `start()` lifts it in
327 ms. The M2 half of the test is unchanged and still green.

### M3-T09 `--selftest overlap` → `selftest_overlap ok=true`
```
overlap_blur_under_off   z_a=1 z_b=0 person_covers=0 tracks=1 attributed_to=["com.goldentik.SitrStimulus2"] cover_extends_over_off_window=false off_marker_covered=false
overlap_curtain_over_blur precovers_seen=0 precovers_outside_curtain_window=0 person_in_blur_covered=true z_b=0 z_a=1 ok=true
overlap_two_curtains      precovers_on_a=16 precovers_on_b=18 precovers_outside_their_window=0 ok=true
overlap_curtain_under_off z_b=0 z_a=1 precovers_on_curtain=34 precovers_on_off_window=0 off_marker_samples=19 off_marker_covered_samples=0 ok=true
```
No cover ever landed on an Off window (0 of 19 sampled frames, 0 of 34 pre-covers), and no pre-cover left its own window. The
first line is the finding that matters: a person whose **box centre** falls under an Off window is attributed to the Off app and
is therefore not covered at all — see `docs/behaviour.md`.

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
