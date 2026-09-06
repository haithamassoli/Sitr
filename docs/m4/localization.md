# Localization EN/AR — M4-T05 (and the M5-T06 READMEs)

One String Catalog, one gate script, no framework. English is the source language; every key has an Arabic value.

## Files
- `App/Resources/Localizable.xcstrings` — the catalog: 193 keys, source `en`, every key with an `ar` `stringUnit` in
  state `translated`, `extractionState: manual` on every key (hand-maintained; Xcode never marks them stale).
- `scripts/build-app.sh` — `xcrun xcstringstool compile … --output-directory Contents/Resources` produces
  `en.lproj/Localizable.strings` and `ar.lproj/Localizable.strings` (XML plists); the `.xcstrings` source is removed
  from the bundle. A malformed catalog exits non-zero, a missing `ar.lproj` fails the build explicitly.
- `scripts/check-strings.sh` — the gate (python3, in CI after the unit tests): scans `Sources/Sitr/**/*.swift` for the
  first-argument literal of `Text( Button( Toggle( Label( Section( LabeledContent( Picker( TableColumn( Menu( Link(
  LocalizedStringKey( String(localized:` and `.accessibilityLabel/Hint/Value(`, turns `\(…)` into a `%…` wildcard,
  and fails when a literal is not a catalog key or its `ar` value is missing / not `translated`. Whole-line `//`
  comments are blanked; `"""` literals are rejected. Unreferenced keys are printed as warnings.
- `Tests/SitrTests/LocalizationTests.swift` — the catalog parses with source `en`; every key has a translated Arabic
  value whose `%` specifiers match the key (positional reordering allowed); the FR7 status keys exist and the code
  returns exactly those keys in the test process; `build/Sitr.app/…/ar.lproj/Localizable.strings` (when built) carries
  `Protected` with an Arabic value; `AppLanguage` writes `AppleTextDirection` next to `AppleLanguages`.
- `App/Info.plist` — `CFBundleLocalizations` `[en, ar]`; `CFBundleDevelopmentRegion` stays `en`.
- Code: `Sources/Sitr/UI/*.swift`, `AppModel.swift` (status line), `Notifier.swift`, `Hotkey/HotkeyManager.swift`,
  `LaunchAtLogin.swift`, `Preferences.swift`.

## How strings reach the catalog
- SwiftUI literals (`Text("…")`, `Button("…")`, `Toggle`, `Picker`, `Section`, `Label`, `LabeledContent`,
  `TableColumn`, `Menu`, `Link`, `.accessibilityLabel/Hint`) are `LocalizedStringKey`s and look the key up in the main
  bundle by themselves; interpolations become `%@` (String) / `%lld` (Int) in the key.
- Anything built as a `String` (status texts, notifications, key names, validation and conflict texts, panel
  messages, window title, recorder text, AppKit accessibility strings) goes through `String(localized:comment:)`.
- Rules that keep the gate honest: a literal must directly follow one of the call sites above (so ternaries and
  helper parameters were rewritten: `page(_:_ title: Text)`, `primaryTitle`, `continueHint`, if/else instead of
  `Text(cond ? "a" : "b")`); interpolated values are simple identifiers (`let hotkey = …`) and non-`Int` numbers are
  converted to `Int` first so the specifier is `%lld`.
- `AppLanguage.title` keeps the endonyms `English` / `العربية` verbatim on purpose; only `System` is a key.
- Glyph key names (↩ ⇥ ⎋ ⌫ arrows F1–F20) stay verbatim; `Space`, `Help`, `Keypad %@`, `Key %lld` are keys.

## RTL audit
- Layout direction on macOS comes from the `AppleTextDirection` default, not from `AppleLanguages`: with
  `-AppleLanguages "(ar)"` alone every string was Arabic but every layout stayed left-to-right (first smoke run).
  `-AppleTextDirection YES` mirrors everything. macOS sets that default system-wide when the primary language is RTL;
  the in-app Language picker only wrote `AppleLanguages`, so `Preferences.language` now writes `AppleTextDirection`
  (true for Arabic, false for English, removed for System) into the same domain.
- Forced LTR in exactly two places: the `codesign` verification command (`.environment(\.layoutDirection,
  .leftToRight)` in About and onboarding step 1: LTR text, left-aligned box) and the hotkey string.
  `KeyCombo.displayString` wraps the combo in a left-to-right isolate (U+2066 … U+2069) only when the key name is in
  an RTL script, so `⌃⌥مسافة` keeps the ⌃⌥⇧⌘ order with the glyphs in front of the key name inside Arabic sentences
  (menu bar, onboarding step 5, Shortcuts recorder and conflict list); `⌃⌥Space` in English is unchanged, which keeps
  `HotkeyTests` untouched. Verified with an AppKit drawing probe: LRI/PDI and LRE/PDF both work, LRO reverses letters.
- Everything else mirrors on its own: TabView tab order, Form rows (label right, control left), `Table` columns,
  `Grid`, `HStack`s, radio groups, switches, the onboarding bottom bar (Back right, primary button left), `›` breadcrumb
  chevrons (a mirrored pair, they point along the reading direction), trailing punctuation after Latin runs.
- Numerals: dynamic values follow the locale (`%lld`, `Date.formatted`, `formatted(.percent)`); under `ar` the app's
  `Locale.current` takes the Arabic language with the system region, so this machine (region JO) shows Arabic-Indic
  digits (`الخطوة ١ من ٥`, `٪٧٠`). Static counts in Arabic strings therefore use Arabic-Indic digits too (١٥ دقيقة،
  ٣٠ ثانية، ٧٠٪); product versions and license identifiers keep Latin digits (`macOS 15.1`, `CC BY 4.0`). Regions
  with Latin numbering (ar_MA, ar_TN, …) will see a mix in prose only.
- `%` inside non-interpolated keys (`Defaults: Gaussian, 70%, 15%.`) is safe: SwiftUI formats only keys with
  arguments; the Appearance footer rendered correctly.

## Verification (this machine, macOS 26.6.2, Xcode 26.6)
- `swift build` 0 warnings in the touched files; `swift test` 163 tests / 21 suites green (5 new in
  `LocalizationTests`; `AppModelTests.safetyTickerCoversWhenTheModifiersAreNotHeld` is timing-based and flaked once
  while other agents' builds loaded the machine, green on re-runs); `scripts/build-app.sh --debug` → `en.lproj` +
  `ar.lproj` (193 entries each);
  `scripts/check-entitlements.sh` OK; `scripts/check-strings.sh` → `OK: 193 literals … 193 keys, 0 unreferenced`;
  `actionlint .github/workflows/ci.yml` clean.
- Smoke runs from the shell (never `open`), one process per screen, each exiting on its own:
  `SITR_OPEN_SETTINGS=<general|protection|appearance|shortcuts|about> build/Sitr.app/Contents/MacOS/Sitr --quit-after 9
  -AppleLanguages "(ar)" -AppleTextDirection YES` and `SITR_ONBOARDING_STEP=<1…5> …` (the dev step opens the window
  regardless of `onboardingCompleted`, which was absent in the app's domain anyway; no default was changed). Every
  layer-0 window was captured with `screencapture -l <windowID>` and reviewed at 1× and zoomed: 5 tabs + 5 onboarding
  steps, all Arabic, all mirrored, no untranslated text, hotkey and command LTR as intended. Screenshots were deleted
  afterwards; nothing of the user's was touched.
- The menu bar menu cannot be captured without a click; its strings (status line incl. `Paused until %@`, Pause ▸
  15 minutes / 1 hour, Resume / Disable / Enable Protection, Reveal line, Settings…, Check for Updates…, Quit Sitr)
  are covered by the gate and by `LocalizationTests`.

## Translations to review first (least certain, in `App/Resources/Localizable.xcstrings`)
1. `Degraded` → «أداء الحماية منخفض» (status line; alternatives: «الحماية متدنّية»، «أداء منخفض»).
2. `Curtain` / `Blur` / `Off` as picker items → «الستارة» / «التمويه» / «إيقاف» (definite vs indefinite mix).
3. `Gaussian` / `Pixelate` / `Solid` → «غاوسي» / «بكسلة» / «مصمت».
4. `Reveal Hold` → «الكشف المؤقت», and "hold %@" → «اضغط باستمرار على %@».
5. `Finish` → «إتمام» (kept apart from `Quit` → «إنهاء»).
6. `Configure myself` → «سأضبطها بنفسي».
7. `Body Padding` → «هامش الجسم».
8. `%@ is %@, a system shortcut.` → «%1$@ اختصار للنظام (%2$@).» and the reserved-use nouns («الإنهاء»، «مبدّل التطبيقات»).
9. `Space` → «مسافة» inside shortcuts (vs «مفتاح المسافة»), `⌥ + key` → «⌥ + مفتاح».
10. Digits: Arabic-Indic in static prose (١٥ دقيقة، ٣٠ ثانية، ٧٠٪) with Latin digits for `macOS 15.1` / `CC BY 4.0`.

## Follow-ups
- Native-speaker review of the catalog (manual item of M4-T05); the list above is where to start.
- Strings that other tasks add in `Sources/Sitr/Pipeline/**`, `SitrApp.swift`, `Selftest.swift`, `Capture/**`,
  `Windows/**`, `Overlay/**` (none user-facing today) will fail `scripts/check-strings.sh` until they are added to the
  catalog; M4-T07's degraded-state texts and any new notification go through `String(localized:)` + a catalog entry.
- `docs/m4/settings.md` and `docs/m4/onboarding.md` still say "strings are literals until M4-T05"; `CHANGELOG.md`
  `Unreleased` has no line for the Arabic localization yet (both outside this task's files).
- A real Arabic system (System Settings language Arabic, an `arab`-numbering region) and a VoiceOver pass in Arabic
  are manual items; so is the in-app Language relaunch into RTL, now that `AppleTextDirection` is written.
- The `.github/workflows/ci.yml` Xcode-select step gained `# shellcheck disable=SC2012` so `actionlint` is clean.
