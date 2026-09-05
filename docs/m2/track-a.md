# M2 Track A — Capture + Overlay (M2-T03, T04, T05, T10, T11)

Production types for the capture → overlay half of the pipeline. All in the `Sitr` app target
(`defaultIsolation(MainActor.self)`). Pure logic (`PermissionLogic`, `DisplayDiff`, `CoverGeometry`, the coordinate
flips, `Frame` helpers) is `nonisolated` and unit-tested in `Tests/SitrTests/TrackATests.swift`.

## Public API (for the pipeline agent, M2-T12)

### Permission — `Sources/Sitr/Permission/PermissionMonitor.swift`
- `@Observable @MainActor final class PermissionMonitor`
  - `enum State { unknown, granted, denied, revoked }` (`nonisolated`, `Equatable`, `Sendable`); `var state` observable.
  - `init()` — refreshes now, re-checks on `didBecomeActiveNotification`, polls every 5 s while `denied`/`revoked`.
  - `func refresh()` `CGPreflightScreenCaptureAccess`; `func request()` `CGRequestScreenCaptureAccess`;
    `func openSystemSettings()` deep link; `func markRevoked()` for the capture layer.
- `nonisolated enum PermissionLogic`
  - `transition(from:preflight:) -> State`; `transition(from:streamErrorIsRevocation:preflight:) -> State`;
    `isRevocation(_ error: Error) -> Bool` (`SCStreamError` `userDeclined`/`userStopped`/`systemStoppedStream`/`missingEntitlements`/`noCaptureSource`).

### Display topology — `Sources/Sitr/Capture/DisplayManager.swift`
- `@Observable @MainActor final class DisplayManager`
  - `init(permission:)`, `func start()`, `func stop()`, `func refresh()`, `func setRevealed(_ revealed: Bool)`.
  - `private(set) var displays: [ManagedDisplay]`. Gates capture on permission; 300 ms debounce on screen-parameter changes.
- `struct ManagedDisplay: Identifiable { id: CGDirectDisplayID; frame; scale; session: CaptureSession; panel: OverlayPanel; renderer: CoverRenderer }`
- `nonisolated enum DisplayDiff.compute(current:desired:) -> Result{add,remove,keep}`
- `extension NSScreen { var displayID: CGDirectDisplayID? }` (via `NSScreenNumber`).

### Capture — `Sources/Sitr/Capture/CaptureSession.swift` + `Frame.swift`
- `@MainActor final class CaptureSession`
  - `init(displayID:permission:)`; `let frames: AsyncStream<Frame>` (**`.bufferingNewest(1)`, single-consumer** — one loop per display);
    `func start()`, `func stop()`, `func restart()`, `func updateFilter(_:) async throws` (M3).
  - `var fps = 15` and `var captureLongSide = 1280` — settable, applied live via `updateConfiguration`.
  - `private(set) var health: Health { ok, stopped(Error?) }`; `var stats: CaptureStats`; `private(set) var restarts`.
  - `static func ownProcessExcluded(display:content:) -> SCContentFilter`.
- `nonisolated struct Frame: @unchecked Sendable` — `pixelBuffer, displayID, sequence, timestamp, dirtyRects, contentRect, scaleFactor, contentScale, displaySize`;
  helpers `pointsPerPixel`, `pixelsPerPoint`, `pixelsToDisplayPoints(_:)`/`displayPointsToPixels(_:)` (Rect & CGRect), `dirtyRectsInDisplayPoints`.

### Overlay — `Sources/Sitr/Overlay/OverlayPanel.swift`
- `final class OverlayPanel: NSPanel`
  - `init(screenFrame: CGRect)`; `func apply(_ specs: [CoverLayerSpec])` (id-keyed diff, one `CATransaction`, animations off, flushed);
    `func setRevealed(_:)`; `var layerCount`, `private(set) var isRevealed`.
- `nonisolated struct CoverLayerSpec: @unchecked Sendable { id: Int; frame: CGRect (display-local, top-left pt); contents: CVPixelBuffer?; color: CGColor? }`
- `nonisolated func appKitRect(_:displayHeight:) -> CGRect` (top-left ↔ bottom-left flip; unit-tested).

### Cover renderer — `Sources/Sitr/Overlay/CoverRenderer.swift`
- `enum CoverStyle { gaussian, pixelate, solid }` (`CaseIterable`, `Sendable`).
- `nonisolated final class CoverRenderer` (one per display, one Metal `CIContext`)
  - `@MainActor init()`; `@MainActor func refreshSolidColor()`.
  - `func render(id:style:strength:padding:rect:frame:) -> CoverLayerSpec` — never throws; falls back to Solid on any failure.
    `strength` 0…1 (FR3 default 0.7), `padding` 0…0.5 (default 0.15), `rect`/`frame` in display-local points, pixels at capture resolution.
- `nonisolated enum CoverGeometry` — `padded(_:padding:display:)`, `gaussianRadius(strength:face:)`, `pixelBlock(strength:face:)`, `faceEstimate(cover:)`.

### Selftests — `Sources/Sitr/Selftest.swift`
`Sitr --selftest` unchanged. Added `--selftest capture --seconds N`, `--selftest overlay [--skip-fullscreen]`,
`--selftest render [--iterations N]`. Each prints parseable lines, removes its windows, has a hard deadline, exits itself.

## Verified on this machine (Apple M3, macOS 26.6.2, one built-in display 1470×956 pt @2×)

- Unit tests: `swift test` → **21 tests pass**, 0 warnings. `swift build` and `scripts/build-app.sh --debug` clean, 0 warnings.
  Entitlements gate green (sandboxed, no network).
- `--selftest capture --seconds 10`: `count=1`, ~129 complete frames, `idle_skipped=6` (idle dropped in the callback),
  `size=1280x832 content_rect=(0,0,640,416) scale_factor=2.0 points_per_pixel=1.148`.
  **`overlay_excluded=true`** (red marker absent through `excludingApplications`), control filter `marker_visible=true`
  (`last_rgb=(234,51,35)`) — the M1-T02 feedback-loop check, now automated. `health ok`, `restarts=0`.
  fps ≈ 13–15: with our overlay excluded the captured content is near-static (hence some idle frames), so the rate follows
  real on-screen motion; the non-excluded control phase runs at ~14.7 fps off the moving overlay.
- **dirtyRects coordinate space**: SCK reports `dirtyRects` in **pixels** (SDK header + live: `max_dirty_px=(0,205,894,627)`,
  union = full 1280×832 buffer) while `contentRect` is in **points** (640×416). `Frame.dirtyRects` is raw pixels;
  `dirtyRectsInDisplayPoints` maps to display points for Curtain/window use.
- `--selftest overlay`: layer count == cover count across 5 diff phases; reveal hides all / unreveal shows all;
  coordinate flip exact; panel `level=1001` (screenSaver+1), `ignores_mouse`, `can_become_key=false`,
  `excluded_from_windows_menu`, `accessibility_element=false`, all four collection behaviors, not opaque;
  **panel above a fullscreen window the selftest owns** (`cover_over_fullscreen=true`, green visible beside);
  **click-through passed** (synthetic `CGEvent`, control click confirms posting works).
- `--selftest render`: 3 styles × strengths 0/0.5/1 × cover heights 120/240/480 pt on a synthetic 1280-wide frame; padding
  0/0.15/0.5 and the display clamp match expected rects; every blur cover is opaque (α=255); Solid returns
  `windowBackgroundColor` (`(0.118,0.118,0.118,1)` in dark) and no pixels.
  Representative quieter-phase p50: **pixelate 0.9–1.1 ms** (≤ 2 ms at all sizes), **Gaussian 1.1–2.8 ms** (larger covers
  approach/exceed 2 ms, as the spike found — radius × area growth). The gate hard-checks pixelate ≤ 2 ms **only when
  `load1 ≤ 4`**; under contention (other agents training/building, load 45–56 seen) it prints `timing_gated=false` and the
  raw numbers, and correctness still gates. Re-run in a quiet phase for the definitive numbers.

## Pending manual items
- Real TCC deny/revoke/re-grant cycle (`tccutil reset ScreenCapture com.goldentik.Sitr`, **bundle-id-scoped only**): this
  shell-launched process inherits the terminal's grant, so a reset does not affect it. Verify by launching the built app
  fresh from Finder on a test account. `PermissionLogic` transitions are unit-tested; `markRevoked()` is wired to
  revocation-class `SCStreamError`s.
- Multi-display: hot-plug, mirror toggle, resolution change — one-display machine, `DisplayDiff` + the keep/restart path are
  unit-tested with fake IDs; resolution change re-creates the panel frame and restarts the session (verified by code path, not hardware).
- Stream survives sleep/wake (M2-T05 Done-when) — sleep/wake is a project-wide manual item; backoff restart (1,2,4,8,10,10 s) is in place.
- Overlay: Space switch, fullscreen **Safari** video, absent from ⌘Tab — selftest never touches the user's apps; own-fullscreen and click-through are automated.
- Quiet-phase render timing numbers.

## Assumptions / shortcuts (`ponytail:` in code)
- `Frame` / `CoverLayerSpec` are `@unchecked Sendable` over `CVPixelBuffer` (immutable IOSurface-backed frame; SCK recycles only when unreferenced).
- Body-cover face size = `min(cover.width, cover.height) / 3` (shoulders ≈ 3 face widths; `min` avoids over-blurring wide merged boxes). Upgrade: pass the tracked face height when a face is assigned.
- `CoverRenderer` uses plain vars + a bounded per-size `CVPixelBufferPool` cache (16), driven serially by one display's pipeline; no lock.
- Hot-plug/mirror recorded as pending (one display); `updateFilter(_:)` exists but the M3 filter builder drives it.

## Needs from other agents / package owner
- No `Package.swift` or `SitrApp.swift` changes required for these types. `SitrApp.swift` still only wires the placeholder
  `MenuBarExtra`; whoever owns M2-T14 should construct a `PermissionMonitor` + `DisplayManager` and call `start()` to bring
  capture + overlay up (they are otherwise inert). Nothing here starts capture on its own outside the selftests.
