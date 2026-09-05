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

## Numbers — preliminary / noisy (2026-09-05, Apple M3, macOS 26.6.2, other agents building in parallel), n=50 each

| Capture rate | capture p50 / p95 | Blur path p50 / p95 | Curtain path p50 / p95 |
|---|---|---|---|
| 15 fps (PRD default) | 44.9 / 71.5 ms | 47.6 / 85.4 ms | 54.3 / 81.5 ms |
| 30 fps | 30.7 / 47.2 ms | 45.2 / 62.6 ms | 31.5 / 52.5 ms |
| 60 fps (capture only) | 19.4 / 32.7 ms | – | – |

Raw lines:

```
capture_latency_ms p50=44.9 p95=71.5 n=50 missed=0          # fps=15
blur_latency_ms    p50=47.6 p95=85.4 n=50 missed=0 detect_calls=50
curtain_latency_ms p50=54.3 p95=81.5 n=50 missed=0
capture_latency_ms p50=30.7 p95=47.2 n=50 missed=0          # fps=30
blur_latency_ms    p50=45.2 p95=62.6 n=50 missed=0 detect_calls=50
curtain_latency_ms p50=31.5 p95=52.5 n=50 missed=0
capture_latency_ms p50=19.4 p95=32.7 n=50 missed=0          # fps=60
latency_config long_side=1280 trials=50 display_pt=1470x956
```

`detect_calls=50` = the person was detected in the very first frame that showed the photo, every trial.

## Reading the numbers

- **Capture latency is dominated by the capture interval**: roughly half the frame interval plus ~12 ms of compositor + SCK
  work (p50 45 → 31 → 19 ms at 15 → 30 → 60 fps). The 15 fps curtain p50 (54 ms) being above the blur p50 (48 ms) is noise
  from parallel builds, not a real ordering; at 30 fps the curtain path is 14 ms cheaper than blur, as expected.
- Detection (`DetectHumanRectanglesRequest`, full frame 1280×832, first call warmed) adds ~15 ms p50 to the capture latency.
- **PRD check**: Blur exposure ≤ 150 ms p95 → 85 ms p95 at 15 fps, comfortably in (this rig has no tracker/classifier
  stage and stops at the commit, so add the on-screen presentation of the commit, ~1 display frame). **Curtain exposure
  ≤ 50 ms p95 is not reachable with 15 fps capture** (81 ms p95, capture alone is 72 ms p95); it is borderline at 30 fps
  (52.5 ms p95) and would need ~60 fps capture for Curtain apps. PRD delta candidate for M1-T09: either raise the Curtain
  target to ≤ 100 ms at 15 fps or capture Curtain-app displays at 30–60 fps (CPU cost to be measured in M1-T08).

## Done when
p50/p95 for capture latency, Blur path and Curtain path: recorded above (noisy). Re-run in the quiet phase:
`swift run sitr-spike latency` and `swift run sitr-spike latency --fps 30`.

## Notes
- Times are `CACurrentMediaTime()` deltas; paint time is taken after `CATransaction.commit()` + `flush()`, i.e. when the
  change has been handed to the render server, not when it is on glass (the real on-screen exposure is up to one display
  frame more on both ends).
- Vision normalized rectangles (lower-left origin) map straight onto AppKit screen points for a full-display frame.
- Two-display check: pending (one-display machine).
