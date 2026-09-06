# M3-T02 — `WindowTracker` (window geometry provider)

Which app owns which on-screen region, for per-app rules (FR6) and fail-closed Curtain covers (FR10). One file,
`Sources/Sitr/Windows/WindowTracker.swift`, in the `Sitr` app target; tests in `Tests/SitrTests/WindowTrackerTests.swift`.

## API

- `nonisolated struct WindowRect: Sendable, Hashable { windowID: CGWindowID; pid: pid_t; bundleID: String?; displayID: CGDirectDisplayID; rect: CGRect; zOrder: Int }`
  - `rect` is **display-local, top-left origin, points** — the same space as `CoverLayerSpec.frame` and the output of
    `Frame.pixelsToDisplayPoints`, so a detection's display-local point goes straight into `topmostWindow(at:on:)`.
  - `zOrder`: front-to-back index among the kept windows, 0 = frontmost. A window straddling two displays yields one entry per
    display (each clipped to its display), both with the same `zOrder`.
  - `bundleID` is `nil` for owners that are not applications (`NSRunningApplication` unknown).
- `@Observable @MainActor final class WindowTracker`
  - `private(set) var windows: [WindowRect]` — front to back; reassigned only when the list actually changed (observers stay quiet on a static screen).
  - `func start()` — refreshes now, then every 100 ms (10 Hz) and immediately on `NSWorkspace` `didActivateApplication` /
    `didLaunchApplication` / `didTerminateApplication`. Idempotent.
  - `func stop()` — cancels the poll, removes the observers, clears `windows`.
  - `func refresh()` — one WindowServer round-trip → `windows` (what the poll calls; call it yourself after a topology change if you need the list before the next tick).
  - `func topmostWindow(at point: CGPoint, on displayID: CGDirectDisplayID) -> WindowRect?` — frontmost window under a display-local point; `nil` over the desktop.
  - `func windows(for bundleID: String) -> [WindowRect]` — every on-screen window of one app, front to back.
- `nonisolated enum WindowGeometry` (pure, unit-tested)
  - `typealias Display = (id: CGDirectDisplayID, bounds: CGRect)` — `bounds` from `CGDisplayBounds(id)`.
  - `static func split(globalRect: CGRect, displays: [Display]) -> [(id: CGDirectDisplayID, localRect: CGRect)]` — the part of a
    global-space rect on each display, in that display's local space; empty when off every display.
  - `static func parse(_ list: CFArray?, displays: [Display]) -> [WindowRect]` — `CGWindowListCopyWindowInfo` output → `WindowRect`s
    (`bundleID == nil`): keeps `kCGWindowLayer == 0`, skips alpha 0 and windows smaller than 8×8 pt, splits across displays, assigns `zOrder`.

## Coordinates

`CGWindowListCopyWindowInfo` bounds (`kCGWindowBounds`) and `CGDisplayBounds` share the global Core Graphics space: origin at the
top-left of the main display, y down. Display-local = global − display origin, clipped to the display. `NSScreen.frame` (AppKit,
y up) is never used for this; `NSScreen.screens` only supplies the display IDs so they match `DisplayManager`'s keys.

Unit-tested layouts (`WindowGeometrySplitTests`): secondary above the main (negative y), to the left (negative x), to the right;
a window straddling two displays (one clipped entry per display, `displays` order); fully off-screen, edge-touching with zero
overlap, and hanging off the bottom of the main display (clipped). Live two-display verification is pending (one-display machine).

## Filtering and privacy

- Query: `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` — front to back.
- Kept: layer 0 only (menu bar 24, Dock 20, our own overlay panels at 1001 fall out), alpha > 0, at least 8×8 pt, on at least one display.
- `kCGWindowName` is never read, and nothing about windows is logged; the tests print counts and bundle IDs only.
- The window list does not need Screen Recording permission (only titles are gated), so the tracker keeps working in the
  Needs-permission state — which is exactly when FR10's fail-closed Curtain covers need `windows(for:)`.
- PID → bundle ID: `NSRunningApplication(processIdentifier:)?.bundleIdentifier`, cached per PID (`nil` results cached too). The cache is
  rebuilt from the PIDs seen on each refresh, so a terminated app's entry is dropped at the refresh its terminate notification triggers.

## Measured poll cost (Apple M3, macOS 26.6.2, ~23 on-screen window entries, 1 at layer 0)

Own-thread CPU is the gated number; wall time includes the IPC wait, which is WindowServer's time, not ours. At 10 Hz,
ms per call equals % of one core.

| Build | Measurement | CPU ms/call | Wall ms/call | CPU at 10 Hz | load1 |
|---|---|---|---|---|---|
| release `-O`, real `refresh()`, 7×100 calls, 3 runs | min / median | 0.145–0.196 / 0.154–0.209 | 0.45–0.60 / 0.48–0.68 | **0.15–0.21 %** | 31.7 (noisy) |
| debug, `pollCost` test, 100 calls, 5 runs | per run | 0.178, 0.225, 0.343, 0.388, 0.532 | 0.52–2.5 | 0.18–0.53 % | 9.6–31.7 (noisy) |
| debug, `pollCost` test, query only (no parsing) | per run | 0.118–0.300 | 0.35–4.0 | 0.12–0.30 % | 9.6–31.7 (noisy) |

Gate (< 0.3 % of one core): met by the release build in every sample, with the machine under heavy load from other agents; the
debug outliers were load spikes. **10 Hz kept.** Parsing walks the CF objects directly — bridging the array with
`as? [[String: Any]]` measured 0.25–0.33 ms CPU per call against 0.10–0.12 ms for the CF walk, i.e. it alone would have blown the
gate. Cost scales with the number of on-screen entries WindowServer returns (all layers), so a desktop with ~60 windows will run
2–3× this. `pollCost` hard-checks the 0.3 % gate only when `load1 ≤ 4` (quiet phase, as the render selftest does) and prints
`timing_gated=false` otherwise; no quiet phase was available while this was measured. If a quiet-phase release measurement
ever lands over 0.3 %, `WindowTracker.pollInterval` is the one constant to change (200 ms = 5 Hz halves everything).

## Tests (`swift test`, 9 new, all green; 81 total in the package)

`WindowGeometrySplitTests` (4): `secondaryAbove`, `secondaryLeft`, `secondaryRight`, `offScreenEdgeTouchingAndHangingOff`.
`WindowGeometryParseTests` (2): layer / alpha / size filters, per-display split and `zOrder` on synthetic entries; nil list, empty
list, non-dictionary and wrongly typed entries. `WindowTrackerLiveTests` (3, serialized, MainActor): the real query returns ≥ 1
window with valid display IDs, positive clipped rects and sorted `zOrder`, resolves ≥ 1 bundle ID, `topmostWindow` under the
frontmost window's centre is that window, `windows(for:)` filters; `start()` refreshes synchronously and polls, `stop()` clears;
`pollCost` prints the line above.

## How to wire (integration / pipeline owner; no `Package.swift` or `SitrApp.swift` change needed)

1. Own one tracker for the process next to `DisplayManager`: `let windowTracker = WindowTracker()`; `windowTracker.start()` when
   protection is enabled (it does not need the Screen Recording grant), `stop()` on Disable / quit.
2. Per-detection attribution (Blur rules, FR6): with a cover in display-local points from `Frame.pixelsToDisplayPoints`,
   `windowTracker.topmostWindow(at: CGPoint(x: cover.midX, y: cover.midY), on: frame.displayID)?.bundleID` → resolve the rule
   (M3-T01). `nil` window or `nil` bundle ID → Default Rule.
3. Curtain / fail-closed (M3-T05, M3-T06): `windowTracker.windows(for: bundleID).map(\.rect)` per display are the solid-cover
   frames — pass them as `CoverLayerSpec(id:frame:contents:nil,color:)` to that display's `OverlayPanel.apply`. Filter by
   `displayID` when building per-display specs.
4. Reacting to changes: `windows` is `@Observable`; `withObservationTracking { _ = windowTracker.windows } onChange: { … }` fires
   only when the list actually changed. `WindowRect` is `Sendable`, so a snapshot can be handed to the pipeline actor per frame.

## Assumptions / shortcuts (`// ponytail:` in code)

- 10 Hz polling instead of window-server notifications (private SkyLight API, or one AX observer per app); the `NSWorkspace`
  notifications make app switches immediate, so only window moves / resizes wait for the next tick (≤ 100 ms).
- PID → bundle ID cache keyed by PID only: a PID reused by a new process within one poll interval would keep the old bundle ID.
  Upgrade = key by `(pid, launchDate)`.
- Displays come from `NSScreen.screens` (matches `DisplayManager`); a window on a display AppKit does not list (mirror set member)
  is dropped. Live two-display checks pending on this one-display machine.
- `zOrder` is global across displays, not per display; entries of a straddling window share it.
