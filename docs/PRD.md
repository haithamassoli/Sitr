# Sitr — Product Requirements

## Summary
Sitr is an open-source macOS menu bar app that hides people on screen in real time, entirely on-device. It captures the screen with ScreenCaptureKit, detects people with Vision/CoreML on Apple Silicon, classifies each person as Woman, Man, or Unknown, and covers the full body of every person in the categories the user chose with a blur, pixelation, or solid block. No pixel leaves the Mac: the app ships with no network entitlement. It is HaramBlur for the whole Mac, not only the browser: native apps, video, chat, video calls.

## Problem
Users who want to lower their gaze have HaramBlur inside browsers only. Native apps (Telegram, WhatsApp, Discord, Photos, video players, FaceTime) are uncovered. Existing Mac tools target nudity (Anti-Glaze) or privacy from onlookers (BlurAway, PeekGuard), not people by category, and none are open source.

## Target user
Muslim macOS user on Apple Silicon who wants women, men, or everyone hidden on screen by default, wants zero cloud involvement, and accepts a small CPU cost. Arabic or English speaker.

## Platform and distribution
- macOS 15+, Apple Silicon only. Intel unsupported.
- Direct download `.dmg`, Developer ID signed, notarized. GitHub Releases + Homebrew cask. Not on the App Store.
- Open source. License: GPL-3.0 (owner may change).

## Definitions
| Term | Meaning |
|---|---|
| Person | Any detected human body region in photographic or video content. Drawn/animated people are best effort. |
| Category | Woman, Man, Unknown. |
| Unknown | Person facing away, face hidden or occluded, too small, too far, or classifier confidence below threshold. |
| Hidden set | Categories the user chose to hide: Women, Men, or Everyone. Everyone = all persons including Unknown. |
| Strict Mode | "Blur Unknown" toggle: adds Unknown to the hidden set. Default on. Forced on and disabled in UI when Everyone is selected. |
| Blur mode | Per-app mode. Detect, then cover. Accepts ~100–200 ms exposure. |
| Curtain mode | Per-app mode. Cover changed regions immediately, uncover regions verified safe. Exposure bounded by capture-to-draw latency (target ≤ 60 ms p95 with 30 fps capture; amended after the M1 spike, was ≤ 50 ms), not zero. |
| Off | Per-app mode. App content is never captured or analyzed. |
| Default Rule | Mode for every app without an override. Initial value Off. Setting it to Blur or Curtain = "Entire Mac". |
| Override | Per-app mode that replaces the Default Rule. |
| Reveal Hold | Hold a global hotkey: all overlays hidden. Release: overlays return. |

## Scope

### In (v1)
1. Menu bar app, no Dock icon, launch-at-login option.
2. Real-time detection on all connected displays, all Spaces, fullscreen apps included.
3. Classification Woman / Man / Unknown. Hidden set Women / Men / Everyone. Strict Mode.
4. Full-body cover as a rectangle plus Body Padding.
5. Blur styles: Gaussian, Pixelate, Solid. Blur Strength slider.
6. Default Rule plus per-app overrides (Off / Blur / Curtain).
7. Recommended Protection preset in onboarding.
8. Temporary Reveal Hold, default ⌃⌥Space, configurable.
9. Menu bar: Pause Protection, Disable Protection, Reveal status.
10. Fail states: warning icon, one notification, Curtain apps fail closed.
11. English and Arabic, LTR and RTL.
12. Zero network: sandbox with no network entitlement, verifiable with `codesign`.
13. Local benchmark CLI for detection and classification metrics.

### Out (v1)
- Pixel-accurate body masks (v2; Vision instance masks cap at 4 people per frame).
- "Mirror" curtain: true zero exposure by showing a delayed, processed copy of the window; adds ~2 frames of display lag. v2 experiment.
- Safe Reveal (per-person hover reveal), accountability, reveal logs, commitment locks.
- Nudity or clothing categories, face recognition, allowlisting specific people.
- Hiding the overlay from screen sharing or screenshots.
- In-app auto-update (Sparkle), telemetry, network crash reporting.
- App Store, Intel, macOS < 15, iOS, Windows, browser extension.

## Functional requirements

### FR1 Capture
- One ScreenCaptureKit stream per active display. Reconfigure within 1 s on display add/remove, resolution change, Space change.
- The `SCContentFilter` always excludes Sitr's own process (overlay and settings windows). `NSWindow.sharingType = .none` is not reliable against ScreenCaptureKit on macOS 15+; without filter exclusion the overlay feeds back into detection and flickers.
- Default Rule Off: filter includes only override apps (Blur/Curtain). Default Rule on: filter excludes Off apps.
- Skip frames with status idle. Use `dirtyRects` to limit detection to changed regions plus tracked boxes.
- Detection input scaled so the long side ≤ 1280 px; map results back with `scaleFactor` / `contentScale`.
- `minimumFrameInterval` 1/15 s default, 1/8 s in Low Power Mode. `queueDepth` 3–5.

### FR2 Detection and classification
- Person detector: Vision `DetectHumanRectanglesRequest` (full body, upper-body fallback), Neural Engine. If the recall target is unmet: a permissively licensed CoreML person detector. Ultralytics YOLO is AGPL and excluded.
- Face detector: Vision `DetectFaceRectanglesRequest`. Each face is assigned to the person box with the largest overlap.
- Gender classifier: CoreML model on an aligned face crop ≥ 32 px, outputs P(woman). Model and training data must be permissively licensed (MIT / Apache / CC BY). Apple MobileCLIP weights are research-only and excluded.
- Category rule: no assigned face, face < 32 px, body height < 40 px in capture space, or max probability < 0.80 → Unknown. Otherwise Woman or Man.
- Tracking: IoU matching across frames, EMA box smoothing. A box persists 300 ms after its last detection. A category sticks to a track until 3 consecutive contrary frames. Goal: no flicker.
- Overlapping hidden-set boxes may be merged.

### FR3 Cover rendering
- One borderless, transparent, non-activating, click-through overlay panel per display, level above `.screenSaver`, joins all Spaces, fullscreen auxiliary, stationary. Never takes focus, never in the app switcher.
- Cover rectangle = body box expanded by Body Padding (0–50 % of box size, default 15 %), clamped to the display.
- Styles: Gaussian (radius from Blur Strength, computed from captured pixels so any content can be blurred), Pixelate (block size from Blur Strength), Solid (neutral opaque color following system appearance). Blur Strength default 70 %. The minimum strength must make a 60 px face unrecognizable.
- A cover appears on the first detected frame. Removal is delayed by tracking persistence; appearance never is.
- Overlay updates coalesced per frame, committed in one `CATransaction`.

### FR4 Curtain mode
Per Curtain app, per region:
1. Frame arrives. `dirtyRects ∩ app window rects` → covered immediately with the active style, before detection runs.
2. Detection on that frame completes → regions without a hidden-set person are uncovered; hidden-set persons keep person covers.
3. Trusted motion: a region continuously changing and verified safe for ≥ 500 ms (video without people, long scroll) is no longer pre-covered and behaves as Blur mode until it stays static ≥ 1 s, which resets it. Prevents permanently blurred video.
4. New windows of a Curtain app are fully covered until their first verified frame.
- Window rects come from `CGWindowListCopyWindowInfo` (bounds and owner PID need no extra permission), polled at 10 Hz and on app activation.
- Displays showing a Curtain app capture at 30 fps (`minimumFrameInterval` 1/30 s); other displays keep the 15 fps default. Amended after the M1 spike: 15 fps capture measures 76 ms p95 for the Curtain path, 30 fps 55 ms, 60 fps 54 ms (`docs/spike/latency.md`).

### FR5 Reveal Hold
- Carbon `RegisterEventHotKey` with pressed and released events. No Accessibility or Input Monitoring permission.
- Default ⌃⌥Space, configurable, with conflict warning. ⌥Space is not the default: it conflicts with Siri (hold ⌥Space) and ChatGPT desktop, and Option-only hotkeys regressed in macOS 15.0.
- Press: all overlays on all displays hidden within 1 frame. Release: restored within 1 frame. Detection keeps running while revealed.
- Safety: re-cover after 30 s of holding, or when the release event is lost (modifier flags change, app deactivation).

### FR6 App rules
- Settings: Default Rule selector (Off / Blur / Curtain), then an overrides table: app icon, name, mode, remove. Add via running-apps picker or `.app` file picker. Apps stored by bundle ID; rules for apps not installed are allowed.
- Recommended Protection preset, shown in onboarding and available in Settings:

| Group | App | Mode |
|---|---|---|
| Browsers | Safari, Chrome, Arc | Curtain |
| Communication | Telegram, WhatsApp, Discord | Curtain |

Buttons: "Use recommended settings" (applies preset, Default Rule stays Off) and "Configure myself" (opens Settings).

### FR7 Menu bar
Items in order:
1. Status line: Protected · Paused until HH:MM · Disabled · Needs Screen Recording permission · Degraded.
2. Pause Protection ▸ 15 minutes / 1 hour. Auto-resumes. Overlays removed while paused.
3. Disable Protection. Stays off until re-enabled; item becomes Enable Protection.
4. Reveal: "Hold ⌃⌥Space to reveal", state Available / Unavailable (unavailable when paused, disabled, or without permission).
5. Settings…, Check for Updates… (opens GitHub Releases in the browser), Quit.

Icon: template glyph; dimmed when paused or disabled; warning badge in Degraded or Needs permission.

### FR8 Onboarding (first launch)
1. What Sitr does, privacy statement, the `codesign` verification command.
2. Screen Recording permission: button opens System Settings › Privacy & Security › Screen & System Audio Recording; auto-advances when granted. macOS re-asks roughly monthly; the app detects a revoked grant and enters Needs permission.
3. Hidden set: Women / Men / Everyone, required, no preselection. Strict Mode toggle, on.
4. Recommended Protection (FR6).
5. Done: Reveal hotkey hint, Launch at login toggle (on).

### FR9 Settings window
Tabs: Protection (hidden set, Strict Mode, Default Rule, overrides, preset), Appearance (style, strength, padding, live preview on a bundled sample image), Shortcuts (Reveal Hold), General (launch at login via `SMAppService`, language System / English / Arabic, Low Power behavior), About (version, license, privacy verification, source link).

### FR10 Failure behavior
| Condition | Curtain apps | Blur apps and Default Rule | UI |
|---|---|---|---|
| Permission revoked or capture error | Solid cover over each app window (rects from CGWindowList) until capture resumes | Uncovered | Warning icon, one notification |
| Stream stalls > 1 s while windows change | Same fail-closed cover | Uncovered | Warning icon |
| Detection > 250 ms/frame for 3 s | Pre-cover stays until verified | Degraded | Warning icon |
| Crash | Relaunched by login item at next login; no self-restart in v1 | | |

Paused and Disabled are user actions, not failures: overlays removed, icon dimmed.

### FR11 Screen sharing and screenshots (documented behavior)
- Share Entire Screen: the overlay is a normal window, covers are usually visible to viewers.
- Share Specific Window: the overlay is not part of that window, covers are not guaranteed.
- Screenshots include covers. Stated in README and About.

### FR12 Localization
English and Arabic via String Catalogs. Layout mirrors in RTL. Numbers and dates follow locale. Menu bar, onboarding, notifications included.

## Privacy and security
- App Sandbox enabled with no `com.apple.security.network.*` entitlements. Hardened Runtime. Notarized. README shows `codesign -d --entitlements - /Applications/Sitr.app` and the expected output.
- Frames stay in memory, never written to disk. No screenshots, no screen-content logs, no telemetry, no crash upload. Debug logs contain timings and counts only.
- Only permission requested: Screen & System Audio Recording, video only, no audio configured.
- Reproducible build: pinned Xcode version, no binary dependencies except the bundled CoreML model with its license and checksum.

## Performance and quality targets (M1, 8 GB baseline)
| Metric | Target |
|---|---|
| Blur mode exposure, person visible → covered, p95 | ≤ 150 ms |
| Curtain exposure, change visible → covered, p95 | ≤ 60 ms with 30 fps capture on Curtain-app displays (amended after the M1 spike, was ≤ 50 ms: rig 76 / 55 / 54 ms p95 at 15 / 30 / 60 fps) |
| Reveal press or release → overlays hidden or shown | ≤ 1 frame |
| CPU, static screen (no complete frames delivered) | < 1 % (amended after the M1 spike: "static" defined as no `.complete` frames; not yet measurable on the spike machine, whose desktop never stopped changing) |
| CPU, idle user with people on screen at ~9 fps of screen change | ≤ 15 % of one P-core (new row after the M1 spike; measured 30–37 %, M4-T09 gate) |
| CPU, active browsing at 15 fps detection | ≤ 15 % of one P-core (M1 measured 32.7 %; M4-T09 gate, target unchanged) |
| CPU, 1080p video with people | ≤ 25 % of one P-core (M1 measured 41.5 %; M4-T09 gate, target unchanged) |
| Memory | < 300 MB |
| Person recall, body ≥ 80 px at capture scale, benchmark set | ≥ 90 %, with large+medium ≥ 90 % (amended after the M1 spike, was ≥ 95 % for bodies ≥ 40 px: measured 88.5 % ≥ 80 px, 91.6 % large+medium, 84.5 % over all bodies ≥ 40 px) |
| Person recall, body ≥ 40 px, benchmark set | Reported, not gated (amended after the M1 spike: no permissively licensed detector reaches 95 % on 20–40 px bodies at this size budget) |
| Hidden-category person shown due to misclassification | ≤ 6 % at default threshold on the v1 classifier, ≤ 2 % on its replacement (amended after the M1 spike, was ≤ 2 %: measured 5.6 % at 0.80 and 5.4 % at 0.90 — 13 of 14 errors are confident, so the threshold is not the lever; Strict Mode covers Unknown) |
| Unknown rate on benchmark | Reported, not gated |
| Cover jitter | No visible flicker at 15 fps on steady content |

## Architecture notes
- Swift 6, SwiftUI (`MenuBarExtra`, Settings), AppKit overlay `NSPanel`s, ScreenCaptureKit, Vision Swift API (macOS 15), CoreML, CoreImage/Metal for blur and pixelate, Carbon hotkeys, `SMAppService`, String Catalogs. Xcode 26.
- Modules: `Capture` (streams, filters, display topology), `Detect` (Vision + CoreML, tracking, category rule), `Policy` (Default Rule and overrides, Curtain state machine, pause/disable, failure states), `Overlay` (per-display panels, rendering), `Hotkey`, `UI` (menu bar, onboarding, settings), `Bench` (CLI).
- `Policy` is pure Swift with no UI or system dependencies, fully unit-tested.
- Per frame: SCK frame → skip idle → Curtain pre-cover from dirty rects → downscale → person and face detection → classify faces → assign categories → tracker update → policy → overlay diff → commit.
- Coordinate spaces: capture pixels → display points via `scaleFactor`; CGWindowList rects are global screen points with flipped origin, converted in one utility.

## Testing
- Unit: `Policy` (mode resolution, Curtain state machine, trusted motion, failure transitions), category rule, tracker persistence.
- Bench CLI: `sitr-bench <folder>` runs the pipeline on labeled images and video frames, prints recall, misclassification, Unknown rate, ms/frame on the host chip. Labeled set in the repo, permissively licensed images only.
- Manual matrix: 1 and 2 displays, Retina and non-Retina, fullscreen Safari video, Stage Manager, Space switch, display hot-plug, permission revoke and re-grant, Low Power Mode, Zoom entire-screen share, screenshot.

## Milestones
1. Spike, go/no-go: SCK + Vision + overlay on M1 and M3. Measure exposure, CPU, detector recall on 200 images. Choose detector and classifier.
2. Core: Entire Mac Blur mode, categories and Strict Mode, rectangle cover with styles and padding, Reveal Hold, menu bar with Pause and Disable, permission flow.
3. Rules: Default Rule and overrides, Curtain mode with trusted motion, Recommended preset, fail-closed behavior.
4. Polish: onboarding, Settings, EN/AR with RTL, Low Power, degraded states, bench CLI.
5. Release: notarized DMG, Homebrew cask, README with privacy verification and screen-sharing caveats.

## Risks
| Risk | Mitigation |
|---|---|
| Monthly re-approval silently stops capture | Detect stall or error → fail-closed for Curtain apps, warning state, notification |
| Vision detector misses partial bodies or drawn people | Upper-body fallback, Unknown + Strict, bench gate, swap to permissive CoreML detector if recall < 95 % |
| Classifier bias (hijab, children, low light) | Unknown below 0.80 confidence, bench reports per subgroup |
| Curtain makes scrolling or video unusable | Trusted-motion rule, per-app switch to Blur |
| Exposure not truly zero in Curtain | Stated honestly, Mirror mode as v2 experiment |
| Overlay captured by own stream | Exclude own process in `SCContentFilter`, re-apply when panels are recreated |
| Hotkey conflicts, Option-only regression | Configurable, default ⌃⌥Space, conflict warning |
| Laptop battery | Idle frames skipped, Low Power → 8 fps, detection ≤ 1280 px |

## Open items
- Classifier model and its license, decided in the Spike.
- App license, GPL-3.0 assumed.
- Blur Strength curve per style, tuned in the Spike against the unrecognizability rule.
