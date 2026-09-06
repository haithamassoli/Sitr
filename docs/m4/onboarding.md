# Onboarding — M4-T01, and the code half of M4-T11 Accessibility basics

Five-step first-launch window (PRD FR8), opened by `AppModel` itself, no new SwiftUI scene. Strings are literals until the
String Catalog (M4-T05). Window 560×400 pt content, centered, not resizable, `titlebarAppearsTransparent`, closes on finish.

## Files
- `Sources/Sitr/UI/Onboarding.swift`
  - `OnboardingFlow` — pure, `nonisolated`, unit-tested: `step`, `permissionOnly`, `permissionGranted`, `hiddenSet`
    (optional: no preselection), `strict`, `usePreset`, `launchAtLogin`, `finished`; `canContinue`, `advance()`, `back()`,
    `skipPermission()`, `choosePreset(_:)`, `effectiveStrict` / `strictLocked` (Everyone forces Strict on), `rulesOnFinish(_:)`,
    `opensSettingsOnFinish`, `registersLaunchAtLogin`; the two `AppModel` hooks `seedDefaultMode(onboardingCompleted:environment:)`
    and `reopens(from:to:)`.
  - `OnboardingWindow` — one `NSWindow` + `NSHostingView`; `present(model:)` brings an existing window to the front instead of
    opening a second one; `close()`; `registerLaunchAtLogin()`; `devStep` (`SITR_ONBOARDING_STEP`).
  - `OnboardingView` — the pages and the bottom bar.
- `Sources/Sitr/AppModel.swift` — `showsOnboarding`, the two triggers, `completeOnboarding(_:)`, the new `rules.json` seed.
- `Sources/Sitr/Preferences.swift` — `onboardingCompleted` (`UserDefaults` key `onboardingCompleted`).
- `Sources/Sitr/UI/SettingsView.swift` — `initialTab` (settable; "Configure myself" sets `.protection`).
- `Tests/SitrTests/OnboardingTests.swift`; two assertions in `SettingsTests.swift` follow the seed change (Off instead of Blur).

## Steps (FR8)
1. Welcome: what Sitr does, "everything happens on this Mac, no network access", the `codesign` command (`AboutTab.verifyCommand`).
2. Screen Recording: "Allow Screen Recording" → `PermissionMonitor.request()`, "Open System Settings" → `openSystemSettings()`;
   status line (granted / not yet: nothing covered, warning icon); the monthly re-approval note (macOS 15.1+). Continue is
   disabled until the monitor reports `granted`, and a grant that arrives while on this step advances automatically.
   "Skip for now" moves on without the grant. Return does nothing while Continue is disabled; Esc is not bound anywhere.
3. Hidden set: radio group Women / Men / Everyone, nothing preselected, required. "Blur Unknown (Strict Mode)" switch, on by
   default; for Everyone it shows on and disabled (`effectiveStrict`).
4. Recommended Protection: the FR6 table (Browsers Safari, Chrome, Arc → Curtain; Communication Telegram, WhatsApp, Discord
   → Curtain). "Use recommended settings" (default button) or "Configure myself"; both go to step 5.
5. Done: "Hold ⌃⌥Space to reveal … covers come back after 30 seconds" (`KeyCombo.displayString`), Launch at login switch (on).
   Finish.

Finish (`AppModel.completeOnboarding` + the view): hidden set and Strict stored (`setHiddenSet` / `setStrict`); rules =
current rules with `defaultMode = .off`, plus `RecommendedPreset.apply` when chosen, through `updateRules` (writes `rules.json`,
reaches the pipelines); `onboardingCompleted = true`; `SMAppService.mainApp.register()` when the switch is on; window closed;
"Configure myself" then sets `SettingsView.initialTab = .protection` and calls the `openSettings` environment action.

## Triggers
- First launch: end of `AppModel.init`, next run-loop turn, when `preferences.onboardingCompleted == false`.
- Needs permission: `policy.didSet` → `OnboardingFlow.reopens(from: oldValue.health, to: policy.health)` (a transition *into*
  `.needsPermission`) → `present`. With onboarding already completed the window is the permission step alone ("Done" once granted,
  "Skip for now" closes); before completion the full flow opens, so a first launch without the grant is not disturbed.
- Both are gated by `AppModel.showsOnboarding`: running from a `.app` bundle, no `--selftest` argument, no `SITR_DEV_BLUR=1`. The
  test runner and the bare `.build/debug/Sitr` never open a window.
- The window keeps its own `PermissionMonitor` (`// ponytail:` — Runtime's lives in `SitrApp.swift`); it only polls
  `CGPreflightScreenCaptureAccess` (5 s while denied, plus app activation).

## `rules.json` seed (replaces the M2 dev placeholder)
Missing file → `Rules(defaultMode: OnboardingFlow.seedDefaultMode(...))`: **Off**, except Blur when `onboardingCompleted == false`
**and** `SITR_DEV_BLUR=1`. Nothing is written until the user changes something (the finish writes it). The `// ponytail:` seed-Blur
note in `AppModel` is gone. Consequence for the pipeline selftests (`Selftest.bootRuntime` builds `AppModel(preferences:)` on the
container's store): run them with `SITR_DEV_BLUR=1`, or have `Selftest.run()` `setenv` it — see "Hooks".

## Skipping the permission
Nothing in the finish touches `policy.health`, so a skipped permission leaves `Runtime`'s `.needsPermission`: `AppModel.status ==
.needsPermission`, `iconState == .warning`, `revealAvailable == false` (unit-tested in `OnboardingModelTests`).

## Accessibility (M4-T11, code part)
- Onboarding: `accessibilityLabel` / `accessibilityHint` on every control whose text is not self-explanatory (hidden set picker,
  Strict switch with the "always on for Everyone" hint, permission buttons, Skip for now, preset buttons, Launch at login), the
  verification command read as "Verification command: …", page titles as headers, decorative symbols hidden, table rows combined.
  Focus: `@FocusState` + `defaultFocus` on the primary button, the hidden-set picker when step 3 appears; layout order = tab
  order. No motion: `.transaction { $0.animation = nil }` on the root, `window.animationBehavior = .none`, no transitions.
- Settings tabs and menu bar: hints added where the label alone does not say what happens (Pause / Disable / Resume, Check for
  Updates, Relaunch now, Low Power toggle, Hidden set, Strict, Default Rule, Add, Use recommended settings, Cover style, Reset to
  Default, Copy the verification command); conflict-list rows combined; every control already carried a label.
- Overlay panels: `OverlayPanel` sets `setAccessibilityElement(false)` on the panel and its content view and overrides
  `isAccessibilityElement()` to `false` (read-only check, unchanged).
- The Accessibility Inspector audit itself is a manual item.

## Dev smoke (`SITR_ONBOARDING_STEP=<1…5>`)
Opens the window at that step (flag ignored), shows step 2 as not granted, never auto-advances, and the finish skips the Launch at
login registration. `build/Sitr.app/Contents/MacOS/Sitr --quit-after 7` from the shell with the flag deleted first
(`defaults delete com.goldentik.Sitr onboardingCompleted`; the domain follows the sandbox container).

## Verified
- `swift build` 0 warnings, `swift test` 150 tests / 19 suites green (15 new), `scripts/build-app.sh --debug` +
  `check-entitlements.sh` OK.
- Smoke, first launch with the flag absent: `CGWindowListCopyWindowInfo` shows one layer-0 window "Sitr Setup" 560×432 (with title
  bar) centered, next to the overlay panel at layer 1001; steps 1–5 via `SITR_ONBOARDING_STEP`, each captured with
  `screencapture -l` and reviewed (fixes: window height 480 → 400, primary buttons `.borderedProminent`). Every run exited 0 with
  no `Sitr` process left; `onboardingCompleted` absent before and after.
- Interaction, driven through the accessibility tree of Sitr's own process (`AXUIElementPerformAction(kAXPress)` scoped to its
  pid; nothing reaches other apps): every control shows up with its label (`AXDescription`) and hint (`AXHelp`). Run A from step 1:
  Continue → step 2 with Continue `enabled=0` and its hint, Skip for now → step 3, Women (`value=1`), Strict `value=1` "Recommended
  on", Continue, Configure myself → step 5 (Launch at login `value=1`), Finish → window gone, `onboardingCompleted=1`, `hiddenSet`
  women, `rules.json` not written (nothing changed from the Off seed), Settings window titled "Protection" open (after the
  `onAppear` fix; the first attempt opened "General" because the scene's view value is built at launch). Run B from step 4: Use
  recommended settings, Finish → `rules.json` with `defaultMode: off` and the eight preset overrides as Curtain, no Settings window.
  `--launch-at-login status` afterwards: not registered (dev-step guard). Both runs exited 0 with no `Sitr` process left; the
  defaults domain was restored from an export and the smoke `rules.json` removed.
- Shell-launched agent apps are not allowed to activate themselves on this macOS (`NSApp.activate()` is a cooperative request), so in
  the smoke runs the window opened behind the terminal; Return = default button is by `.keyboardShortcut(.defaultAction)` and not
  exercised (a real key event needs the app to be active).

## Manual pending
- Fresh user account: the real first launch from Finder (activation, the TCC dialog from "Allow Screen Recording", auto-advance on
  grant, Launch at login registration), the monthly re-approval reopen, VoiceOver pass, Accessibility Inspector audit.
- Return / Esc with a real keyboard; a click-through of the flow with the mouse.

## Hooks needed elsewhere
- `Selftest.bootRuntime` (SitrApp/Selftest owner): pipeline, motion and failstate selftests need Blur covers → run with
  `SITR_DEV_BLUR=1` or `setenv("SITR_DEV_BLUR", "1", 1)` before building the `AppModel`.
- M4-T05: every string in `Onboarding.swift` is a literal.
- `docs/tasks.md`: tick M4-T01 (code) and the code half of M4-T11 (orchestrator).
