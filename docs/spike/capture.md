# M1-T01 — Capture loop (`sitr-spike capture`)

Run: `swift run sitr-spike capture [--seconds N=10] [--motion] [--long-side PX=1280 (0 = native)]`

One `SCStream` on the main display: BGRA, `minimumFrameInterval` 1/15 s, `queueDepth` 3, `showsCursor` false, output scaled
to a 1280 px long side (PRD FR1). Frames are counted in the `SCStreamOutput` callback; `.idle` frames are counted separately and
never processed. `--motion` opens a small always-on-top panel with a Core Animation dot bouncing at display refresh so the screen
is never static; without it the rig measures whatever the screen is doing (a static screen if nothing else moves).

Rig code: `Sources/SitrSpike/Capture.swift`, shared stream wrapper in `Sources/SitrSpike/RigSupport.swift` (`RigStream`).

## Numbers

Re-measured 2026-09-06 (no other agent running, load1 13–17 from the user's own apps — the cadence is set by
`minimumFrameInterval`, not by CPU load): `--motion` 10 s → `capture_fps mean=14.81 complete=153 idle=0 seconds=10.3
long_side=1280 size=1280x832`, i.e. the 15 fps cadence holds. **The "0 fps on a static screen" number could not be
reproduced on this machine on that date**: with the user's own (untouched) desktop showing an animating browser window,
30 s without `--motion` measured `capture_fps mean=7.61 complete=238 idle=226`, 3.6–9 complete fps. Idle frames still make
up the rest, and a genuinely unchanged screen still yields 0 complete frames (below); see docs/spike/system.md, where this
decides how the PRD's "static CPU" row can be read.

Preliminary / noisy (2026-09-05, Apple M3, macOS 26.6.2, other agents building in parallel):

Static screen, 6 s:

```
t=1s complete=15 idle=0  dirtyRects=77   (initial full frames)
t=2s complete=0  idle=16 dirtyRects=0
t=3s complete=0  idle=16 dirtyRects=0
t=4s complete=0  idle=15 dirtyRects=0
t=5s complete=0  idle=16 dirtyRects=0
t=6s complete=0  idle=15 dirtyRects=0
capture_fps mean=2.37 complete=15 idle=78 seconds=6.3 motion=false   (0 fps after the first second)
```

`--motion`, 6 s:

```
t=1..6s complete=15–16 idle=0 dirtyRects=15–17 (93 in the first second)
capture_fps mean=14.93 complete=93 idle=0 seconds=6.2 motion=true long_side=1280 size=1280x832
```

Every frame: `size=1280x832 contentRect=(0,0,640,416) scaleFactor=2.0 contentScale=0.4351`.

## Done when

| Check | Result |
|---|---|
| frames flow | yes |
| `.idle` frames skipped | yes — SCK emits idle frames at the configured 15 Hz when nothing changes; they are counted and dropped |
| cadence ≈ 15 fps under motion | 14.93 fps (14.81 fps on the 2026-09-06 re-run) |
| cadence ≈ 0 on a static screen | 0 complete frames/s after the first second (2026-09-05, screen genuinely unchanged); on 2026-09-06 the desktop itself animated and the same run measured 7.6 complete fps — the check is about SCK, not about the desktop |

## Notes for M2-T05

- The panel is 2560×1664 physical but the display runs at **1470×956 points @2x** (2940×1912 backing px). `contentScale`
  is output px / backing px (1280 / 2940 = 0.4351). The rigs map screen points to capture pixels with
  actual buffer size ÷ `CGDisplayBounds` (points) and never rely on `contentScale`.
- `contentRect` comes back as (0,0,640,416) for a 1280×832 buffer, i.e. in "output points" (buffer px / `scaleFactor`).
- `dirtyRects` is one rect per frame under simple motion, 77–93 rects in the first second (full invalidation on start).
- Idle frames make a free heartbeat: the latency rig waits for one to know the screen has settled.
- `--long-side 0` captures native (2940×1912) if M1-T03 wants to compare.
- Two-display check: pending (one-display machine).
