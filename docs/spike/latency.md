# M1-T04 — Latency rig (`sitr-spike latency`)

Run: `swift run sitr-spike latency [--trials N=50] [--long-side PX=1280] [--fps N=15] [--only capture|blur|curtain]`
(≈ 90 s for 3 × 50 trials; exits on its own, removes its window)

## How it measures

One stimulus `NSPanel` (400×600 pt, level `.screenSaver`, centred) with a **frame counter encoded in pixels**: a row of ten 40 pt
blocks, block 0 always white, block 9 always black, blocks 1–8 = the trial number MSB first. Below it a 400×560 pt region
shows the CC0 person photo `Sources/SitrSpike/Fixtures/person.jpg` (see `Fixtures/ATTRIBUTION.md`). One `SCStream` on the
main display (BGRA, 1280 px long side, queueDepth 3, no cursor) feeds an `AsyncStream` with drop-oldest backpressure. Every
`.complete` frame is decoded (5×5 mean per block, threshold 128, marker blocks validated), so each frame says which paint it
shows and trials cannot be confused.

Per trial: wait for an `.idle` frame (screen settled, 600 ms cap), sleep 100–170 ms at random (de-phases the paint from the
capture cadence), then paint counter *i* in one flushed `CATransaction` and record `tPaint = CACurrentMediaTime()`.

| Path | Stimulus | Stops the clock at |
|---|---|---|
| capture | counter only | `CACurrentMediaTime()` at entry of the `SCStreamOutput` callback of the first frame decoding *i* |
| blur | counter + photo | first frame decoding *i* → `DetectHumanRectanglesRequest` on the frame (new Vision API, warmed once) → cover layer `frame` set to the detected body box → `CATransaction.commit()` + `flush()` |
| curtain | counter + photo | first frame decoding *i* with `dirtyRects` non-empty → cover layer over the changed region → commit + flush (no detection) |

Cover commits go into the stimulus window's own layer tree (no overlay panel needed; the rig excludes nothing from capture).
A trial is "missed" when no frame decodes *i* within 2 s (none missed so far). The 8-bit counter caps `--trials` at 255.

## Numbers — quiet phase (2026-09-06, Apple M3, macOS 26.6.2, nothing else of ours running, load1 2.1–2.9), n=50 each

| Capture rate | capture p50 / p95 | Blur path p50 / p95 | Curtain path p50 / p95 |
|---|---|---|---|
| 15 fps (PRD default) | 37.1 / 80.1 ms | 60.2 / 84.2 ms | 52.0 / 75.6 ms |
| 30 fps | 28.5 / 45.0 ms | 42.0 / 64.2 ms | 31.3 / 55.4 ms |
| 60 fps | 20.5 / 33.9 ms | 37.7 / 58.2 ms | 26.7 / 54.3 ms |

Raw lines (`.build/debug/sitr-spike latency --fps N`, one process per rate):

```
capture_latency_ms p50=37.1 p95=80.1 n=50 missed=0          # fps=15, load1 2.55
blur_latency_ms    p50=60.2 p95=84.2 n=50 missed=0 detect_calls=50
curtain_latency_ms p50=52.0 p95=75.6 n=50 missed=0
capture_latency_ms p50=28.5 p95=45.0 n=50 missed=0          # fps=30, load1 2.80
blur_latency_ms    p50=42.0 p95=64.2 n=50 missed=0 detect_calls=50
curtain_latency_ms p50=31.3 p95=55.4 n=50 missed=0
capture_latency_ms p50=20.5 p95=33.9 n=50 missed=0          # fps=60, load1 2.14
blur_latency_ms    p50=37.7 p95=58.2 n=50 missed=0 detect_calls=50
curtain_latency_ms p50=26.7 p95=54.3 n=50 missed=0
latency_config long_side=1280 fps=15|30|60 trials=50 display_pt=1470x956
```

`detect_calls=50` = the person was detected in the very first frame that showed the photo, every trial.

Preliminary (2026-09-05, other agents building in parallel; superseded by the table above): 15 fps 44.9 / 71.5, 47.6 / 85.4,
54.3 / 81.5 ms; 30 fps 30.7 / 47.2, 45.2 / 62.6, 31.5 / 52.5 ms; 60 fps capture only 19.4 / 32.7 ms.

## Reading the numbers

- **Capture latency is dominated by the capture interval**: roughly half the frame interval plus ~12 ms of compositor + SCK
  work (p50 37 → 29 → 21 ms at 15 → 30 → 60 fps). p95 follows the interval too (80 → 45 → 34 ms).
- Detection (`DetectHumanRectanglesRequest`, full frame 1280×832, first call warmed) adds ~10–20 ms p50 to the capture
  latency; the Curtain path (no detection) is 10–15 ms cheaper than the Blur path at every rate.
- **PRD check**: Blur exposure ≤ 150 ms p95 → 84 ms p95 at 15 fps, in (this rig has no tracker/classifier stage and stops at
  the commit, so add the on-screen presentation of the commit, ~1 display frame; the production pipeline's own exposure
  number is in `docs/spike-report.md`). **Curtain exposure ≤ 50 ms p95 is not reachable with 15 fps capture** (76 ms p95,
  capture alone is 80 ms p95); 30 fps gives 55 ms and **60 fps buys nothing more at p95** (54 ms: the tail is SCK delivery
  jitter, not the interval, while capture cost doubles). Decision recorded in `docs/spike-report.md`: Curtain-app displays
  capture at 30 fps and the PRD target moves to ≤ 60 ms p95 (CPU cost of 30 fps: `docs/spike/system.md`).

## Done when
p50/p95 for capture latency, Blur path and Curtain path: recorded above (quiet phase, official).

## Notes
- Times are `CACurrentMediaTime()` deltas; paint time is taken after `CATransaction.commit()` + `flush()`, i.e. when the
  change has been handed to the render server, not when it is on glass (the real on-screen exposure is up to one display
  frame more on both ends).
- Vision normalized rectangles (lower-left origin) map straight onto AppKit screen points for a full-display frame.
- Two-display check: pending (one-display machine).
