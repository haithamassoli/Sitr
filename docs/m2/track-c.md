# M2 Track C — UI: AppModel, Reveal hot key, menu bar, launch at login

Tasks: M2-T13 (app side), M2-T14, M2-T15, M5-T05. Built on `SitrCore` (`Policy`, `RevealState`); no Capture/Overlay/Permission code touched.

## Files
- `Sources/Sitr/AppModel.swift` — `@Observable @MainActor final class AppModel`, single source of truth.
- `Sources/Sitr/Preferences.swift` — `UserDefaults` persistence: `hiddenSet`, `strictMode`, `hotkey`.
- `Sources/Sitr/Hotkey/HotkeyManager.swift` — `KeyCombo` + Carbon `HotkeyManager`.
- `Sources/Sitr/UI/MenuBar.swift` — `MenuBarLabel` (icon) and `MenuBarContent` (FR7 menu).
- `Sources/Sitr/UI/SettingsView.swift` — placeholder Settings: General, About.
- `Sources/Sitr/LaunchAtLogin.swift` — `LaunchAtLoginToggle` view + `LaunchAtLogin.selfcheck` (shell check).
- `Sources/Sitr/SitrApp.swift` — `MenuBarExtra` + `Settings` scenes; `--selftest` untouched; dev flags `--launch-at-login [on|off|status]`, `--quit-after <s>`.
- `Tests/SitrTests/AppModelTests.swift`, `Tests/SitrTests/HotkeyTests.swift`.

## AppModel API
| Member | Meaning |
|---|---|
| `policy: Policy` | Hidden set, strict, `protection`, `health`, rules. Writable; `didSet` fires `onPolicyChanged` when it changes. |
| `reveal: RevealState` | Reveal Hold state; `didSet` fires `onRevealChanged` on covered ↔ revealed transitions and runs the safety ticker. |
| `preferences: Preferences`, `hotkey: HotkeyManager` | Owned for the process lifetime. |
| `status: Status` | `.protected / .paused(until: Date) / .disabled / .needsPermission / .degraded`; `.text`, `.iconState`, `.revealAvailable`. |
| `statusText`, `iconState`, `revealAvailable` | Shortcuts on `status`. `revealAvailable` == `status == .protected` (active protection and `health == .ok`). |
| `static status(for:now:wallClock:)` | Pure FR7 mapping, unit-tested for every protection × health combination. Priority: needsPermission > disabled > paused (until > now) > degraded > protected. |
| `pause(minutes:)`, `pause(seconds:)`, `resume()`, `enable()`, `disable()` | Protection state. `enable()` is `resume()`. |
| `setHiddenSet(_:)`, `setStrict(_:)`, `setHotkey(_:)` | Update policy / hot key and persist. |
| `hotkeyPressed()`, `hotkeyReleased()` | What the Carbon events call; press is ignored unless `revealAvailable`. |
| `refreshTimers()` | Arms the auto-resume `Task`; runs on `NSWorkspace.didWakeNotification`. |
| `static releasesURL`, `static version`, `static checkForUpdates()` | M5-T05. |

Clocks: `policy.protection`'s `until` is on the `CACurrentMediaTime()` clock (what the pipeline passes to `Policy.covers(for:now:)`). That clock stops during sleep, so the pause deadline is also kept as a wall-clock `Date`; on wake `refreshTimers()` resumes if it passed, otherwise rewrites `until` from the wall clock and re-arms the timer. `Task.sleep` runs on the continuous clock as well.

## Hook points for the integration agent
- `model.onPolicyChanged = { policy in pipeline.update(policy) }` — a `Sendable` snapshot per change; pass `CACurrentMediaTime()` as `now`.
- `model.onRevealChanged = { revealed in panels.forEach { $0.setRevealed(revealed) } }` — main actor, within the same run-loop turn as the Carbon event.
- Health: `model.policy.health = .needsPermission / .degraded / .ok` from PermissionMonitor / CaptureSession (the didSet propagates).
- Read `model.policy` anywhere on the main actor; `model.preferences.hotkey.displayString` for hints.

## Hot key (M2-T13 app side)
- `KeyCombo { keyCode: UInt32, carbonModifiers: UInt32 }`, Codable; `displayString` glyph order ⌃⌥⇧⌘ (`⌃⌥Space` default: keyCode 49, `controlKey|optionKey`); `modifiersHeld(in: NSEvent.ModifierFlags)` superset check.
- `HotkeyManager(combo:)`: `RegisterEventHotKey` + `InstallEventHandler` for `kEventHotKeyPressed/Released` on the application target; `rebind(_:)`; `unregister()` on `NSApplication.willTerminateNotification`; `registrationStatus` for M4-T03's conflict UI.
- Safety while revealed (AppModel): 100 ms `Task` loop → `reveal.tick(now:)` (30 s) and `lostRelease()` when `NSEvent.modifierFlags` no longer holds the combo's modifiers; `lostRelease()` on `didResignActiveNotification`.

## Menu bar (M2-T14) and Settings
FR7 order: status `Text`; Pause Protection ▸ 15 minutes / 1 hour (replaced by Resume Protection while paused, disabled while Disabled); Disable ↔ Enable Protection; "Reveal: hold ⌃⌥Space" / "Reveal unavailable"; Settings… (`openSettings` environment action + `NSApp.activate()`); Check for Updates…; Quit ⌘Q. Every item has an `accessibilityLabel`. Icon: `eye.slash`, dimmed = the same symbol drawn at 50 % alpha into a template `NSImage` (SwiftUI `.opacity` on the label is ignored by the status item, see below), warning = `eye.trianglebadge.exclamationmark`. Settings: General (Launch at login, Hide picker, Strict toggle forced on and disabled for Everyone), About (version, Check for Updates…).

## Verified
- `swift build`: 0 warnings. `swift test`: 64 tests / 7 suites green (24 new: status matrix 10 rows + texts, pause/resume/disable/enable, policy hook, auto-resume after 0.2 s, wake re-sync of a drifted deadline, elapsed deadline resumes on refresh, reveal press/release + unavailable while paused / needsPermission, safety ticker covers within 400 ms when no modifiers are held, persistence round trip; KeyCombo default, glyph order, superset check, Codable). `scripts/build-app.sh --debug` + `check-entitlements.sh`: OK.
- Hot key, `build/Sitr.app/Contents/MacOS/Sitr --quit-after 14` from the shell, unified log (`log stream --predicate 'subsystem == "com.goldentik.Sitr"'`): `hotkey register ⌃⌥Space status=0` on every launch; ⌃⌥Space posted with `CGEvent` (modifier downs, Space down/up, modifier ups — posting works from this terminal) gave `reveal on` → `reveal off` 530 / 203 / 1004 ms apart for 600 / 200 / 1000 ms holds, with no "lost release" line (first-press latency on the 600 ms run); `hotkey unregistered` logged on the graceful quit; no Sitr process left.
- Cross-process: a second instance registers the same combo with status 0 while the first is alive, so `RegisterEventHotKey` does not report conflicts across processes; release on quit is evidenced by the `hotkey unregistered` log line (and the OS drops per-process hot keys at exit).
- Menu bar icon: screenshots of the menu bar strip show the template `eye.slash`; the forced-dimmed build renders it visibly lighter; the `.opacity` variant rendered identical to normal, hence the `NSImage` approach.
- Launch at login (M2-T15) on the ad-hoc `build/Sitr.app`: `--launch-at-login status` → `notFound`; `on` → `enabled`; a fresh process `status` → `enabled` (survives relaunch); `off` → `notRegistered`; final `status` → `notRegistered`. Left OFF.

## Manual pending
- Physical ⌃⌥Space press over a fullscreen app with overlay panels (needs Track A panels + integration).
- After quit, ⌃⌥Space reaching the system (input-source switch) again: only the unregister log line is checked.
- Menu rendering per state and VoiceOver reading (mapping is unit-tested; the menu is a straight switch on it); the `requiresApproval` hint (this machine approves silently).
- M5-T05: not clicked — it would open the user's browser; `NSWorkspace.open` is a Launch Services call, no socket, so the missing network entitlement does not apply.
- Pause across a real sleep/wake (unit test covers the re-sync and the elapsed-deadline resume paths).

## Notes for other owners
- `SitrCore.Observation` (the tracker input) shadows the `Observation` module inside every `@Observable` expansion in a file that does `import SitrCore` (`'Observable' is not a member type of struct 'SitrCore.Observation'`). `AppModel.swift` and `Preferences.swift` use scoped imports (`import struct SitrCore.Policy` …) as a workaround; renaming the type (e.g. `Detection`) in SitrCore would remove the trap for the pipeline/integration code.
- swift-frontend 6.3.3 crashes (SmallVector overflow in IRGen) when a `@MainActor` method reference such as `model.setStrict` is passed as `Binding(set:)`; closures `{ model.setStrict($0) }` avoid it.
- No `Package.swift` change needed.
- `// ponytail:` markers: placeholder defaults (Everyone + Strict), key names table (UCKeyTranslate later), single hot-key id.
