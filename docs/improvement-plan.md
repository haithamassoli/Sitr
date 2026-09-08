# Sitr Performance and User Experience Improvement Plan

Date: 2026-09-08

Scope: the macOS app, capture and detection pipeline, settings, onboarding, and release validation.

Status: proposed work, based on a source review and the repository's existing measurements. This review did not run new benchmarks or a live usability session.

Improve Sitr in this order: make protection and recovery trustworthy, measure the current build, reduce unnecessary processing, then improve everyday controls and detection quality. Keep the native SwiftUI/AppKit architecture and reuse the existing test and benchmark tools.

## 1. Starting point

### Keep the improvements that already exist

- Capture retains only the newest pending frame and drops idle frames.
- The pipeline skips identical overlay commits and reuses eligible cover surfaces, which addresses the documented capture/overlay feedback loop.
- Rendering already uses reusable Core Image contexts, bounded pixel-buffer pools, grouped GPU submissions, and reduced resolution for large Gaussian covers.
- Classification already prioritizes new/Unknown tracks and refreshes settled categories at a lower rate.
- The current working tree skips face detection and classifier warm-up for Everyone, and compares captured tiles against the last verified frame for Curtain. Re-measure these changes before attributing the older performance numbers to this version.
- The app already provides one-click default setup, an appearance preview, pause timers, reveal safeguards, per-app rules, English/Arabic localization, and capture restart backoff.
- The project already has Swift Testing suites, live selftests, a labeled-image benchmark, entitlement checks, and a localization gate.

Sources: [pipeline](../Sources/Sitr/Pipeline/Pipeline.swift), [frame comparison](../Sources/Sitr/Capture/Frame.swift), [renderer](../Sources/Sitr/Overlay/CoverRenderer.swift), [onboarding](../Sources/Sitr/UI/Onboarding.swift), and [performance report](perf.md).

### Baseline and acceptance targets

Use the amended [PRD performance table](PRD.md#performance-and-quality-targets-m1-8-gb-baseline) as the target source. Some rows in README, `tasks.md`, and `bench.md` still refer to earlier targets.

| Area | Recorded result | Target for this plan |
|---|---|---|
| Active browsing CPU | 5.6–7.8% in the M3 performance pass | At most 15% of one core on the M1 8 GB baseline |
| Video with people CPU | 26.1–28.5% on M3 | At most 25% on the reference workload |
| Static/near-static CPU | 0.5% sampled mean; 1.1% from CPU-time delta, with about 0.45 complete frames/s | Under 1% on a verified static screen; report near-static separately |
| Blur exposure p95 | 121–143 ms in quiet M3 runs; 152–186 ms under load | At most 150 ms on the reference workload |
| Curtain exposure p95 | Earlier integration result: 84.8 ms at 30 fps; the later performance pass could not complete the exposure harness | At most 60 ms at 30 fps; obtain a valid measurement first |
| Memory | 140–144 MB maximum in the recorded performance pass | Under 300 MB on the reference configuration, with no sustained growth |
| Person recall, bodies at least 80 capture pixels tall | 88.7% after the performance pass | At least 90%; large+medium recall must also remain at least 90% |
| Classification error | 5.6% at the default threshold in the labeled-face benchmark | At most 6% for the current v1 model; at most 2% for a replacement |
| Reveal responsiveness | Existing requirement; recheck on the release candidate | Covers hide/return within one display frame |

The results above come from [perf.md](perf.md) and [bench.md](bench.md). They describe earlier runs, mainly on an M3 with 24 GB, and do not establish performance on an M1 with 8 GB. The classification percentage uses known predictions on matched labeled people as its denominator; it is not an end-to-end protection success rate. Report missed people and Unknown separately.

## 2. Measurement protocol

- [ ] Record the commit, working-tree changes, build configuration, model checksums, macOS version, hardware, display count/resolution, power mode, and thermal/load conditions for each run.
- [ ] Build in release mode. Measure startup separately from steady-state processing, with cold and warm model caches identified.
- [ ] Run static, near-static with people, browsing, video with people, and safe video/scrolling in Curtain. Cover Everyone and category-specific protection, all cover styles, and Low Power Mode.
- [ ] Take at least three runs per scenario. Use interleaved before/after runs against the same stimulus; mark noisy runs and keep their results separate.
- [ ] Record CPU-time delta, sampled CPU, peak memory, processed/skipped frames, errors, render/commit counts, and p50/p95 stage timings. Report `replayd`/capture-service cost separately where the existing script provides it.
- [ ] Measure visible-content-to-cover exposure with the stimulus harness. `Frame.timestamp` begins at the capture callback, so pipeline `e2e` alone excludes the delay before that callback.
- [ ] Preserve individual-run p95 values. The system script summarizes per-window percentiles; a median of window p95 values is not the p95 of the full sample population.
- [ ] Repeat the release gates on M1 8 GB. Measure an additional display separately; do not assume a one-display resource budget proves multi-display performance.
- [ ] Run a 10-minute motion/memory soak after performance changes. Keep logs to timings, counts, and configuration metadata; retain no captured pixels.

Start with [measure-system.sh](../scripts/measure-system.sh), [the selftests](../Sources/Sitr/Selftest.swift), and [the bench CLI](../Bench/README.md). Use Instruments Time Profiler/Core ML/Metal when the existing measurements cannot locate a cost. For settings responsiveness, inspect long or repeated view updates with Apple's [SwiftUI performance tools](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance).

## 3. Prioritized work

Effort estimates describe implementation and focused checks for one developer. Hardware access, participant scheduling, and model experiments can extend elapsed time. P0 items address protection correctness and misleading state; P1 items improve performance and daily use; P2 items require further evidence or broader validation.

### P0-1. Apply capture rules before accepting frames

**Evidence:** `CaptureSession.connect()` can start with the own-process exclusion filter before the app-specific filter arrives. A filter update during `startCapture()` can also miss the not-yet-assigned `stream`. `Runtime.sessionBecameOK()` documents a later reinstall as a workaround. This conflicts with the Off rule's promise that an app is never captured or analyzed.

**Work:**

- [ ] Reproduce initial startup and restart races with the existing filter stimulus.
- [ ] Make the first stream filter reflect the current rules before capture starts. If that filter is unavailable, wait for it.
- [ ] Handle filter changes during connection in `CaptureSession`; prevent outdated connection attempts from becoming active.
- [ ] During a transition to Off, discard pending results from the older rule/filter state and finish the exclusion before presenting the transition as complete.
- [ ] Remove the delayed-reinstall workaround once the shared connection path handles these cases.

**Done when:** startup, rule edits during connection, permission recovery, and reconnect checks show no Off-app pixels reaching detection. A regression check must fail against the reproduced race. Use the existing stream/filter APIs; Apple documents filter replacement through [`SCStream`](https://developer.apple.com/documentation/screencapturekit/scstream).

**Files:** [CaptureSession.swift](../Sources/Sitr/Capture/CaptureSession.swift), [FilterBuilder.swift](../Sources/Sitr/Capture/FilterBuilder.swift), [SitrApp.swift](../Sources/Sitr/SitrApp.swift), [Pipeline.swift](../Sources/Sitr/Pipeline/Pipeline.swift).

**Effort:** 2–4 days. **Dependency:** a working filter stimulus.

### P0-2. Show protection readiness, scope, and recovery actions

**Evidence:** `AppModel.status(for:)` resolves healthy/active policy to Protected without checking configured apps or model readiness. Model-load failures remain in logs, and `Runtime.checkHealth()` maps general stream failures to Needs Screen Recording permission. Pipeline detection errors increment a counter and bypass the successful-detection health sample.

**Work:**

- [ ] Distinguish preparing protection, no apps configured, waiting for a protected app, active protection, capture recovery, and model/detection failure in the status presentation.
- [ ] Include a plain-language scope summary, such as “Selected apps” or “All apps except overrides.” Do not imply that an absence of detected people means protection is inactive.
- [ ] Show “Open Screen Recording Settings” only for an actual permission problem; offer retry for recoverable capture/model failures.
- [ ] Expose fallback operation and repeated inference failures. Explain the consequence for category-specific protection without displaying model internals in the primary UI.
- [ ] Preserve notification deduplication and the existing conservative Curtain behavior during capture loss.

**Done when:** a status-table test covers startup, zero rules, configured-but-closed apps, healthy capture, model fallback, repeated inference failure, pause/disable, revocation, and recovery. The menu and General tab agree, and each recoverable failure has a usable action.

**Files:** [AppModel.swift](../Sources/Sitr/AppModel.swift), [SitrApp.swift](../Sources/Sitr/SitrApp.swift), [DetectionMeter.swift](../Sources/Sitr/Pipeline/DetectionMeter.swift), [MenuBar.swift](../Sources/Sitr/UI/MenuBar.swift), [GeneralTab.swift](../Sources/Sitr/UI/GeneralTab.swift).

**Effort:** 2–4 days.

### P0-3. Make settings failures visible and recoverable

**Evidence:** `AppModel.updateRules()` applies changes in memory and only logs a failed save. `RulesStore.load()` returns default Off rules for unreadable content. Onboarding logs launch-at-login registration failures, and the language relaunch callback terminates the current process without checking whether opening the replacement succeeded.

**Work:**

- [ ] Keep the existing atomic rules writer. Show a persistent “Changes apply until quit; saving failed” message with Retry when persistence fails.
- [ ] Report corrupted/unreadable rules and offer recovery or an explicit reset. Preserve the original file and existing recovery copies before replacing anything.
- [ ] Reuse the General tab's launch-at-login status to surface setup registration failures.
- [ ] Keep Sitr running and display the error if the replacement process cannot launch after a language change.

**Done when:** an unwritable rules directory, corrupt JSON, failed login registration, and failed relaunch each produce a clear recovery path. Settings that the UI reports as saved survive a relaunch.

**Files:** [AppModel.swift](../Sources/Sitr/AppModel.swift), [Rules.swift](../Sources/SitrCore/Rules.swift), [Onboarding.swift](../Sources/Sitr/UI/Onboarding.swift), [GeneralTab.swift](../Sources/Sitr/UI/GeneralTab.swift), [LaunchAtLogin.swift](../Sources/Sitr/LaunchAtLogin.swift).

**Effort:** 1–3 days.

### P1-1. Stop inference when the user has paused or disabled protection

**Evidence:** the policy removes covers while paused/disabled, but `Pipeline.run()` still proceeds into detection and classification. Runtime policy updates do not stop capture for these states.

**Work:**

- [ ] Skip inference for an explicit pause/disable, and recheck current policy before committing work that started before that transition.
- [ ] Suspend capture for user-disabled processing where the existing lifecycle permits it; keep the monitors needed for timed resume and new eligible windows.
- [ ] Measure displays with no eligible visible apps, then park their streams if the savings justify the lifecycle change.
- [ ] Resume from a fresh frame and invalidate stale tracking/verification state. Keep permission-recovery processing separate: a blanket `!isProtecting` guard could prevent the committed frame that restores health.
- [ ] Preserve the current Everyone shortcut. Consider deferring the classifier's model load only if cold-start/memory measurements show a useful gain; switching to Women/Men must still load it once and cover Unknown during preparation.

**Done when:** detection/classifier counters stop after in-flight work settles during pause/disable, old results cannot restore covers, and timed/manual resume works. Report CPU and resume-latency changes together.

**Files:** [Pipeline.swift](../Sources/Sitr/Pipeline/Pipeline.swift), [SitrApp.swift](../Sources/Sitr/SitrApp.swift), [DisplayManager.swift](../Sources/Sitr/Capture/DisplayManager.swift).

**Effort:** 2–4 days. **Dependencies:** P0-1 and readiness handling from P0-2.

### P1-2. Repair Curtain measurement and reduce visible interruption

**Evidence:** [perf.md](perf.md) records a failed remote-stimulus channel. [The integration recipe](m3/integration.md#stimulusapp-the-second-process) already describes an unsandboxed throwaway stimulus with the production app still sandboxed. The current working tree adds exact 64-pixel tile comparison to avoid pre-covering unchanged captured content.

**Work:**

- [ ] Verify the existing stimulus recipe and channel path before changing the harness. Require a successful handshake and a nonzero number of exposure samples; report missed trials.
- [ ] Measure the current tile-comparison path, including CPU cost and retained-frame memory, at 30 fps and with two displays.
- [ ] Check dropped frames, window moves/resizes, same-position content replacement, and static browser controls around changing video.
- [ ] Record visible-content-to-pre-cover exposure, time to clear safe regions, and the number/duration of unnecessary pre-covers during safe playback.
- [ ] If exposure still misses 60 ms, profile the pre-cover render and commit stages first. Change the measured bottleneck while preserving protection until verification completes.

**Done when:** the reference run meets 60 ms p95, safe scrolling clears within 100 ms of verification, and safe continuous motion reaches the documented trusted state around 500 ms. New people appearing during trusted motion must still trigger coverage. Include a visual check for flicker and tearing.

**Files:** [Selftest.swift](../Sources/Sitr/Selftest.swift), [Frame.swift](../Sources/Sitr/Capture/Frame.swift), [Pipeline.swift](../Sources/Sitr/Pipeline/Pipeline.swift), [Curtain.swift](../Sources/SitrCore/Curtain.swift).

**Effort:** 2–4 days for measurement and diagnosis; estimate further fixes from the profile. **Dependency:** measurement protocol.

### P1-3. Close the video CPU gap

**Evidence:** the recorded performance pass missed the video CPU target by 1.1–3.5 percentage points. That workload keeps both the captured scene and the covers moving, limiting reuse.

**Work:**

- [ ] Re-profile the current build under the reference video stimulus before selecting an optimization.
- [ ] Compare Gaussian, Pixelate, and Solid to separate detector/preprocessing cost from rendering cost.
- [ ] Inspect changing cover sizes and pixel-buffer pool churn, GPU waits, and main-thread commits. Retain the existing pooled/zero-copy path.
- [ ] Apply one measured improvement at a time. Consider a shared render destination only if per-cover GPU work remains dominant after smaller fixes.
- [ ] Measure Low Power Mode as its own configuration. Report its effect on exposure; do not claim the normal 30 fps Curtain target at the existing 8 fps cap.

**Done when:** the reference video workload stays at or below 25% CPU and under 300 MB, with no recall regression or worse exposure. Keep any broader render change only if repeated before/after runs show a benefit.

**Files:** [CoverRenderer.swift](../Sources/Sitr/Overlay/CoverRenderer.swift), [OverlayPanel.swift](../Sources/Sitr/Overlay/OverlayPanel.swift), [Pipeline.swift](../Sources/Sitr/Pipeline/Pipeline.swift), [CoreMLPersonDetector.swift](../Sources/SitrDetect/CoreMLPersonDetector.swift).

**Effort:** 2–5 days after profiling. **Dependencies:** current baseline and P1-2 measurements.

### P1-4. Make first-run success obvious

**Evidence:** setup already has “Use Default Settings,” but completion focuses on permission and preferences. Users still need to understand which apps have rules and whether capture is ready.

**Work:**

- [ ] Keep the short default path and customization flow. Show the chosen scope and resulting readiness after setup completes.
- [ ] List the actual recommended apps instead of relying only on “browsers and chat apps.” Distinguish installed apps from saved rules for absent apps.
- [ ] Add a direct route to Protection settings when no configured app can currently use protection.
- [ ] Reuse the existing sample scene for a brief cover/reveal demonstration. Label it as a demonstration; it does not prove detector recall.
- [ ] Explain permission denial/recovery in terms of what remains covered. Verify OS-specific permission wording on supported macOS versions before updating the English and Arabic copy.

**Done when:** in a small formative session with five new users across English and Arabic, at least four finish default setup without coaching and can identify the protected apps, pause/resume protection, and locate permission recovery. Treat this as a usability signal, not a population estimate.

**Files:** [Onboarding.swift](../Sources/Sitr/UI/Onboarding.swift), [MenuBar.swift](../Sources/Sitr/UI/MenuBar.swift), [ProtectionTab.swift](../Sources/Sitr/UI/ProtectionTab.swift).

**Effort:** 2–3 days plus user sessions. **Dependency:** P0-2.

### P1-5. Improve settings responsiveness and rule management

**Evidence:** the settings window uses a fixed 560×600 frame; app overrides use a fixed-height table. `PreviewView.render()` runs the real renderer synchronously during view updates. App names/icons use a process-lifetime cache.

**Work:**

- [ ] Skip unchanged appearance previews, then profile continuous slider dragging. Coalesce updates or move expensive preparation off the main actor only if the trace shows stalls; serialize renderer access.
- [ ] Make settings and onboarding tolerate longer Arabic text and larger accessibility text without clipped actions. Use flexible sizing/scrolling where the current layout fails.
- [ ] Add a useful empty state for overrides and explain that removing an override restores the Default Rule, which may keep that app protected.
- [ ] Refresh installed-app metadata when Settings becomes active. Add search only if testing a realistic long list makes it worthwhile.
- [ ] Provide an appearance reset using the existing default values, and preserve unrelated protection rules.

**Done when:** settings controls respond within a proposed 100 ms p95 interaction budget on the reference Mac, the preview ends at the selected value, and keyboard users can add/edit/remove a rule without losing focus. Confirm these behaviors under Arabic RTL and increased text size.

**Files:** [AppearanceTab.swift](../Sources/Sitr/UI/AppearanceTab.swift), [ProtectionTab.swift](../Sources/Sitr/UI/ProtectionTab.swift), [SettingsView.swift](../Sources/Sitr/UI/SettingsView.swift), [Onboarding.swift](../Sources/Sitr/UI/Onboarding.swift).

**Effort:** 2–4 days. **Dependency:** a settings responsiveness trace.

### P2-1. Improve detection quality without hiding its limits

**Evidence:** recall for bodies at least 80 pixels tall remains below 90%. The labeled-face threshold sweep changes error from 5.6% to 5.4% while increasing Unknown, so raising confidence alone does not deliver the replacement-model target. The classifier refresh interval can also preserve an old category when a different person appears in the same location.

**Work:**

- [ ] Maintain a fixed evaluation set and separate tuning data. Report bodies at least 40 pixels, at least 80 pixels, partial bodies, profiles, low-light samples, and Unknown with sample counts.
- [ ] Add temporal sequences for same-position person replacement, people entering/leaving, and category changes. Check stale classification and tracking behavior as well as still-image accuracy.
- [ ] Measure unnecessary coverage on safe scenes, in addition to missed people and classification errors.
- [ ] Try detector threshold/preprocessing adjustments on tuning data, then validate on the fixed set. Evaluate targeted higher-detail crops only if recall warrants their added latency and CPU cost.
- [ ] Consider a replacement classifier only after the current pipeline is stable. Require the 2% error target, adequate evaluation coverage, acceptable Unknown rate, documented licensing/checksums, and performance within budget.

**Done when:** recall reaches the amended PRD gates, temporal tests do not retain a wrong category beyond the agreed refresh behavior, and quality gains survive the performance checks. Keep Everyone/Strict behavior intact; Strict covers Unknown but cannot correct a confidently wrong category or an undetected person.

**Files:** [SitrDetect](../Sources/SitrDetect/), [Tracker.swift](../Sources/SitrCore/Tracker.swift), [SitrBench](../Sources/SitrBench/), [Bench](../Bench/).

**Effort:** 3–5 days for evaluation and bounded tuning; estimate model work separately. **Dependencies:** stable P1 measurements and fixed evaluation data.

### P2-2. Complete accessibility, system, and release validation

**Evidence:** [tasks.md](tasks.md) still lists manual accessibility, real sleep/wake, display, and release-candidate checks as pending. Automated/simulated checks cover useful logic but do not establish those OS behaviors.

- [ ] Audit menu bar access, onboarding, settings, shortcut recording, warnings, and recovery with VoiceOver and keyboard-only navigation. Keep overlay panels outside the accessibility tree.
- [ ] Review Arabic terminology with a native speaker. Check focus order, RTL alignment, localized percentages/times, and LTR shortcut/command text.
- [ ] Test actual sleep/wake, lock/unlock, permission revoke/regrant, display hot-plug, mirroring, mixed scaling, fullscreen video, Spaces, and Stage Manager on a dedicated test session.
- [ ] Repeat whole-screen and single-window sharing checks; document the overlay limitation for window sharing.
- [ ] Validate a signed release build from a fresh account, including login startup, language relaunch, updates-page access, and uninstall instructions.
- [ ] Run benchmark math selfchecks independently of network downloads in CI. The current smoke step skips its selfcheck when no images download. Keep hardware performance gates on a controlled Mac and identify skipped data-dependent checks.
- [ ] Reconcile README, PRD, task status, and benchmark summaries. Distinguish implemented features, measured results, and hardware/manual checks still pending.

**Done when:** the release matrix records a result and environment for each supported scenario, EN/AR controls remain usable, and unresolved items have explicit limits and owners before release.

**Files:** [tests](../Tests/), [CI workflow](../.github/workflows/ci.yml), [String Catalog](../App/Resources/Localizable.xcstrings), [robustness notes](m4/robustness.md), [release notes](m5/release.md).

**Effort:** 3–5 days plus access to the reference hardware and reviewers. **Dependency:** the final candidate build.

## 4. Delivery order

| Stage | Deliverable | Exit condition |
|---|---|---|
| 1. Establish the baseline | Current-build measurements, repaired stimulus, reconciled targets | Valid samples with hardware/build metadata; no inherited “pass” labels |
| 2. Fix correctness and state | P0-1 through P0-3 | Capture exclusions hold; status and persistence failures are truthful and actionable |
| 3. Improve speed | P1-1 through P1-3 | Reduced unnecessary work; measured CPU, exposure, and memory gates pass |
| 4. Improve daily use | P1-4 and P1-5 | Setup tasks succeed; controls, Arabic layouts, and previews pass usability checks |
| 5. Validate quality and release | P2-1 and P2-2 | Quality results, accessibility review, and system/release matrix are complete |

Correctness work can begin while preparing the measurement harness. Run timed measurements in a quiet session. Ship focused changes with one regression check for each new failure path; use the existing Swift Testing and selftest infrastructure.

## 5. Verification commands

Run these from the repository root during implementation. This plan did not execute them.

```sh
swift build
swift test
swift run sitr-bench --selfcheck
scripts/check-strings.sh
scripts/build-app.sh
scripts/check-entitlements.sh build/Sitr.app
```

For steady-state performance, use the release bundle assembled above and the debug stimulus produced by `swift build`. Run each command separately on the test desktop:

```sh
scripts/measure-system.sh static 120
scripts/measure-system.sh browsing 120
scripts/measure-system.sh video 120
build/Sitr.app/Contents/MacOS/Sitr --selftest pipeline --motion --seconds 600
```

Use [the integration recipe](m3/integration.md#stimulusapp-the-second-process) to prepare the separate stimulus before the filter/Curtain checks. Use [Bench/README.md](../Bench/README.md) to prepare the full labeled datasets; report missing files and evaluated counts. Launch automated capture checks directly from the shell as described in [dev.md](dev.md), and reserve real permission/sleep/display changes for the test session.

## 6. Scope limits

Keep the existing architecture, local processing, and native controls. Add no analytics backend, networking entitlement, new UI framework, general cache layer, or automatic model download for this work. Change capture rate/resolution, rendering layout, window polling, or model choice only when a measurement identifies the need and the resulting build passes protection-quality checks.
