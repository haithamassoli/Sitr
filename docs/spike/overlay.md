# M1-T02 — Overlay panel + feedback-loop check (`sitr-spike overlay`)

Run: `swift run sitr-spike overlay [--long-side PX=1280] [--skip-fullscreen]` (≈ 20 s, exits on its own, removes its windows)

The rig creates:
- the overlay `NSPanel`: borderless, `.nonactivatingPanel`, clear background, `ignoresMouseEvents`, level `.screenSaver + 1`,
  `collectionBehavior` [canJoinAllSpaces, fullScreenAuxiliary, stationary, ignoresCycle], `hidesOnDeactivate` false, whole
  main display, one solid red 400×300 pt `CALayer` in the centre;
- a blue "target" panel under the rectangle (level `.screenSaver`, above the user's windows, below the overlay) whose view
  counts `mouseDown`;
- for the fullscreen check, a normal titled green `NSWindow` that the rig toggles into fullscreen and back.

It then streams the display through four filters and samples the captured pixels at the rectangle centre (5×5 mean, a number,
never stored), posts a synthetic click, and prints one line per check. Code: `Sources/SitrSpike/Overlay.swift`.

## Result (2026-09-05, Apple M3, macOS 26.6.2)

```
overlay_own_process listed_in_SCShareableContent=true name=sitr-spike bundle= panel_scwindows=1 target_scwindows=1
overlay_red filter=excludingApplications                 present=false expected=false ok=true frames=14 red_frames=0  blue_frames=0  last_rgb=(255,255,255)
overlay_red filter=excludingApplications+exceptingTarget present=false expected=false ok=true frames=10 red_frames=0  blue_frames=10 last_rgb=(0,0,244)
overlay_red filter=excludingWindows(panel)               present=false expected=false ok=true frames=14 red_frames=0  blue_frames=14 last_rgb=(0,0,244)
overlay_red filter=none                                  present=true  expected=true  ok=true frames=10 red_frames=10 blue_frames=0  last_rgb=(234,51,35)
overlay_exclusion_api worked=excludingApplications,excludingApplications+exceptingTarget,excludingWindows(panel)
overlay_fullscreen entered=true red_over_fullscreen=true fullscreen_window_visible_beside=true centre_rgb=(234,51,35) beside_rgb=(104,206,103) frames=13
overlay_clickthrough passed=true control_hits=1 hits_through_panel=1
overlay_space_switch manual pending
overlay_safari_fullscreen_video manual pending
```

### Which exclusion API worked
- **Primary: `SCContentFilter(display:excludingApplications:exceptingWindows:)`** with our own `SCRunningApplication`
  (`processID == getpid()`). The bundle-less CLI process *is* listed by `SCShareableContent` (name `sitr-spike`, empty bundle
  id), so no fallback was needed. `exceptingWindows` also works: excluding our app but excepting the target window left the
  blue target in the frames.
- Fallback `SCContentFilter(display:excludingWindows:)` with our `SCWindow` (`windowID == panel.windowNumber`) works too.
- Without any exclusion red is present in every frame (234,51,35 — sRGB red after the capture colour conversion), so the
  "red absent" check is meaningful.

### Fullscreen
The panel stays above a fullscreen window the rig itself created (`toggleFullScreen`): red at the centre, the green fullscreen
window beside it, in the same frames. An accessory-policy app can enter fullscreen after `NSApplication.activate()`.

### Click-through
A `CGEvent` left click posted at the rectangle centre reached the target view's `mouseDown` both with the panel hidden
(control, proves posting works from this process) and with the panel shown (`ignoresMouseEvents` works).

## Done when
| Check | Result |
|---|---|
| red absent from captured frames with the exclusion | yes (all three exclusion variants) |
| clicks pass through | yes (synthetic CGEvent) |
| panel above fullscreen | yes, for the rig's own fullscreen window |
| panel above fullscreen **Safari video** | manual pending (rig never touches the user's apps) |
| survives a Space switch | manual pending (rig never switches the user's Spaces) |

## Notes for M2-T05 / M2-T10
- Exclude by application, not by window: new panels (per display, recreated on topology changes) are covered automatically,
  and `SCShareableContent` must not be re-fetched for every new window.
- The stream must be (re)started or `updateContentFilter`ed after the panels exist only when excluding by window; by
  application it is independent of panel lifetime.
- Two-display check: pending (one-display machine).
