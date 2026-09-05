# M2 Pipeline + fail states (M2-T12, M2-T16, glue of M2-T06/T07)

Connects Track A (permission, displays, capture, overlay, renderer), Track B (`SitrCore` tracker/policy/category,
`SitrDetect` Vision detectors) and Track C (`AppModel`, hot key, menu bar) into the running app, and proves the numbers.

## Files
- `Sources/Sitr/Pipeline/Pipeline.swift` — `PersonDetecting`, `GenderClassifying`, `VisionPersonDetector`, `NoClassifier`,
  `CoverAppearance`, `PipelineMetrics`, `actor Pipeline`, pure `dedupe` / `assignFaces`, `residentMemoryMB`.
- `Sources/Sitr/SitrApp.swift` — `Runtime` (the one wiring: AppModel + PermissionMonitor + DisplayManager + Pipelines + Notifier)
  and the `@main` scene that owns it.
- `Sources/Sitr/Notifier.swift` — one `UNUserNotificationCenter` notification per health transition, lazy authorization, `dryRun`.
- `Sources/Sitr/Preferences.swift` (additive) — `coverStyle`, `blurStrength`, `bodyPadding` with FR3 defaults.
- `Sources/Sitr/Selftest.swift` — `--selftest pipeline [--trials N] | pipeline --motion [--seconds N] | failstate | stimulus [--seconds N]`.
- `Tests/SitrTests/PipelineTests.swift` — dedupe, face assignment, metrics, notifier dedupe, appearance defaults.

## How the app is wired
`SitrApp.init` builds `Runtime(model: AppModel())` and calls `start()` on the first run-loop turn. `Runtime.start()` starts
the `DisplayManager` (which creates one `CaptureSession` + `OverlayPanel` + `CoverRenderer` per `NSScreen` and starts capture
while `PermissionMonitor.state == .granted`), then reconciles one `Pipeline` per `ManagedDisplay` and re-reconciles on every
`displays` change (hot-plug) through `withObservationTracking`. Hooks: `model.onPolicyChanged → pipeline.update(policy)` for
every pipeline (a `Mutex` snapshot read per frame, so the closure stays synchronous and ordered), `model.onRevealChanged →
displayManager.setRevealed`. Appearance follows the three `Preferences` keys the same way. `HotkeyManager` is owned by
`AppModel` (Track C). A 1 s health poll plus the pipelines' per-frame commit hook drive M2-T16 (below).

### Per frame (`Pipeline.run`, one actor per display)
`CaptureSession.frames` (`.bufferingNewest(1)`, `.idle` already dropped) → persons (`PersonDetecting`) and faces
(`FaceDetector`) concurrently, off the actor and off main (nonisolated async), one frame at a time → `assignFaces`
(largest overlap) → `GenderClassifying.pWoman` (hook) → `categorize(face:body:pWoman:)` → `PersonObservation`s in display points
(`Frame.pixelsToDisplayPoints`) → `Tracker.update(at: CACurrentMediaTime(), sequence:)` → `Policy.covers(for:now:)` (merges
overlapping hidden tracks) → `CoverRenderer.render` per cover with style/strength/padding → `OverlayPanel.apply` on the main
actor in one pass → `onCommit(specs, frame, time)` hook.

**Drop-oldest is structural**: the loop awaits detection, and the stream keeps only the newest frame that arrives meanwhile, so
a slow detector skips intermediate frames and no queue can grow. Skipped frames are counted from sequence gaps. An empty cover set
is applied once, then the panel is left alone (static screens cost nothing). When the policy stops protecting (pause, disable,
`needsPermission`) `update(_:)` clears the panel at once, frames or not.

### Plug-in points
- **CoreML person detector (M1-T06b)**: conform in the app (5 lines) —
  `extension CoreMLPersonDetector: PersonDetecting { func detect(in frame: Frame) async throws -> [Detection] { try await detect(in: frame.pixelBuffer) } }`
  and pass `detector:` in `Runtime.reconcile()`'s `Pipeline(...)` call (the default is `VisionPersonDetector()`).
- **Gender classifier (M2-T07)**: a type conforming to `GenderClassifying` (`func pWoman(faceCrop face: Rect, in frame: Frame) async -> Double?`,
  face in capture pixels, the implementation crops with its 20 % margin) passed as `classifier:` instead of `NoClassifier()`.
  Until then every person is `.unknown`, which the placeholder Everyone + Strict policy covers.
- `bundleID` on `Track` / `PersonObservation` (M3): pass `nil` where the initializer gains it; the pipeline has no window attribution yet.

## Fail states (M2-T16)
`Runtime.checkHealth()` every second: `permission.state != .granted`, or a session whose `health` is `.stopped(error)` or
`.stopped(nil)` after it had been `.ok` (a fresh session's initial `.stopped(nil)` is not a failure) → `model.policy.health =
.needsPermission`. `Policy.covers` then returns nothing (Blur fails open), `Pipeline.update` clears the panels, `AppModel`
shows the warning icon, and `Notifier.healthChanged(to:)` posts exactly one notification per transition. Recovery: the first
frame a pipeline commits while permission is granted and every session is `.ok` → `.ok` and one "Protection restored"
notification. `Notifier` requests authorization lazily on the first real post; `dryRun` counts instead. It only touches
`UNUserNotificationCenter` from inside a registered `.app` (`LSRegisterURL` first), because `current()` raises an uncatchable
ObjC exception without a bundle proxy.

## Metrics
`SITR_METRICS=1` prints per display every 5 s: `pipeline display= t= in= out= skipped= detections= errors= applies=
detect_ms=p50/p95 track_ms= render_ms= commit_ms= e2e_ms= tracks= layers= rss_mb= load1=`. Timings and counts only; `e2e` is
capture callback → commit. Without the variable the sample window is capped at 512 entries.

## Verified on this machine (Apple M3, macOS 26.6.2, one built-in display 1470×956 pt @2×; other agents running, load noted)
- `swift build`, `scripts/build-app.sh --debug`: 0 warnings. `swift test`: **78 tests pass** (6 new). Entitlement gate OK.
- `--selftest pipeline --trials 30` (Blur path, Gaussian 0.7, padding 0.15; the M1-T04 method through the production pipeline;
  the selftest excludes only the overlay panel window from capture so its own stimulus window is seen):
  ```
  exposure_ms p50=79.35 p95=129.28 n=30 missed=0 target_p95_ms=150 within_target=true load1=3.174 noisy=false path=blur style=gaussian
  cover_control overlap_min=1.000 overlap_p50=1.000 layers_max=1 covers_cleared_between_trials=true ok=true
  pipeline_counts in=229 out=229 skipped=2 detections=229 errors=0 applies=186 detect_ms=21.40/38.67 track_ms=0.03/0.08 render_ms=2.12/25.73 commit_ms=0.16/0.33 e2e_ms=25.61/57.91
  ```
  The spike's Blur path was 48 / 85 ms (detection only, no tracker/render); the extra ~30 ms p50 is the second Vision handler run
  (upper body), the face request and the Gaussian render. M1 chip: pending.
- `--selftest pipeline --motion --seconds 120` (two moving photos, ~14.6 fps of complete frames, load1 5.5–10):
  ```
  motion t=10  frames_in=144  detections=143  skipped=8  window_skip_ratio=0.053 tracks=2 layers=2 rss_mb=62 detect_ms=30.58/45.75 e2e_ms=52.37/106.20
  motion t=120 frames_in=1753 detections=1753 skipped=16 window_skip_ratio=0.000 tracks=2 layers=2 rss_mb=63 detect_ms=26.36/41.48 e2e_ms=38.01/71.09
  backlog_growth=false rss_mb_first=62 rss_mb_last=63 skip_ratio_first=0.013 skip_ratio_last=0.003 frames_in=1753 skipped_total=16 skip_ratio_total=0.009 layers_max=2
  ```
  The 600 s quiet-phase run is pending (`--seconds 600`).
- `--selftest failstate` (`Notifier.dryRun`):
  ```
  failstate_baseline health=ok covered=true layers=3 notifications=0 icon=normal
  failstate_stop health=needsPermission flipped=true within_ms=967 covers_dropped=true layers=0 notifications=1 icon=warning reveal_available=false permission=granted
  failstate_hold notifications=1 health=needsPermission
  failstate_restart health=ok recovered=true within_ms=107 covers_back=true layers=1 notifications=2 icon=normal session_ok=true
  ```
- Manual-by-code run: `.build/debug/Sitr --selftest stimulus --seconds 30` (a second process drifting the photo; the app's
  own-process exclusion does not hide it) next to `SITR_METRICS=1 build/Sitr.app/Contents/MacOS/Sitr --quit-after 20`
  (load1 15, noisy):
  ```
  pipeline display=1 first_frame_at_ms=453 first_commit_at_ms=546 warmup_ms=216 layers=2
  pipeline display=1 t=5  in=64  out=63  skipped=5 detections=64  errors=0 applies=63  detect_ms=30.95/47.79 track_ms=0.11/0.25 render_ms=14.47/80.89 commit_ms=0.35/0.68 e2e_ms=62.17/138.23 tracks=2 layers=2 rss_mb=94
  pipeline display=1 t=15 in=214 out=214 skipped=8 detections=214 errors=0 applies=214 detect_ms=31.12/40.03 track_ms=0.11/0.14 render_ms=26.91/63.03 commit_ms=0.35/0.88 e2e_ms=73.86/125.68 tracks=2 layers=2 rss_mb=94
  ```
  Covers are up ~0.55 s after the pipeline starts (SCK connect + first frame 453 ms; the Vision warm-up overlaps it); the app
  quit on `--quit-after` with exit 0 and no `Sitr` process left. Gaussian render p95 climbs under GPU contention (M4-T09 caps it).

## Pending manual items
- Real TCC revoke / re-grant (`tccutil reset ScreenCapture com.goldentik.Sitr` on a Finder-launched build): `markRevoked()` keeps
  `granted` here because the shell-launched process inherits the terminal's grant, so the selftest exercises the same health path
  through `session.stop()`; the real cycle and the real (non-dry-run) notification, whose authorization dialog a selftest must
  never trigger, are manual.
- Exposure and the 10 min backlog run in the quiet phase; both on an M1 8 GB machine (PRD baseline).
- Two displays: one `Pipeline` per `ManagedDisplay` follows `DisplayDiff`, verified by code path on this one-display machine.

## Shortcuts (`ponytail:` in code)
- `VisionPersonDetector` runs full and upper body as two concurrent Vision handler runs (SitrDetect keeps its requests internal);
  faces are a third. Replaced wholesale by the CoreML detector. Dedupe: IoU ≥ 0.5 **or** ≥ 80 % contained (an upper-body box
  inside its full-body box would otherwise become a second track; the cover union would be the same).
- `NoClassifier` returns nil until M2-T07.
- A failed detection keeps the previous covers and is counted; M4-T07 turns sustained failures/slowness into `.degraded`.
- Covers persist on a static screen after the person's last frame: no frame means nothing changed, so the last known state is
  the safe one (a timer-based expiry would uncover a person in a still image). The next complete frame expires the track.
- Notification strings are literals (String Catalog in M4-T05); repeat spacing is M4-T07's.
- `LSRegisterURL` before `UNUserNotificationCenter.current()` for shell-launched bundles; a no-op for Finder launches.

## Needs from other owners
- None for `Package.swift`, `SitrCore`, `SitrDetect`. When `CoreMLPersonDetector` lands, add the `PersonDetecting` conformance
  above (app side) and switch the default in `Runtime.reconcile()`.
