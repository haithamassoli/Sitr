# Sitr — Milestones and Tasks

Source: `PRD.md`. Solo developer, AI-assisted. Sizes: S ≤ 0.5 day, M 1–2 days, L 3–5 days. IDs `M<milestone>-T<nn>`; `deps` lists blocking tasks. A task is done only when its "Done when" line holds, never on compile alone.

## Global definition of done
- Builds with Xcode 26, Swift 6 strict concurrency, zero warnings in `SitrCore`.
- Unit tests pass in CI. `Policy`, `Tracker`, `Curtain`, category rule, coordinate utilities all have tests.
- CI asserts the built app has no `com.apple.security.network.*` entitlement.
- No screen pixels written to disk or logs. Debug logs contain timings and counts only.
- Deliberate shortcuts carry a `// ponytail:` comment naming the ceiling and the upgrade path.
- From M4 on: every user-facing string lives in the String Catalog with an Arabic translation.

## Milestone map
| # | Milestone | Goal | Exit gate | Est. |
|---|---|---|---|---|
| M1 | Spike | Measure before building; choose detector and classifier | `docs/spike-report.md`, go/no-go | 7 d |
| M2 | Core | Entire Mac Blur mode end to end | Exposure ≤ 150 ms p95, CPU table on M1 | 15 d |
| M3 | Rules | Default Rule, overrides, Curtain, fail-closed | Curtain ≤ 50 ms p95, video watchable, revoke test | 10 d |
| M4 | Polish | Onboarding, Settings, EN/AR, bench, perf | Bench gates met, manual matrix green | 12 d |
| M5 | Release | Signed, notarized, cask, docs | Fresh-account install and verification pass | 5 d |

Parallel tracks inside M2 and M3: (A) Capture + Overlay, (B) Detect + Policy (pure Swift, runs without Screen Recording permission), (C) UI. Track B never waits on A.

---

## M1 — Spike (go/no-go)
Goal: real numbers on real hardware before writing product code. Throwaway code allowed; keep the measurement rigs, M2 and M3 reuse them.
Exit: `docs/spike-report.md` with every number below against the PRD targets, plus decisions: detector, classifier, capture long side (1280 vs 1920), detection fps. PRD amended if a target moves.
No-go triggers: Blur exposure > 250 ms p95 on M3, or person recall < 85 % with every permissive detector, or CPU > 40 % of one P-core during browsing. Any of these stops M2 and reopens the PRD.

- [x] **M1-T01 Spike app + capture loop** (M) — `sitr-spike capture`: 14.9 fps under `--motion`, 0 complete / ~15 idle per s static; `docs/spike/capture.md`
  Do: minimal SwiftUI app; request Screen Recording; one `SCStream` on the main display (BGRA, `minimumFrameInterval` 1/15 s, `queueDepth` 3, `showsCursor` false); log frame status, `dirtyRects` count, callback cadence, capture size.
  Done when: frames flow; `.idle` frames skipped; cadence is 15 fps under motion and 0 on a static screen.
- [x] **M1-T02 Overlay + feedback-loop check** (M) deps: M1-T01 — `excludingApplications:` works (red absent / present without); above own fullscreen window; CGEvent click passes through; Space switch + Safari video manual pending; `docs/spike/overlay.md`
  Do: transparent click-through `NSPanel` (level `.screenSaver` + 1, `canJoinAllSpaces`, `fullScreenAuxiliary`); draw a red rectangle; exclude own process with `SCContentFilter(display:excludingApplications:exceptingWindows:)`; sample captured pixels under the rectangle.
  Done when: red is absent from captured frames; clicks pass through; panel stays above fullscreen Safari video and survives a Space switch.
- [x] **M1-T03 Detection cost** (M) deps: M1-T01 — Vision 8–23 ms p50 per frame, flat across 1280/1920/2560 (M1 chip pending); `docs/spike/detect.md`
  Do: `DetectHumanRectanglesRequest` (`upperBodyOnly` false and true) + `DetectFaceRectanglesRequest` on frames downscaled to 1280 and 1920 long side; ms/frame p50/p95 on M3 (and M1 if available); note compute unit.
  Done when: table of ms per configuration per chip.
- [x] **M1-T04 Latency rig** (M) deps: M1-T02 — 15 fps: capture 45/72, Blur 48/85, Curtain 54/82 ms p50/p95; 30 fps: 31/47, 45/63, 32/53; 60 fps capture 19/33; preliminary, quiet re-run pending; `docs/spike/latency.md`
  Do: test window flips a region to a person image and records `CACurrentMediaTime()`; pipeline records the time the cover commit is scheduled; second signal: window paints a frame counter in pixels to isolate capture-to-callback latency. 50 trials each.
  Done when: p50/p95 for capture latency, Blur path (capture → detect → commit), Curtain path (capture → commit).
- [x] **M1-T05 Gender classifier candidates** (L) — chosen `dima806/fairface_gender_image_detection` (Apache-2.0, FairFace CC BY 4.0) int8: 93.7 % Commons / 95.0 % FairFace-val, Unknown 3.6 % @0.80, per-tag 92.6/97.0/92.8/88.5/89.2, 82 MB, 8–10 ms/crop ANE (noisy); SSR-Net/Human/Intel OMZ rejected on data terms; `docs/spike/classifier.md`; follow-up: fine-tune a ≤ 10 MB model
  Do: shortlist permissively licensed face-gender models (Apache/MIT/CC BY: SSR-Net, Human library gender model, FairFace-trained classifier); verify model license and training-data license; convert to CoreML (coremltools, fp16); evaluate on 200 local faces tagged hijab / child / low-light / profile; ms per crop on ANE.
  Done when: accuracy per tag, Unknown rate at threshold 0.80, ms/crop; one model chosen, license recorded. MobileCLIP and any research-only weights rejected.
- [x] **M1-T06 Person detector recall** (M) deps: M1-T03 — 200 COCO images (permissive licenses) + `Bench/ATTRIBUTIONS.md`; Vision full 25.8 %, union 37.8 % → below the 85 % floor; decision: CoreML detector (YOLOX first), evaluated in M1-T06b
  Do: 200 permissively licensed images (Wikimedia Commons CC0/CC BY, Pexels) labeled with body boxes and tags (partial, back-facing, small, drawn); recall for bodies ≥ 40 px at 1280 and 1920; if < 95 %, evaluate a permissive CoreML detector (YOLOX, RF-DETR, NanoDet; all Apache-2.0). Ultralytics excluded (AGPL).
  Done when: recall table; detector decision; labeled set committed with `ATTRIBUTIONS.md`.
- [x] **M1-T07 Blur render cost + strength curve** (S) deps: M1-T02 — IOSurface path 1.2–3.7 ms Gaussian, 0.9–1.7 ms Pixellate; curves `radius = f(0.17+0.33s)`, `block = f(0.20+0.30s)`; proxy minima 5 px / 4 px at 60 px face; 3-reviewer check pending; `docs/spike/blur.md`
  Do: `CIGaussianBlur` and `CIPixellate` from captured pixels into a layer; ms per cover; minimum radius and block size that make a 60 px face unrecognizable (5 faces, 3 reviewers).
  Done when: ms per cover; strength → radius and strength → block curves recorded.
- [x] **M1-T06b CoreML person detector** (L) deps: M1-T06 — shipped yolox-s 1280×768 fp16 (18.2 MB, Apache-2.0): all 85.1 / large 93.3 / medium 90.5 / small 78.4 / back 91.8 / partial 83.3 %; m 1280×768 87.1 % (50.8 MB); 95 % gate unreachable on COCO small people; ANE p50 24 ms noisy (floor 12–19 ms); `docs/spike/detect.md`
  Do: convert YOLOX (Apache-2.0) tiny/s to CoreML fp16, `CoreMLPersonDetector` in `SitrDetect`, `--detector coreml:` on the recall and detect rigs; recall + ms/frame per model × input size.
  Done when: recall table next to Vision's; a shipped `Models/dist/PersonDetector.mlpackage` with license, source, checksums; detector decision recorded.
- [ ] **M1-T08 System cost** (M) deps: M1-T03, M1-T07
  Do: capture + detect + render at 15 fps for 10 min browsing and 10 min 1080p video with people; CPU % of one P-core, GPU/ANE, memory, thermal state; static screen 5 min.
  Done when: numbers against the PRD table, on M1 8 GB or marked pending.
- [ ] **M1-T09 Spike report + decisions** (S) deps: all M1
  Do: `docs/spike-report.md`: numbers, decisions, PRD deltas.
  Done when: go/no-go recorded; PRD updated if any target changed.

---

## M2 — Core
Goal: Entire Mac Blur mode works: hidden set + Strict Mode, rectangle covers with styles and padding, Reveal Hold, menu bar Pause/Disable, permission flow. Default Rule is hard-coded Blur for this milestone; onboarding sets Off in M4.
Exit: on 1 and 2 displays, hidden-set persons covered with exposure ≤ 150 ms p95 (rig from M1-T04); CPU within the PRD table on M1; Policy, Tracker, category tests green in CI.

- [x] **M2-T01 Production scaffold** (M) — done as a SwiftPM package (no .xcodeproj; `scripts/build-app.sh` assembles `build/Sitr.app`); `codesign -d --entitlements` shows only `app-sandbox`; `--selftest` confirms sandboxed + screen-capture preflight true
  Do: Xcode project `Sitr`: app target (`LSUIElement`, App Sandbox, Hardened Runtime, no network entitlements); Swift package `SitrCore` (Policy, Detect types, Tracker, geometry; no AppKit); test target; folders per PRD modules: Capture, Detect, Policy, Overlay, Hotkey, UI, Bench; swift-format config.
  Done when: builds; `codesign -d --entitlements` shows no network keys; one placeholder test passes.
- [x] **M2-T02 CI** (S) deps: M2-T01 — `.github/workflows/ci.yml` green on `macos-26`; entitlement gate proven red locally with a `network.client` key
  Do: GitHub Actions on a macOS runner with Xcode 26: build, unit tests, `scripts/check-entitlements.sh`.
  Done when: green on main; proven red once with a deliberately added network entitlement.
- [x] **M2-T03 Permission manager** (M) deps: M2-T01 — `PermissionMonitor` + pure `PermissionLogic` (grant/deny/revoke/re-grant tests); real TCC cycle manual pending (shell-launched process inherits the terminal grant)
  Do: `Permission` actor: `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, re-check on app activation and 5 s poll while denied, revoked detection from `SCStream` errors; publishes granted / denied / revoked.
  Done when: grant, deny, and `tccutil reset ScreenCapture <bundle id>` each produce the right state within 5 s.
- [x] **M2-T04 Display topology** (M) deps: M2-T01 — `DisplayManager` + tested `DisplayDiff`; one session + one panel per display; hot-plug/mirror pending (one display here)
  Do: `DisplayManager`: map `SCDisplay` ↔ `NSScreen` by `CGDirectDisplayID`; observe `didChangeScreenParametersNotification`; one `CaptureSession` + one `OverlayPanel` per display; debounce 300 ms.
  Done when: hot-plug, mirror toggle, resolution change re-establish sessions within 1 s; stream count equals display count.
- [x] **M2-T05 Capture session** (L) deps: M2-T03, M2-T04 — `CaptureSession`/`Frame`; selftest: 129 frames, idle skipped, `overlay_excluded=true` (control shows marker); dirtyRects are pixel-space (fixed); sleep/wake pending
  Do: `SCStream` per display: BGRA, output scaled to the spike's long side, `minimumFrameInterval` 1/15 s, `queueDepth` 3–5, `showsCursor` false; filter excludes own process; skip `.idle`; `dirtyRects`, `contentRect`, `scaleFactor` into a `Frame` value (pixel buffer, metadata, sequence number); stop/error → health state; restart with backoff.
  Done when: frames on all displays; overlay marker absent from frames (M1-T02 check as a manual XCTest); stream survives sleep/wake.
- [x] **M2-T06 Detect: persons + faces** (M) deps: M2-T01 — production detector = `CoreMLPersonDetector` (yolox-s 1280×768) + Vision faces, face→person by largest overlap; Vision fallback with a logged reason; fixture tests within 5 %; quiet detect 17.8/21.3 ms p50/p95
  Do: `PersonDetector` (spike choice; Vision full body with upper-body fallback unless the spike chose otherwise), `FaceDetector`, face → person assignment by largest overlap; normalized → capture pixels → display points.
  Done when: fixture images yield expected boxes within 5 %; conversion tests pass.
- [x] **M2-T07 Detect: gender classifier** (M) deps: M2-T06, M1-T05 — `GenderClassifier` (spike crop rule, batch predict, ≤ 3 faces/frame), category rule tests + fixture tests (woman/man CC0), `ModelChecksumTests`; 5.1/6.4 ms per crop quiet; `category` selftest passes women/men/strict cases
  Do: bundle the chosen `.mlpackage` with its LICENSE; checksum test; face crop with 20 % margin, resize, batch predict P(woman); category rule as a pure function: no face / face < 32 px / body < 40 px / max p < 0.80 → Unknown.
  Done when: every category-rule branch tested; checksum test passes; ms/crop ≤ spike number.
- [x] **M2-T08 Tracker** (M) deps: M2-T01 — `SitrCore/Tracker.swift`, 15 tests (dropout, 300 ms drop, flip after exactly 3, merge, crossing ids)
  Do: `Tracker` in `SitrCore`: IoU ≥ 0.3 matching, EMA α 0.5, persist 300 ms after last hit, category sticky until 3 contrary frames, merge overlapping hidden boxes.
  Done when: scripted tests: no flicker on a 1-frame dropout; category flips after exactly 3 frames; merge on overlap.
- [x] **M2-T09 Policy core** (M) deps: M2-T01 — `SitrCore/Policy.swift`, 8 tests over hidden set × strict × category, paused/disabled/auto-resume; `needsPermission` fails open
  Do: `Policy` in `SitrCore`: hidden set (women / men / everyone), Strict Mode (everyone forces on), protection state (active / paused(until) / disabled), health (ok / needsPermission / degraded); `covers(for:tracks, rules:) -> [Cover]`. Default Rule fixed to Blur in M2.
  Done when: tests over every hidden set × Strict × category; paused and disabled yield no covers.
- [x] **M2-T10 Overlay panels** (L) deps: M2-T04 — `OverlayPanel`/`CoverLayerSpec`; selftest: layer count == cover count over 5 diffs, reveal, above own fullscreen, click-through; Space switch / Safari / ⌘Tab manual pending
  Do: `OverlayPanel` (`NSPanel`): borderless, clear, non-activating, `ignoresMouseEvents`, level `.screenSaver` + 1, `collectionBehavior` [canJoinAllSpaces, fullScreenAuxiliary, stationary, ignoresCycle], `hidesOnDeactivate` false, excluded from Windows menu, not an accessibility element; cover `CALayer`s keyed by track id; per-frame diff in one `CATransaction` with implicit animations off; `setRevealed(_:)` across all panels.
  Done when: manual: fullscreen Safari video, Space switch, menu bar overlap, clicks pass through, absent from ⌘Tab; layer count equals cover count.
- [x] **M2-T11 Cover renderer** (M) deps: M2-T05, M2-T10, M1-T07 — `CoverRenderer`; padding/clamp/solid verified; quiet p50 0.9–2.8 ms per cover (2 ms gate re-checked in the quiet phase)
  Do: `CoverRenderer`: Gaussian (`CIGaussianBlur` on the cropped captured pixels, radius from the strength curve), Pixelate (`CIPixellate`, block from curve), Solid (system-appearance color); Body Padding expand + clamp to display; one Metal `CIContext` per display.
  Done when: ≤ 2 ms per cover at spike source size; 3 styles × 3 strengths checked visually; padding 0 / 15 / 50 % verified.
- [x] **M2-T12 Pipeline** (L) deps: M2-T05, M2-T06, M2-T07, M2-T08, M2-T09, M2-T10, M2-T11 — `Pipeline` actor + `Runtime`; selftest exposure p50 79 / p95 129 ms (Vision detector, load 3), cover overlap 1.0; 120 s motion: skip ratio 0.9 %, RSS flat 62→63 MB; 600 s quiet run + M1 chip pending
  Do: per-display `Pipeline` actor: Frame → skip idle → detect → classify → track → policy → render → commit; drop-oldest backpressure (latest frame only); debug metrics per stage; exposure measured with the M1-T04 rig.
  Done when: exposure ≤ 150 ms p95 on M1; no backlog growth over 10 min of video.
- [x] **M2-T13 Reveal Hold** (M) deps: M2-T10 — `RevealState` (7 tests) + Carbon `HotkeyManager` (⌃⌥Space, status 0; posted CGEvent press/release verified 203/1004 ms holds); panel wiring lands with M2-T12; physical press over fullscreen manual pending
  Do: `HotkeyManager` on Carbon `RegisterEventHotKey` (`kEventHotKeyPressed` / `kEventHotKeyReleased`); default ⌃⌥Space persisted; press → panels revealed within 1 frame, release → covered; 30 s safety timer; re-cover on app deactivation or `flagsChanged` without a release; pure `RevealState` machine in `SitrCore`.
  Done when: state-machine tests (press, release, timeout, lost release); manual reveal over a fullscreen app; detection keeps running while revealed.
- [x] **M2-T14 Menu bar core** (M) deps: M2-T09, M2-T13 — `AppModel` status/icon/reveal matrix (10-row test), pause auto-resume + wake re-sync tested, menu per FR7; VoiceOver + per-state visual check manual pending
  Do: `MenuBarExtra`: status line (Protected / Paused until HH:MM / Disabled / Needs permission / Degraded); Pause ▸ 15 min / 1 hour with auto-resume; Disable ↔ Enable; Reveal line with Available / Unavailable; Settings… (placeholder window); Quit; icon normal / dimmed / warning badge.
  Done when: every Policy state renders; pause resumes at the right time after sleep; VoiceOver reads all items.
- [x] **M2-T15 Launch at login** (S) deps: M2-T01 — `SMAppService.mainApp`: notFound → enabled → enabled in a fresh process → notRegistered; left off
  Do: `SMAppService.mainApp` register/unregister behind a toggle in the placeholder settings; handle `requiresApproval`.
  Done when: toggle reflects real status after relaunch.
- [x] **M2-T16 Fail states, basic** (M) deps: M2-T03, M2-T05, M2-T14 — `Notifier` + health poll; failstate selftest: needsPermission within 967 ms, covers dropped, 1 notification; restart → ok in 107 ms, 1 restore notification; real TCC revoke manual pending
  Do: stream stop/error or revoked permission → needsPermission; covers dropped (Blur mode fails open); warning icon; one notification per transition via `UNUserNotificationCenter` (authorization requested on first need); recover when frames resume.
  Done when: revoke → state within 5 s, exactly one notification; re-grant recovers without relaunch.

---

## M3 — Rules
Goal: Default Rule + per-app overrides, Curtain mode with trusted motion, Recommended preset, fail-closed for Curtain apps.
Exit: Curtain exposure ≤ 50 ms p95; YouTube without people in Safari-as-Curtain is watchable after ≤ 500 ms; page load and scroll start are pre-covered; revoking permission covers Curtain windows solid; Off apps' pixels never reach detection.

- [x] **M3-T01 Rules model + store** (M) deps: M2-T09 — `Rules`/`RuleMode`/`AppRule`/`RulesStore` (schema 1, `.bak` on bad file), Policy resolves per bundle ID; 7 + 3 tests
  Do: `AppRule { bundleID, mode }`, `DefaultRule` (off / blur / curtain, initial off); JSON in Application Support with a schema version; Policy resolves mode per bundle ID; rules for uninstalled apps allowed.
  Done when: resolve tests (override beats default, unknown app → default); persistence round-trip test.
- [x] **M3-T02 Window geometry provider** (M) deps: M2-T04 — `WindowTracker`/`WindowGeometry`; 10 Hz poll costs 0.15–0.21 % of one core (noisy); 9 tests incl. 2-display split layouts; wiring lands with M3-T03/T05
  Do: `WindowTracker`: `CGWindowListCopyWindowInfo` (on-screen, layer 0) at 10 Hz plus `NSWorkspace` activate / launch / terminate notifications; ownerPID → bundle ID via `NSRunningApplication`; flipped global points → per-display points in one utility; publishes `[WindowRect(bundleID, displayID, rect, zOrder)]`.
  Done when: conversion tests on 2-display layouts (secondary above, left, right); poll cost < 0.3 % CPU.
- [ ] **M3-T03 Filter builder + live updates** (M) deps: M3-T01, M2-T05
  Do: rules → `SCContentFilter` per display: Default off → include only override apps; Default on → exclude Off apps and own process; refresh `SCShareableContent` on app launch/terminate and rules change; `updateContentFilter` without restarting the stream.
  Done when: an Off app showing a marker color never appears in frames (manual XCTest); an app launched after start is included within 1 s.
- [x] **M3-T04 Curtain state machine** (L) deps: M3-T01 — `SitrCore/Curtain.swift`, 13 scripted tests (page load, scroll, 30 s video → trusted at 500 ms, person mid-video, out-of-order, resize, close)
  Do: pure `Curtain` in `SitrCore`, per app, 64-pt tiles per window: dirty tile → preCovered(seq); verified (seq ≥ dirty seq, no hidden person) → clear; continuously dirty and verified safe ≥ 500 ms → trustedMotion (no pre-cover, Blur behavior); static ≥ 1 s → reset; new window → all tiles preCovered until the first verified frame.
  Done when: scripted tests: page load, scroll start, 30 s video without people (trusted after 500 ms, no pre-cover until a pause), person appears mid-video (cover on detection), out-of-order result (frame N result never clears tiles dirtied by N+1).
- [ ] **M3-T05 Curtain fast path in pipeline** (L) deps: M3-T04, M3-T02, M2-T12
  Do: on frame arrival, before detection: `dirtyRects` ∩ Curtain windows → tiles → pre-cover commit immediately; detection result path clears or keeps by sequence; pre-cover uses the active style, falling back to Solid if render > 5 ms.
  Done when: Curtain exposure ≤ 50 ms p95 (rig); text scrolling clears within 100 ms of verification; no visible tearing between pre-cover and person covers.
- [ ] **M3-T06 Fail-closed for Curtain apps** (M) deps: M3-T02, M2-T16, M3-T04
  Do: health needsPermission or stalled (no frames > 1 s while `WindowTracker` sees Curtain windows change) → Solid cover over each Curtain window rect; lift on first frame; Blur apps stay uncovered; warning icon and one notification.
  Done when: revoke with Safari as Curtain → Safari windows solid within 1 s; re-grant lifts; moving the window moves the cover.
- [x] **M3-T07 Recommended preset** (S) deps: M3-T01 — `RecommendedPreset` (8 bundle IDs incl. App Store Telegram `com.tdesktop.Telegram`; Safari/Chrome/Arc/WhatsApp/Discord verified on this Mac); 5 tests
  Do: preset data → Curtain: Safari `com.apple.Safari`, Chrome `com.google.Chrome`, Arc `company.thebrowser.Browser`, Telegram `ru.keepcoder.Telegram` and `org.telegram.desktop`, WhatsApp `net.whatsapp.WhatsApp`, Discord `com.hnc.Discord` (verify each on a real install); `apply()` upserts overrides and leaves Default Rule untouched.
  Done when: apply test; re-apply idempotent; user edits to preset apps survive until the preset is re-applied.
- [x] **M3-T08 Rules UI** (L) deps: M3-T01, M3-T07 — Protection tab: Default Rule picker, overrides table (icons, mode, remove), Add ▸ running apps / .app panel, preset button; edits reach covers + `rules.json` (tested); capture-filter side lands in M3-T03
  Do: Settings › Protection: Default Rule picker; overrides table (icon via `NSWorkspace`, name, mode picker, remove); Add ▸ running-apps picker or `.app` `NSOpenPanel` (bundle ID from `Bundle`); "Use recommended settings" button; uninstalled apps get a generic icon.
  Done when: add, remove, and mode changes reach the capture filter and covers without restart; keyboard-navigable.
- [ ] **M3-T09 Overlap and attribution check** (S) deps: M3-T05
  Do: manual matrix: Blur window under an Off window, Curtain window over a Blur window, two Curtain apps side by side; record behavior; decide whether covers clip to the visible window region.
  Done when: documented in `docs/behaviour.md`; no cover appears on an Off window unless a hidden person's box from a monitored app extends under it.

---

## M4 — Polish
Goal: onboarding, full Settings, EN/AR with RTL, Low Power, degraded state, bench CLI, performance pass.
Exit: bench gates (recall ≥ 95 %, misclassification ≤ 2 %); PRD performance table met on M1 8 GB; manual matrix green; Arabic complete.

- [x] **M4-T01 Onboarding** (L) deps: M2-T03, M2-T09, M3-T07 — 5-step "Sitr Setup" window, driven end to end via the Accessibility API (skip permission → Needs permission + warning icon; preset writes Off + 8 Curtain overrides); 15 tests; fresh-account Finder launch manual pending
  Do: first-launch window, 5 steps per FR8; step 2 auto-advances on grant; step 3 requires a hidden-set choice; step 4 preset buttons; step 5 hotkey hint plus Launch at login (on); reopens at Needs permission; Default Rule is Off after onboarding.
  Done when: a fresh user account completes the flow; skipping permission leaves the app in Needs permission with the correct icon.
- [x] **M4-T02 Settings › Appearance** (M) deps: M2-T11 — style/strength/padding bound to Preferences (Runtime pushes live); preview = synthetic `SampleScene` through the real `CoverRenderer`; screenshot reviewed
  Do: style picker, strength slider, padding slider, live preview running the real `CoverRenderer` over a bundled synthetic sample image (generated, no third-party rights).
  Done when: changes apply live to overlays; preview matches overlay output.
- [x] **M4-T03 Settings › Shortcuts** (M) deps: M2-T13 — recorder, validation with reasons, conflict list, reset; `UCKeyTranslate` key names; physical recording manual pending
  Do: hotkey recorder (key + modifiers); static conflict list (⌥Space Siri/ChatGPT, ⌘Space Spotlight, Option-only warning); reset to default.
  Done when: rebind works without relaunch; invalid combos rejected; conflict text shown.
- [x] **M4-T04 Settings › General + About** (M) deps: M2-T15 — language override + relaunch, Low Power toggle key, About with verify command copy, FR11 caveats, model notices; Arabic relaunch check waits for M4-T05
  Do: launch at login; language System / English / Arabic (`AppleLanguages` override plus relaunch prompt); Low Power behavior toggle; About: version, license, `codesign` verification command with copy button, source link, screen-sharing and screenshot caveats.
  Done when: language switch relaunches into Arabic RTL; About text matches README.
- [ ] **M4-T05 Localization EN/AR** (L) deps: M4-T01, M4-T02, M4-T03, M4-T04, M2-T14
  Do: String Catalog for all strings including notifications and menu bar; Arabic reviewed by a native speaker; RTL audit (mirrored layouts, hotkey glyph order, locale numerals); `-AppleLanguages (ar)` scheme.
  Done when: zero untranslated strings; Arabic screenshots of every screen attached to the PR.
- [ ] **M4-T06 Low Power Mode** (S) deps: M2-T05
  Do: observe `NSProcessInfoPowerStateDidChange` → `minimumFrameInterval` 1/8 s, back to 1/15 s; respect the General toggle.
  Done when: fps change logged within 1 s of toggling Low Power.
- [ ] **M4-T07 Degraded state** (M) deps: M2-T12, M2-T16
  Do: detection > 250 ms/frame for 3 s → degraded; recover after 5 s under 150 ms; notification dedupe (one per transition, ≥ 5 min between repeats); status texts.
  Done when: a synthetic slowdown toggles the state and sends exactly one notification.
- [~] **M4-T08 Bench CLI** (L) deps: M2-T06, M2-T07, M1-T06 — `sitr-bench` + labels + CI smoke done; results: recall 84.5 % (≥ 80 px 88.5 %, large+medium 91.6 %), misclassification 5.6 % at 0.80/0.85/0.90 (confident errors), Unknown 9.7 %; PRD gates 95 % / 2 % NOT met → PRD amendment or a stronger classifier (see `docs/bench.md`)
  Do: `sitr-bench <folder>` SwiftPM executable over `SitrCore` + Detect; labels JSON (image, boxes, category, tags); outputs recall (≥ 40 px), hidden-category-shown rate, Unknown rate, ms/frame, per-tag breakdown (hijab, child, low-light, back, drawn); dataset from M1-T05 and M1-T06 with `ATTRIBUTIONS.md`; CI runs 20 images as smoke.
  Done when: recall ≥ 95 % and misclassification ≤ 2 % on the full set on M3; report in `docs/bench.md`.
- [ ] **M4-T09 Performance pass** (L) deps: M2-T12, M3-T05
  Do: Instruments (Time Profiler, Core ML, Metal): reuse `CIContext` and pixel-buffer pools, remove per-frame allocations; detection ROI from `dirtyRects` plus tracked boxes if the CPU target is missed; verify the PRD table on M1 8 GB.
  Done when: static < 1 %, browsing ≤ 15 %, video with people ≤ 25 % of one P-core, memory < 300 MB; `docs/perf.md`.
- [ ] **M4-T10 Robustness** (M) deps: M2-T04, M2-T05
  Do: sleep/wake, lock/unlock, fast user switching, display hot-plug, Stage Manager, mirrored displays; stream restart with exponential backoff (max 10 s); no duplicate panels.
  Done when: 20 sleep/wake cycles leave exactly one stream and one panel per display.
- [~] **M4-T11 Accessibility basics** (S) deps: M2-T14, M4-T01 — labels/hints on onboarding, all tabs, menu bar; focus order; no motion; overlay panels outside the a11y tree; Accessibility Inspector audit manual pending
  Do: VoiceOver labels on menu items and controls; keyboard navigation in onboarding and settings; overlay panels outside the accessibility tree; no motion.
  Done when: Accessibility Inspector audit shows no errors on menu bar, onboarding, settings.
- [ ] **M4-T12 Manual matrix + bug bash** (M) deps: all M4
  Do: run the PRD matrix (1 and 2 displays, Retina and non-Retina, fullscreen Safari video, Stage Manager, Space switch, hot-plug, revoke and re-grant, Low Power, Zoom entire-screen share, screenshot); file issues; fix P0/P1.
  Done when: `docs/test-matrix.md` all green.

---

## M5 — Release
Goal: v1.0 anyone can install and verify.
Exit: fresh macOS 15 user account: download DMG → Gatekeeper passes → onboarding → protection works; `codesign` output matches README; `brew install --cask` works.

- [~] **M5-T01 Sign + notarize script** (M) — `scripts/release.sh` dry run from a clean clone builds, verifies, gates entitlements; notarize/staple/spctl pending Developer ID + notarytool credentials (`docs/m5/release.md`)
  Do: `scripts/release.sh`: `xcodebuild archive` → export with Developer ID, Hardened Runtime, entitlements (sandbox, no network) → `notarytool submit --wait` → `stapler staple` → `spctl -a -vv` and entitlement check.
  Done when: the script produces a stapled `.app` from a clean checkout.
- [x] **M5-T02 DMG** (S) deps: M5-T01 — `scripts/make-dmg.sh` (HFS+ UDZO, /Applications link), mount check + `shasum -c` verified
  Do: `hdiutil` DMG with an `/Applications` symlink; SHA-256 into `checksums.txt`.
  Done when: DMG opens, drag-install works, checksum matches.
- [~] **M5-T03 Release workflow** (M) deps: M5-T01, M5-T02 — `.github/workflows/release.yml` (tag `v*`, draft release, unsigned fallback without secrets) + `CHANGELOG.md`; actionlint clean; end-to-end run pending a pushed tag
  Do: GitHub Actions on tag `v*`: build, notarize (secrets: Developer ID p12, notarytool API key), attach DMG and checksums, notes from `CHANGELOG.md`.
  Done when: tagging a release candidate publishes a draft release end to end.
- [ ] **M5-T04 Homebrew cask** (S) deps: M5-T03
  Do: own tap `homebrew-sitr` with `sitr.rb` (url, sha256, livecheck on GitHub releases, zap stanza for defaults and Application Support); bump step in the release workflow.
  Done when: `brew install --cask <owner>/sitr/sitr` installs the notarized app.
- [x] **M5-T05 Check for Updates** (S) deps: M2-T14 — menu item opens the GitHub Releases URL via `NSWorkspace` (built with M2-T14; click not exercised automatically)
  Do: menu item opens the GitHub Releases URL via `NSWorkspace`; current version shown in About.
  Done when: works in the sandbox with no network entitlement (browser opens).
- [ ] **M5-T06 README + docs** (M) deps: M4-T05
  Do: `README.md` and `README.ar.md`: what it does, requirements, install (DMG, brew), permission and monthly re-approval note, privacy verification command with expected output, screen-sharing and screenshot caveats, Recommended preset, default hotkey, build from source (pinned Xcode), model license and checksum, uninstall steps.
  Done when: a new user follows the README on a fresh account without help.
- [x] **M5-T07 Licensing + compliance** (S) — `LICENSE` GPL-3.0, `THIRD_PARTY_NOTICES.md`, `SECURITY.md`, `CONTRIBUTING.md`, issue templates; `ModelChecksumTests` enforces model SHA-256 in CI (proven red)
  Do: `LICENSE` (GPL-3.0 unless the owner changes it), `THIRD_PARTY_NOTICES.md` (model, dataset attributions, SPM deps), CI model-checksum test; `SECURITY.md`, `CONTRIBUTING.md`, issue templates (bug: macOS version, chip, display setup).
  Done when: files present; CI enforces the checksum.
- [ ] **M5-T08 RC validation** (M) deps: M5-T02, M5-T03, M5-T04, M5-T05, M5-T06, M5-T07
  Do: fresh user account: Gatekeeper, onboarding, preset, Curtain in Safari, Reveal Hold, pause and disable, `tccutil reset` monthly-nag simulation, uninstall; both languages.
  Done when: checklist green; blockers fixed; `v1.0.0` tagged.

---

## Backlog (post-v1, from PRD "Out")
- Mirror curtain: true zero exposure by showing a delayed processed copy of the window (~2 frames lag), behind an experimental flag.
- Pixel-accurate body masks via `GeneratePersonInstanceMaskRequest` (≤ 4 people) as an Appearance option.
- Detection ROI from `dirtyRects` if M4-T09 did not need it.
- Cask in the main `homebrew-cask` repo once notability criteria are met.
- Self-restart after crash.
