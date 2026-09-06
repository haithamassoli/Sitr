# Robustness — M4-T10

Sleep/wake, lock/unlock, fast user switching, display hot-plug, Stage Manager, mirrored displays, and stream restart with
exponential backoff. One invariant runs through all of it:

> **Exactly one `Pipeline`, one `OverlayPanel` and one `SCStream` per managed display, through every transition.**

Panels are never closed for a transition — closing and reopening them is how duplicates appear — and streams are stopped
on purpose before macOS tears them down, so a sleep costs no error and no backoff retry.

## Files
- `Sources/SitrCore/Resilience.swift` — the pure half, injected clock, no AppKit:
  - `Backoff` / `Backoff.captureStream` — 1, 2, 4, 8, 10, 10 … s, capped at 10, fresh sequence after a stream that ran 30 s.
  - `RestartPolicy` — one pending retry per session (`.retry` / `.alreadyScheduled` / `.stop`), so a burst of failures
    schedules one timer, and a display that went away schedules none.
  - `SuspensionReasons` / `SystemActivity` / `SystemActivityMachine` — sleep, lock, screens-off and session-inactive as
    four independent reasons; `active → suspended → resuming → active`, where `resuming` ends only at the first frame (or,
    for health purposes, after `settleFor` = 5 s).
  - `DisplayLink` / `DisplayTopology.managed` — one id per display, duplicates collapsed, a display mirroring a managed
    one dropped.
- `Sources/Sitr/Capture/SystemEventMonitor.swift` — the eight notifications (`NSWorkspace` will-sleep / did-wake,
  session-resign / session-become-active, screens-did-sleep / did-wake, plus the `com.apple.screenIsLocked` /
  `Unlocked` distributed pair) → `SystemActivityMachine`. `simulate(_:)` drives the same path without the notification.
- `Sources/Sitr/Capture/CaptureSession.swift` — the backoff is `RestartPolicy` now; `displayIsPresent` and `captureAllowed`
  are the two "is a retry worth it" seams; `liveStreams` counts connected sessions; `simulated` is the test seam. Each
  connection carries a `generation`, and `stream(_:didStopWithError:)` is ignored unless it is the current one:
  `SCStream.stopCapture` is asynchronous, so without it the stop of a stream we tore down for a sleep or a restart arrives
  late and takes its healthy successor down as well (found by the live selftest, not by reasoning).
- `Sources/Sitr/Capture/DisplayManager.swift` — `ScreenSnapshot` list (real or simulated), mirror dedupe,
  `CGDisplayRegisterReconfigurationCallback` as a second trigger next to `didChangeScreenParametersNotification`,
  `suspendCapture()` / `resumeCapture()`, `knownIDs`.
- `Sources/Sitr/Overlay/OverlayPanel.swift` — `OverlayPanel.openCount`, the live-panel registry.
- `Sources/Sitr/SitrApp.swift` (`Runtime`) — `suspend()` / `resume()`, health held across a transition, fail-closed covers
  up while capture is not live, `reconcileNow()`, `pendingStallChecks`. This extends the M3-T06 stall path rather than
  adding a second recovery mechanism: a stall check is skipped while capture is parked, and `resume()` re-arms it.
- `Tests/SitrCoreTests/ResilienceTests.swift`, `Tests/SitrTests/RobustnessTests.swift` — 35 tests.
- `Sitr --selftest robustness [--cycles 20]` — the live half.

## What each transition does

| Transition | Events | What happens |
| --- | --- | --- |
| Sleep | `willSleep` → `didWake` | streams stopped; panels, pipelines and covers untouched; on wake: permission re-read, topology re-read, streams restarted, pipelines reconciled, filters reinstalled |
| Screen lock | `com.apple.screenIsLocked` / `Unlocked` | same |
| Fast user switching | `sessionDidResignActive` / `sessionDidBecomeActive` | same |
| Displays off | `screensDidSleep` / `screensDidWake` | same |
| Hot-plug | screen-parameters notification or `CGDisplay` reconfiguration, debounced 300 ms | add/remove one panel + session + pipeline per display; the removed display's session stops retrying |
| Resolution / scale change | same | panel moved and stream restarted; the **same** panel and session objects |
| Mirroring on | same | the mirror slave is dropped: one panel, one stream for the set |
| Stage Manager, Space switch | no topology change | repeated no-op reconciliation; the panel stays (`canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`, level `screenSaver + 1`) |

Four reasons can overlap. Closing a MacBook lid produces lock → screens-off → sleep, and opening it clears them in a
different order; capture comes back only when the last one clears, so an unlock that arrives before the wake does not
restart capture into a sleeping machine.

**Fail-closed across the gap (PRD FR10).** From the moment a suspend starts until the first frame after the wake, every
Curtain window gets its Solid cover, exactly as for a lost grant or a stalled stream. Blur apps fail open, as they always
do. Health is *held* for the same window (5 s after the wake, or until the first frame): a stream we stopped ourselves is
not a lost grant, so the menu bar does not flash "Needs Screen Recording permission" on every wake.

## Proven synthetically (green in `swift test`)

`swift test --filter 'BackoffTests|RestartPolicyTests|SystemActivityMachineTests|DisplayTopologyTests|RobustnessTests'`

| Claim | Where |
| --- | --- |
| Backoff is 1, 2, 4, 8, 10, 10 … and never exceeds 10 s, however long it has been failing | `BackoffTests` |
| A burst of failures schedules one retry, not one per failure | `RestartPolicyTests.severalFailuresAtOnceScheduleOneRetry` |
| A display that went away (or a lost grant, or a stop) schedules nothing | `RestartPolicyTests.aDisplayThatWentAwayStopsTheRetries`, `RobustnessTests.aStoppedSessionRetriesNothing` |
| A stream that ran 30 s earns a fresh backoff | `RestartPolicyTests.aStreamThatRanForHalfAMinuteEarnsAFreshBackoff` |
| 20 sleep/wake cycles end `.active` with no reason held | `SystemActivityMachineTests.twentySleepWakeCyclesEndActiveWithNothingHeldOpen` |
| Overlapping / duplicate / unpaired events cannot strand the state machine | `SystemActivityMachineTests` (4 tests) |
| **20 sleep/wake cycles leave one pipeline, one panel and one stream per display**, on the same session and panel objects, with no stall task left behind | `RobustnessTests.twentySleepWakeCyclesLeaveOneStreamAndOnePanelPerDisplay` |
| Lock/unlock and fast user switching hold the same invariant (7 rounds × 3 pairs) | `RobustnessTests.lockUnlockAndFastUserSwitchingHoldTheSameInvariant` |
| An unlock before the wake does not restart capture | `RobustnessTests.anUnlockThatArrivesBeforeTheWakeDoesNotRestartCapture` |
| Hot-plug adds and removes exactly one of everything; repeated reconciliation adds nothing | `RobustnessTests.hotPlugAddsAndRemovesExactlyOneOfEverything` |
| A display unplugged (or three plugged in) while asleep is reconciled on the wake | `RobustnessTests.aDisplayUnpluggedWhileAsleepIsGoneByTheFirstFrameAfterTheWake` |
| A mirror set — reported as a mirror master + slave, or as the same id twice — gets one panel and one stream | `RobustnessTests.aMirrorSetGetsOnePanelAndOneStream`, `DisplayTopologyTests` |
| A resolution change moves the panel and restarts the stream without a second of either | `RobustnessTests.aResolutionChangeRestartsTheStreamWithoutASecondPanel` |
| Stage Manager / Space-switch panel properties, and 20 no-op reconciliations | `RobustnessTests.stageManagerAndSpaceSwitchesNeitherHideNorDuplicateAPanel` |
| A wake does not report a lost grant, and covers stay closed until a frame | `RobustnessTests.aWakeDoesNotReportALostGrantAndKeepsFailClosedCoversUp` |
| Nothing leaks: panels and streams are back to the baseline after `Runtime.stop()` | every `RobustnessTests` case |

The topology is `DisplayManager.simulatedScreens`, so these run with no ScreenCaptureKit traffic, no real displays and
nothing on the user's screen.

## Proven live (`Sitr --selftest robustness`)

```
swift build && .build/debug/Sitr --selftest robustness --cycles 20
```

Real capture, real overlay panels, the real `Runtime` — with the transitions injected through
`SystemEventMonitor.simulate(_:)` instead of a real power event: 20 sleep/wake cycles, then one lock/unlock, one fast
user switch, one screens-off/on, then the live backoff. Per cycle it checks that the suspend parks every stream without
touching a panel, a pipeline or a cover already on screen, and that the resume brings back exactly one stream, one panel
and one pipeline per display **and** a frame from the new stream (not a straggler from the old one).

```
robustness_topology displays=<id>=<w>x<h>+<x>+<y>,builtin=…,mirrors=…,asleep=…,active=… …
robustness_baseline displays=[…] pipelines=N panels=N streams=N covered=true …
robustness_cycle kind=sleep n=1 parked=true held_panels=true held_pipelines=true covers_untouched=true
                 layers=… frames_back=true resume_ms=… pipelines=N panels=N streams=N backoff_restarts=0 health=ok
robustness_cycle kind=lock|user_switch|screens_off …
robustness_backoff failures=3 retries_scheduled=1 next_delay_s=1.000 cap_s=10 reconnected=true
                 recovery_ms=… frames_back=true health_back=true restarts_total=1 …
robustness_summary cycles=20 … stall_checks=0 state=active ok=true
robustness_teardown panels=0 streams=0
```

Pass = `ok=true` on the summary and `panels=0 streams=0` on the teardown.

**Run of 2026-09-06** (this machine, one built-in 1470×956 display, `load1` 4–10 so the millisecond figures are noisy):
`ok=true`. All 23 cycles: `parked=true held_panels=true held_pipelines=true covers_untouched=true frames_back=true
pipelines=1 panels=1 streams=1 backoff_restarts=0 health=ok`; resume 120–730 ms. Backoff: three failures inside one turn →
`retries_scheduled=1 restarts_total=1 next_delay_s=1.000`, stream and health back on their own in 1.4 s. Teardown
`panels=0 streams=0`.

What this does **not** prove is that macOS behaves the way the notifications say it does — the streams are stopped and
restarted by us, not by a real sleep. That is the manual procedure below.

## Manual procedure — the rows that are still pending

All of these need a person at the machine. Ten minutes for the whole list.

### Setup (once)

```sh
scripts/build-app.sh                                  # -> build/Sitr.app
build/Sitr.app/Contents/MacOS/Sitr &                  # from the shell, never `open` (docs/dev.md)
```

In a second terminal, stream the invariant:

```sh
log stream --style compact --predicate 'subsystem == "com.goldentik.Sitr" AND (category == "runtime" OR category == "displays" OR category == "capture" OR category == "system")'
```

Every transition prints, in order:

```
system willSleep reasons=1 state=suspended changed=true
displays suspended count=<D> streams=0
suspended displays=<D> pipelines=<D> panels=<D> streams=0
system didWake reasons=0 state=resuming changed=true
displays resumed count=<D>
resuming displays=<D> pipelines=<D> panels=<D> streams=<D>
system resumed: frames are flowing again
```

**Pass for one cycle:** `pipelines`, `panels` and the resumed `streams` all equal `<D>`, the display count; `streams=0`
while suspended; and `system resumed: frames are flowing again` follows within a second or two of the wake.

### R1 — 20 sleep/wake cycles (the "done when")

Repeat 20 times: `pmset sleepnow`, wait for the fans/screen to settle, press a key, log in.
Then, in one command:

```sh
log show --last 30m --style compact --predicate 'subsystem == "com.goldentik.Sitr"' \
  | grep -E '^\S+ +\S+ +.*(suspended|resuming) displays=' \
  | awk '{for (i=1;i<=NF;i++) if ($i ~ /^(displays|pipelines|panels|streams)=/) printf "%s ", $i; print ""}' \
  | sort | uniq -c
```

**Pass:** exactly two distinct shapes, 20 of each —
`displays=<D> pipelines=<D> panels=<D> streams=0` (suspended) and
`displays=<D> pipelines=<D> panels=<D> streams=<D>` (resuming). Any third shape, or a `panels=` that grows over the run,
is a duplicate panel and a bug.

Also check nothing retried its way through the sleeps:

```sh
log show --last 30m --predicate 'subsystem == "com.goldentik.Sitr" AND category == "capture"' | grep -c 'restart in'
```

**Pass:** 0. A sleep must not cost a backoff retry, because the stream was stopped before macOS could break it.

Finally, with the app still running, put a Curtain app (Safari, Telegram) on screen and confirm by eye that the cover is
there the instant the screen comes back — not a second later.

### R2 — lock / unlock

`Ctrl-Cmd-Q` (or the Apple menu → Lock Screen), wait five seconds, unlock. Five times.
**Pass:** the same two log shapes as R1, five of each, `reasons=8` (`screenLocked`) on the way down. If `system
screenLocked` never appears, the undocumented distributed notification is gone and the fallback is `screensDidSleep` a few
seconds later — note it and file it; behaviour degrades to a late suspend, never a missed one.

### R3 — fast user switching

Needs a second account. System Settings → Users & Groups → Fast user switching menu on. Switch to the other user, wait
ten seconds, switch back. Five times.
**Pass:** `system sessionResignedActive` → suspended, `system sessionBecameActive` → resuming, same counts. Nothing in
the log while the other user is in front.

### R4 — two-display hot-plug

Needs a second display (this machine has one built-in panel, so R4 and R5 have never run here).
1. Plug it in: one new `displays reconciled count=2 added=[…]` line, `panels=2 streams=2`.
2. Sleep/wake with two displays: the R1 shapes with `<D>` = 2.
3. Unplug while asleep, wake: `displays reconciled count=1 removed=[…]`, `panels=1 streams=1`, and **no** `restart in`
   lines for the display that went.
4. Unplug while awake: same, within ~300 ms of the notification.

### R5 — mirrored displays

With the second display attached, System Settings → Displays → Mirror.
**Pass:** `displays reconciled count=1`, `panels=1 streams=1` — the mirror slave is dropped. Turn mirroring off:
`count=2`, `panels=2 streams=2`. Covers must be visible on the mirrored image (they are, because the master is captured
and its panel is the one drawing).

### R6 — Stage Manager

Turn Stage Manager on. Open three windows of a Curtain app and shuffle between them for a minute.
**Pass:** no `displays reconciled` lines at all (Stage Manager changes windows, not displays), covers follow the windows,
and the panel stays above the Stage Manager strip. Then switch Spaces a few times: covers stay (the panel is
`canJoinAllSpaces`).

### Status of the manual rows

| Row | Status |
| --- | --- |
| R1 20 real sleep/wake cycles | **manual, pending** |
| R2 lock / unlock | **manual, pending** |
| R3 fast user switching | **manual, pending** (needs a second account) |
| R4 two-display hot-plug | **manual, pending** (needs a second display) |
| R5 mirrored displays | **manual, pending** (needs a second display) |
| R6 Stage Manager | **manual, pending** |

Until R1 has run, M4-T10's "done when" is **not** met: the synthetic 20 cycles prove the reconciliation, not that macOS's
own sleep leaves the process in the state the notifications claim.
