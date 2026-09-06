# M1-T08 — System cost (`scripts/measure-system.sh`)

What the whole app costs while it runs: CPU (% of one core), memory, per-stage timings, thermal state, at 15 fps capture
with the shipped CoreML detector + classifier. Machine: Apple M3 (4 P + 4 E cores), 24 GB, macOS 26.6.2, one built-in display
1470×956 pt @2× (2940×1912 backing px), capture long side 1280 px.

## Reproduce

```
scripts/build-app.sh --debug        # or without --debug for the release bundle; both are measured below
swift build                         # the stimulus process runs from .build/debug/Sitr (it reads the repo's fixtures)
scripts/measure-system.sh browsing 600
scripts/measure-system.sh video 600
scripts/measure-system.sh static 300
SITR_CAPTURE_SIDE=1920 scripts/measure-system.sh video 120     # capture long side comparison
SITR_FPS=30 scripts/measure-system.sh video 120                # capture rate comparison
```

The script starts `build/Sitr.app/Contents/MacOS/Sitr` with `SITR_METRICS=1 SITR_DEV_BLUR=1 --quit-after <seconds>`, starts the
stimulus in a **second** process (`Sitr --selftest stimulus --mode browsing|video`) so the app's own-process exclusion does not
hide it, samples `ps -o %cpu=,rss=` on the Sitr PID once a second (macOS `%cpu` is per core, i.e. already "% of one core"),
records `pmset -g therm` at both ends, and prints three lines: `system_run`, `system_cpu`, `system_pipeline`. Steady state =
samples from t ≥ 10 s (model load and ANE warm-up excluded); `cpu_exact_mean` is the `cputime` delta over the same window,
`cpu_mean`/`cpu_p95` are the per-second `ps` samples. `replayd_cpu_*` is the ScreenCaptureKit server process, which does capture
work on our behalf but is not our process.

Stimulus modes (`Sources/Sitr/Selftest.swift`, additive):
- `video` — the two person photos travel on Lissajous paths at 30 fps: continuous motion with people, PRD's "1080p video with people".
- `browsing` — a 5 s page cycle: redraw (photo column blanked and repainted), a 1 s scroll burst at 60 Hz, then 4 s of reading.
- `static` — no stimulus at all; nothing of ours is drawn and the user's desktop is left alone.

**GPU and ANE utilisation are pending**: they need `sudo powermetrics --samplers gpu_power,ane_power`, and this rig never asks
for sudo. What can be said without it: both models run on `.cpuAndNeuralEngine` and every YOLOX op is placed on the ANE
(docs/spike/detect.md), and the covers are rendered by CoreImage on the GPU (docs/spike/blur.md).

## Caveat on this machine: the screen is never static, and there are always people on it

The rule for these runs is "never touch the user's own windows". The user's screen showed a browser window with **7 detected
people** (5 classified woman, 2 Unknown) throughout every run, and that window animates on its own: `sitr-spike capture
--seconds 30` with **no** Sitr and no stimulus running measures **7.6 complete fps** (mean over 30 s, 3.6–9 fps per window)
on the untouched desktop. So:

- `static` here means "we draw nothing" — not "nothing changes". Every `static` number below is really *idle user, 7 people on
  screen, ~9 fps of screen changes*. The PRD's `< 1 %` static row is **not** measured by it; see the reading below.
- `browsing` and `video` carry those 7 people **plus** the stimulus, so they are a heavier scene than the PRD's wording
  ("active browsing", "1080p video with people") suggests: up to 7 covers rendered per frame, 3 face crops classified per frame.
- The frames are the screen's, not a feedback loop of our own commits: the capture rig above sees the same rate with Sitr not
  running, and the overlay is excluded from the filter (docs/spike/overlay.md).

Load average was 2.5–26 across the runs (the user's own apps, one long-running Python job, and memory pressure that inflates
load1 without using CPU — the busiest non-Sitr process during the release runs was 11 %). Every line below carries its load
window. **Everything here is a single-run number on a machine that was never fully quiet; treat ±20 % as noise.**

## Numbers

### The three PRD scenarios — debug bundle, capture side 1280, 15 fps (2026-09-06)

| Mode | Seconds | CPU mean / p95 / max (% of one core) | CPU exact mean | RSS max | frames in | skipped | layers max | load1 min/mean/max |
|---|---|---|---|---|---|---|---|---|
| browsing | 600 | 32.7 / 56.1 / 74.5 | 34.2 | 140 MB | 6903 | 352 (4.9 %) | 7 | 2.5 / 4.0 / 10.7 |
| video | 600 | 41.5 / 64.1 / 79.1 | 43.1 | 141 MB | 7188 | 1551 (17.7 %) | 3 | 2.8 / 10.5 / 23.4 |
| static (see caveat) | 300 | 36.8 / 63.4 / 67.5 | 38.4 | 139 MB | 2746 | 22 (0.8 %) | 7 | 4.3 / 7.1 / 14.3 |

Pipeline stages, ms p50 / p95 (median over the 5 s metric windows of the run; the worst single window in brackets):

| Mode | detect | classify (per crop) | render (per cover) | commit | e2e (capture → commit) |
|---|---|---|---|---|---|
| browsing | 36.9 / 82.3 (165) | 14.2 / 25.8 (120) | 4.4 / 24.4 (137) | 0.2 / 0.4 | 53.4 / 172.1 (361) |
| video | 45.7 / 78.4 (154) | 19.1 / 29.5 (52) | 7.9 / 31.6 (77) | 0.2 / 0.5 | 90.2 / 166.0 (278) |
| static | 31.3 / 58.4 (174) | 11.2 / 19.8 (58) | 9.3 / 42.9 (174) | 0.3 / 0.5 | 85.0 / 194.3 (727) |

`replayd` (the SCK server) adds 0.5–0.8 % of one core on average, 0.8–1.6 % p95, in every mode.
Thermal state: `pmset -g therm` reported no thermal, performance or CPU-power warning at the start and the end of every run.

### Debug vs release bundle, 120 s each (release built with `scripts/build-app.sh`)

| Mode | debug CPU mean (10 min run) | release CPU mean (2 min run) | release RSS max | release load1 mean |
|---|---|---|---|---|
| browsing | 32.7 | 28.0 | 142 MB | 13.1 (noisy) |
| video | 41.5 | 38.3 | 168 MB | 19.9 (noisy) |
| static | 36.8 | 30.0 | 140 MB | 7.8 (noisy) |

Release is 8–18 % cheaper than debug, no more: the time is inside CoreML (ANE), Vision and CoreImage, not in our Swift.
Both bundles are within each other's noise, so the debug 10-minute runs above are the reference numbers.

### Capture long side and capture rate — `video`, release bundle, 120 s each

| Configuration | CPU mean / p95 | frames in | skipped | detect p50/p95 | render p50/p95 | e2e p50/p95 | load1 mean |
|---|---|---|---|---|---|---|---|
| 1280 px, 15 fps (reference) | 38.3 / 52.3 | 1374 | 15.0 % | 38.6 / 70.4 | 8.4 / 31.0 | 72.8 / 156.8 | 19.9 |
| **1920 px, 15 fps** | 36.0 / 54.6 | 1327 | 21.1 % | 43.1 / 89.1 | 12.7 / 32.4 | 86.2 / 182.6 | 7.4 |
| **1280 px, 30 fps** | 47.4 / 61.3 | 1981 | 38.6 % | 35.6 / 61.6 | 7.9 / 14.9 | 72.9 / 122.2 | 12.9 |

- **1920 vs 1280 long side: no CPU difference** (36.0 vs 38.3 %, inside the noise of two runs at different load), but the
  render stage costs +50 % (12.7 vs 8.4 ms p50 — covers are cropped from a 2.25× bigger buffer) and 6 points more frames are
  skipped. Recall does not depend on the capture side either (docs/spike/detect.md), so **1280 stays**.
- **30 vs 15 fps: +24 % CPU** (47.4 vs 38.3 %) for +30 % processed frames (the pipeline saturates: 38.6 % of the 30 fps input
  is dropped by the newest-frame stream, so it really runs at ~18 fps). e2e p95 improves 157 → 122 ms. That is the price of
  the Curtain decision (docs/spike/latency.md): 30 fps only on displays showing a Curtain app.
- `SITR_CAPTURE_SIDE` / `SITR_FPS` are dev-only environment overrides read once by `CaptureSession` (`// ponytail:`), so this
  comparison needed no UI knob.

## Reading it against the PRD table

| PRD row | Target | Measured | Verdict |
|---|---|---|---|
| CPU, static screen | < 1 % | not measurable here (the desktop was never static); 30–37 % with 7 people permanently on screen at ~9 fps of screen change | **pending** — see below |
| CPU, active browsing at 15 fps | ≤ 15 % of one P-core | 32.7 % (debug, 10 min), 28.0 % (release, 2 min) | **fail** (2.2×) |
| CPU, 1080p video with people | ≤ 25 % of one P-core | 41.5 % (debug, 10 min), 38.3 % (release, 2 min) | **fail** (1.7×) |
| Memory | < 300 MB | 141 MB max (debug), 168 MB max (release) | **pass** |

- **Static.** A screen where nothing changes delivers no `.complete` frames at all (docs/spike/capture.md: 0 complete
  frames/s after the first second), and the pipeline only runs on complete frames, so the true static cost is the SCK idle
  callback plus a 1 Hz health poll — well under 1 %, but **not demonstrated here** and carried into M4-T09 on a machine whose
  screen can be left alone. What this run does show is the number nobody had before: a person who stops typing while people are
  on screen keeps paying ~30 % of a core, because every delivered frame re-detects, re-classifies and re-renders all 7 covers.
- **Where the CPU goes.** Per processed frame the app spends ~35 ms detecting (YOLOX-s 1280×768 ∥ Vision faces), ~6 ms × 3
  crops classifying, and 4–13 ms rendering covers, at 10–12 processed fps. Detection and classification are ANE wall time that
  still holds a cooperative thread; the covers are GPU work with a CPU-side commit. Nothing in the profile looks like a leak:
  RSS is flat and the skipped-frame ratio is stable (below).
- **The obvious levers for M4-T09**, in the order the numbers suggest: (1) don't re-detect a frame whose `dirtyRects` miss every
  tracked box (the static caveat above becomes free); (2) don't re-render a cover whose rect and source pixels did not change
  (render is 25–40 % of the per-frame cost when 7 covers are up); (3) re-classify a known track every N-th frame instead of
  every frame (the 3-crop cap already limits this, but 3 crops × 6 ms is 20 % of the budget); (4) detect every other frame and
  let the tracker's 300 ms persistence carry the gap — that alone would nearly halve the CPU.

## Backlog and memory over 10 minutes (`.build/debug/Sitr --selftest pipeline --motion --seconds 600`)

```
motion t=10  frames_in=79   skipped=63   window_skip_ratio=0.444 tracks=2 layers=2 rss_mb=109 detect_ms=67.28/109.09 classify_ms=23.99/40.20 e2e_ms=160.39/235.72 load1=19.2
motion t=300 frames_in=3395 skipped=981  window_skip_ratio=0.231 tracks=1 layers=1 rss_mb=92  detect_ms=42.33/82.79  classify_ms=17.58/33.99 e2e_ms=94.54/192.88  load1=7.1
motion t=600 frames_in=7018 skipped=1774 window_skip_ratio=0.143 tracks=2 layers=2 rss_mb=92  detect_ms=34.11/76.25  classify_ms=11.87/29.72 e2e_ms=58.01/158.64  load1=12.5
backlog_growth=false rss_mb_first=95 rss_mb_last=93 skip_ratio_first=0.237 skip_ratio_last=0.165 frames_in=7018 skipped_total=1774 skip_ratio_total=0.202 layers_max=2 seconds=600
```

10 minutes of continuous motion: **no backlog growth** (the check the drop-oldest stream exists for), RSS flat at 92–95 MB,
the skip ratio *falling* over the run (0.237 → 0.165) as the machine's own load fell, 0 errors, layers always present. The
pipeline runs at ~11.7 processed fps of a 15 fps input, so 20 % of frames are dropped by the newest-frame stream; every
dropped frame is a frame the tracker never sees, and the covers' 300 ms persistence covers the gap (no flicker observed).
Run at load1 7–19 (the user's own machine activity), so the per-stage timings are noisy; the flatness is the result.

## Shortcuts (`# ponytail:` / `// ponytail:`)

- `ps` sampling once a second instead of Instruments or `powermetrics`: no sudo, no dashboards; the exact mean comes from the
  `cputime` delta over the same window, and the two agree within 2 points in every run.
- The `browsing` stimulus is a fixed 5 s cycle (redraw, 1 s scroll burst, 4 s pause), not a recorded browsing trace.
- GPU / ANE utilisation: pending (`sudo powermetrics`).
- M1 8 GB (the PRD baseline machine): pending, as everywhere else in M1.
