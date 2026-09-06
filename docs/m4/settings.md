# Settings window — M3-T08 Rules UI, M4-T02 Appearance, M4-T03 Shortcuts, M4-T04 General + About

Five tabs (PRD FR9), one file per tab under `Sources/Sitr/UI/`, bound straight to `AppModel` / `Preferences` (no view
models). Strings are literals until the String Catalog (M4-T05). Tab order follows the brief: General, Protection,
Appearance, Shortcuts, About. Window 560×600 pt, fixed (grouped Forms scroll where a tab is taller, About only).

## Files
- `UI/SettingsView.swift` — `TabView`; `SITR_OPEN_SETTINGS=<general|protection|appearance|shortcuts|about>` picks the initial tab.
- `UI/GeneralTab.swift` — Launch at login (`LaunchAtLoginToggle`), Language, "Reduce frame rate in Low Power Mode", `GeneralTab.relaunch()`.
- `UI/ProtectionTab.swift` — hidden set + Strict (moved from General), Default Rule, overrides `Table`, Add ▸ running apps / Other…,
  "Use recommended settings", `AppInfo` (icon + name per bundle ID), `AppRule: Identifiable`, `RuleMode.title`.
- `UI/AppearanceTab.swift` — style / strength / padding controls, `CoverPreview` (`NSViewRepresentable`) → `PreviewView`, `SampleScene`.
- `UI/ShortcutsTab.swift` — `HotkeyRecorder` (`NSViewRepresentable`) → `RecorderView`, conflict list, Reset to Default.
- `UI/AboutTab.swift` — version/build, GPL-3.0 + repo link, Verify privacy (command + Copy), FR11 caveats, model notices, Check for Updates.
- `UI/MenuBar.swift` — `MenuBarLabel.onAppear` opens Settings when `SITR_OPEN_SETTINGS` is set (dev smoke runs only).
- `AppModel.swift` — `rulesStore`, `rulesDirectory`, `updateRules(_:)`; init loads `rules.json`.
- `Preferences.swift` — `AppLanguage`, `language`, `lowPowerReducesFrameRate`.
- `Hotkey/HotkeyManager.swift` — `KeyCombo.init(keyCode:flags:)`, `keyName` via `UCKeyTranslate`, `validationProblem`, `conflictNote`, `knownConflicts`.
- Tests: `Tests/SitrTests/SettingsTests.swift` (new), `HotkeyTests.swift` (suite now `@MainActor`, one assertion updated, `HotkeyValidationTests` added).

## What each tab does

### Protection (M3-T08)
- Hide (Women / Men / Everyone) and Blur Unknown (forced on + disabled for Everyone) — unchanged behaviour, moved here.
- Default Rule picker Off / Blur / Curtain → `model.updateRules { $0.defaultMode = … }`.
- Overrides `Table(selection:)`: app icon (`NSWorkspace.urlForApplication(withBundleIdentifier:)` + `icon(forFile:)`; generic
  app-bundle icon and "Not installed" when absent), display name (`CFBundleDisplayName` → `CFBundleName` → file name; bundle ID
  when not installed), per-row Mode picker (upsert), ⊖ button (remove), ⌫ on selected rows (`onDeleteCommand`). Rows are
  focusable/arrow-navigable through the standard `Table`.
- Add ▸ lists `NSWorkspace.shared.runningApplications` with `.regular` activation policy (ourselves excluded), sorted by name;
  "Other…" runs an `NSOpenPanel` limited to `.application` and reads `Bundle(url:)?.bundleIdentifier` (sandbox: the
  `files.user-selected.read-only` entitlement covers it). New overrides start as Blur; an existing one is selected instead.
- "Use recommended settings" → `RecommendedPreset.apply(to:)`; disabled with a "Recommended settings applied" label while
  `RecommendedPreset.isApplied` holds (a user edit to a preset app re-enables it).
- Persistence: `RulesStore(directory: AppModel.rulesDirectory)` = `FileManager.urls(for: .applicationSupportDirectory)/Sitr`
  (inside the sandbox: `~/Library/Containers/com.goldentik.Sitr/Data/Library/Application Support/Sitr/rules.json`). Loaded in
  `AppModel.init`; when no file exists the in-memory seed is `Rules(defaultMode: .blur)` (dev placeholder, not written, so
  M4-T01 onboarding can still detect a first launch). `updateRules` saves after every change and, through `policy.rules`
  `didSet` → `onPolicyChanged` → `Pipeline.update(policy)`, reaches the covers on the next frame without a restart.
- Not here: the capture-filter update that stops Off apps from being captured is M3-T03. Today Off removes covers only.

### Appearance (M4-T02)
- Segmented style picker, Blur Strength 0–100 % (default 70), Body Padding 0–50 % (default 15), bound to
  `Preferences.coverStyle / blurStrength / bodyPadding`. Strength is disabled for Solid.
- Live propagation: `Runtime.observe()` already tracks the three keys with `withObservationTracking` and calls
  `pipeline.update(CoverAppearance)` on every change (docs/m2/pipeline.md); the pipeline reads it per frame. No hook needed.
- Preview: `SampleScene` draws a room and a standing figure with CoreGraphics into a 960×600 BGRA IOSurface buffer
  (480×300 pt at 2 px/pt; the face is 30 pt = 60 px, FR3's minimum-strength criterion) and wraps it in a `Frame`.
  `PreviewView` calls the real `CoverRenderer.render(id:style:strength:padding:rect:frame:)` with the figure's body box and
  shows the returned `CoverLayerSpec` exactly as `OverlayPanel` does (layer `contents` = the spec's IOSurface, or
  `backgroundColor` = its solid color, frame through `appKitRect`), scaled to the 400×250 pt view. Nothing third-party.

### Shortcuts (M4-T03)
- `RecorderView`: click (or Space / ↩ while focused) starts recording; the next `keyDown` / `performKeyEquivalent` becomes
  `KeyCombo(keyCode:flags:)`; ⎋ cancels. Focus alone never records (the window gives the first focusable view initial focus).
- Validation (`KeyCombo.validationProblem`): needs a modifier; not Option alone; not Shift alone; not a reserved system
  shortcut (⌘Q, ⌘W, ⌘H, ⌘M, ⌘,, ⌘⇥, ⌘⇧Q, ⌘⌥⎋, ⌃⌘Q, ⌘⇧3/4/5). Rejections show a reason in red under the recorder.
- Conflict list (static): ⌥Space Siri / ChatGPT, ⌘Space Spotlight, ⌃Space input sources, "⌥ + key" warning. The current combo
  gets an orange `conflictNote` when it matches, or when it has Option without ⌃/⌘. `HotkeyManager.registrationStatus ≠ noErr`
  shows a red line too.
- Reset to Default (⌃⌥Space, disabled while current). Rebinding goes through `AppModel.setHotkey` → `HotkeyManager.rebind`.
- Key names: `UCKeyTranslate` on `TISCopyCurrentKeyboardLayoutInputSource`'s `kTISPropertyUnicodeKeyLayoutData`
  (`kUCKeyActionDisplay`, no modifiers, uppercased), a glyph table for keys the layout does not name (Space, ↩, ⇥, ⎋, ⌫, ⌦,
  arrows, Home/End/Page, F1–F20), "Keypad N" for the numeric pad, "Key N" fallback. Glyph order stays ⌃⌥⇧⌘.
  `displayString` / `keyName` are `@MainActor` (Text Input Sources is a main-thread API), hence `HotkeyTests` is `@MainActor`.

### General (M4-T04)
- Launch at login (unchanged `LaunchAtLoginToggle`).
- Language System / English / Arabic: `Preferences.language` stores the choice and writes `AppleLanguages = ["en"|"ar"]` into
  the app's defaults domain (removes it for System). While the choice differs from the language the process started with,
  "Relaunch now" appears: `NSWorkspace.openApplication(at: Bundle.main.bundleURL, configuration:)` with
  `createsNewApplicationInstance = true`, then `NSApp.terminate`.
- "Reduce frame rate in Low Power Mode" → `Preferences.lowPowerReducesFrameRate` (default on). Capture behaviour is M4-T06.

### About (M4-T04, M5-T05)
Name, `CFBundleShortVersionString (CFBundleVersion)`, one-line description, Check for Updates…, "GPL-3.0" + link to
`https://github.com/haithamassoli/Sitr`, Verify privacy (`codesign -d --entitlements :- --xml /Applications/Sitr.app`, Copy
button, one sentence: sandbox true, no `network` keys), FR11 caveats (entire screen usually shows covers; single window does not
include the overlay; screenshots include covers), model notices (YOLOX-S Apache-2.0; dima806 FairFace classifier Apache-2.0,
FairFace CC BY 4.0) linking to `THIRD_PARTY_NOTICES.md` (file lands with M5-T07).

## Verified
- `swift build`: 0 warnings in the files above. `swift test`: 125 tests / 14 suites green (16 new: rules seed / edit → hook +
  file / remove / preset state / fresh-model reload, `AppInfo` fallback, language mapping + `AppleLanguages` domain write,
  Low Power default, About texts, tab list, `SampleScene` geometry + pixel check (row 0 is the top), preview through the real
  renderer for all three styles, key names, event-flag mapping, validation, conflict notes). `scripts/build-app.sh --debug`
  + `scripts/check-entitlements.sh`: OK.
- Smoke run, shell-launched `build/Sitr.app/Contents/MacOS/Sitr --quit-after 7` with `SITR_OPEN_SETTINGS=<tab>` for all five
  tabs: `CGWindowListCopyWindowInfo` showed one layer-0 window 560×688 titled with the tab name (plus the 1470×956 overlay
  panel at layer 1001); each was captured with `screencapture -l` and reviewed. Fixes from the review: fixed table height so
  Add / preset stay in view, window height 600 so the preview is whole, recorder no longer records on initial focus. Every run
  exited 0 with no `Sitr` process left. Protection was captured with a seeded `rules.json` (preset + TextEdit Off + an
  uninstalled bundle ID): real icons for Safari/Chrome/Arc, generic icon + "Not installed" for the rest, preset button in its
  "applied" state. The seed file was removed afterwards; screenshots were deleted.
- Rules → covers live: by code path (`updateRules` → `policy.rules` didSet → `onPolicyChanged` → `Pipeline.update`), the same
  path `AppModelTests.policyChangesReachTheHook` exercises; `editsReachThePolicyHookAndTheFile` checks the rules variant.

## Hooks needed elsewhere
- None in `Runtime` for appearance or rules; both are already wired (`Runtime.observe()` for appearance, `onPolicyChanged` for
  rules).
- M3-T03: `Runtime` should rebuild the `SCContentFilter` per display from `model.policy.rules` inside its `onPolicyChanged`
  closure (Off apps excluded / Default Off → include only overrides) — the UI already delivers the new `Rules` there.
- M4-T06: read `model.preferences.lowPowerReducesFrameRate` where `NSProcessInfoPowerStateDidChange` is handled.
- M4-T05: every string in the five tab files is a literal.
- M5-T07: `THIRD_PARTY_NOTICES.md` (About links to it on GitHub).

## Manual pending
- Recording a real key in the recorder (⌘Q rejected with the message; ⌘⌥R accepted and `hotkey register … status=0` logged);
  the `NSOpenPanel` "Other…" flow; VoiceOver pass over the table and recorder (labels are set).
- Language: the relaunch itself and Arabic RTL — meaningful only after M4-T05 adds the `ar` localization (today the bundle has
  no Arabic strings, so a relaunch shows no change). Mapping and the `AppleLanguages` write are unit-tested.
- Solid color in the preview follows the appearance at the time the tab opened (`CoverRenderer.refreshSolidColor` is not
  called on light/dark switches while Settings is open).

## Shortcuts (`ponytail:` in code)
- Missing `rules.json` → in-memory Blur seed (M4-T01 replaces with Off after onboarding).
- `AppInfo` process-lifetime cache; `GeneralTab.launchLanguage` read once from the standard domain.
- Reserved system-shortcut list is a short fixed table by ANSI key position.
- One hot key per process (unchanged). The current Reveal combo cannot be re-recorded while registered (Carbon swallows it),
  which is a no-op anyway.
- New overrides default to Blur; `SampleScene` force-unwraps its `CVPixelBufferCreate`.
