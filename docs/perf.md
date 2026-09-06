# M4-T09 — Performance pass

What the app cost per frame, what was cut, what it costs now, and what is still missed. This is the pass the M1 spike's
**conditional GO** hangs on (`docs/spike-report.md` §5): the browsing and video CPU rows and the Blur exposure p95.

Machine: **Apple M3, 24 GB, macOS 26.6.2**, one built-in display 1470×956 pt @2×, capture 1280×832 px, 15 fps, release bundle
(`scripts/build-app.sh`). **The PRD's baseline machine is an M1 8 GB and nothing here has been measured on it** — every verdict
below is *pending a re-take on M1 8 GB*, exactly as every other number in `docs/spike/*.md`.

The machine is shared with the user's own work throughout (a Python job, an editor, a browser); `load1` is on every line and
anything above 4 is marked `noisy`. Because the machine's own load moved by 5× between runs, **every before/after pair below was
taken in one interleaved session from one binary**, with `SITR_PERF_LEGACY=1` restoring the pre-pass per-frame behaviour
(`Pipeline.swift`, `perfLegacy`). A number taken minutes apart on this machine is not a comparison; a number taken back to back
against the same scene is.

## 1. The result

| PRD metric | Target | Before (M1 spike) | Before (this session, `SITR_PERF_LEGACY=1`) | After | Verdict |
|---|---|---|---|---|---|
| CPU, active browsing at 15 fps | ≤ 15 % of one P-core | 32.7 debug / 28.0 release | **30.0** (load1 6.8) · **26.0** (load1 3.8) | **5.6** (load1 5.7) · **7.8** (load1 4.6) | **pass**, 2× under |
| CPU, 1080p video with people | ≤ 25 % of one P-core | 41.5 / 38.3 | **28.7** (load1 3.3) · **32.3** (load1 4.7) | **26.1** (load1 3.7) · **28.5** (load1 4.9) | **missed** by 1.1–3.5 points |
| CPU, near-static screen, 7 people covered | < 1 % | not measurable (30–37 %) | **30.5** (load1 6.5) | **0.5 mean / 1.1 exact** (load1 3.5) | **pass**, first time measured (§5) |
| Blur exposure p95 (person → covered) | ≤ 150 ms | 276 / 298 / 360 | **254.6** (quiet, load1 2.1) | **121.0** · **143.3** (quiet) | **pass on a quiet machine**; 152–186 under load |
| Curtain exposure p95 | ≤ 60 ms (amended) | 84.8 @30 fps / 97.9 @60 | — | — | **not measurable** here (§6) |
| Memory | < 300 MB | 141 / 168 release | 167–171 MB max | **140–144 MB max** | pass, kept |
| Render per cover | ≤ 2 ms | 0.35–0.46 ms | — | 1.01–1.34 ms p50 (render **+ on-screen apply**) | pass, kept |
| Person recall (bodies ≥ 80 px) | ≥ 90 % | 88.5 % | 88.5 % | **88.7 %** | unchanged (§4) |

Supporting, same sessions:

| | Before | After |
|---|---|---|
| Frames the pipeline processed, browsing / 120 s | 1276 (10.6 fps) | **472 (3.9 fps)** |
| Frames processed, near-static / 120 s | 1323 (11.0 fps) | **48 (0.4 fps)** |
| Frames processed, video / 120 s | 1533–1581 | 1644 (*more*: the screen really does change that fast) |
| e2e p50/p95, browsing | 51.5 / 152.0 ms | **44.4 / 101.5 ms** |
| e2e p50/p95, video | 45.3 / 105.3 ms | **31.6 / 80.1 ms** |
| Face crops classified per processed frame, browsing | 0.79 | **0.23** |
| Face crops per frame, near-static (7 people) | 3.00 | **1.48** |
| Cover renders per frame, near-static | 7.00 | **3.50** (+3.50 reused) |
| Overlay commits per processed frame | 1.00 everywhere | **0.35 (browsing) · 0.02 (near-static) · 0.99 (video)** |
| Backlog over 3 min of motion | skip ratio 0.237 → 0.165, RSS 95 → 93 MB (M1, 10 min) | skip ratio 0.033 → 0.010, RSS 114 → 92 MB, `backlog_growth=false` |

## 2. What the profile said, and what actually paid

Profiled with `sample` (the Time Profiler's sampler; no sudo, no UI) on the release bundle under the `browsing` and `video`
stimuli, 30 s each, aggregated by symbol. Instruments' own `xctrace` was not needed: `sample` attributes the same call graph and
the answers were unambiguous at every step.

**The first profile (browsing, 30 s, 2 covers up, ~12 processed fps):**

| Symbol | Samples | Reading |
|---|---|---|
| `-[MLModel predictionsFromBatch:]` (gender classifier) | 1961 | the biggest single item — bigger than the person detector |
| `-[CIContext render:toCVPixelBuffer:]` (detector letterbox + classifier crops) | 1378 | Core Image preprocessing |
| `CoverRenderer.render` (`startTask` 1192 of which `waitUntilCompleted` 1036) | 1039 | one GPU round trip per cover, serialized |
| `-[MLE5Engine _predictionFromFeatures:]` (person detector) | 625 | the ANE work itself |
| `WindowTracker.refresh` | 484 | 10 Hz poll on the main thread |
| `FaceDetector.detect` | 183 | plus its own Vision queue (1592 on `VNANFDMultiDetectorANODv4`) |

`E5RT::Ops::BnnsCpuInferenceOperation::ExecuteSync` sat under the classifier's batch call: parts of the int8 ViT do not fit the
ANE and run on the **CPU** through BNNS, which is why the classifier costs three times what the detector does.

The changes, in the order they were made, with what each one actually bought:

### 2.1 Classify a settled track once a second, not every frame — **paid**
`classificationOrder` gained a `fresh` argument and the pipeline a `classifiedAt` map: a track the classifier answered for less
than `Pipeline.classifyRefresh` (1 s) ago is skipped entirely; new and `.unknown` tracks are never deferred, so a person walking
on screen is still classified on the frame they are first seen. Crops per processed frame: **0.79 → 0.23** browsing, **3.00 →
1.48** near-static, 0.75 → 0.15 video. The classifier fell from 1961 to 149 samples in the profile.

Cost, stated plainly: a track whose *person* changes without the box moving keeps the old category for up to `classifyRefresh` ×
`Tracker.flipFrames` ≈ 3 s, where it used to be ~0.6 s. `--selftest category` still covers the right person in 211 ms in every
branch (women / men / Strict-Unknown).

### 2.2 The app was feeding itself frames — **paid, and this was the whole game**
The overlay panel lives on the display the `SCStream` captures. It is excluded from the *content* filter, so its pixels never
reach a frame — but a commit still **damages the display**, and ScreenCaptureKit answers damage with a `.complete` frame. Every
frame produced a commit, and every commit produced the next frame.

Measured directly, with a temporary switch that skipped every `panel.apply` (`browsing` stimulus, 40 s):

```
applies on : frames_in=372 in 30 s (12.4 fps)   cpu_mean=29.3 %
applies off: frames_in=122 in 35 s ( 3.5 fps)   cpu_mean= 6.9 %      reuse_blocked=0px/179mv
```

Three quarters of the frames, and three quarters of the CPU, were the app's own output. It also poisoned the obvious fix: the
`dirtyRects` of those frames were our own covers, so a cover never looked reusable (`reuse_blocked` was 73 % "pixels changed"
with applies on, **0 %** with them off).

The fix is two rules that reinforce each other:
- `Pipeline.applyAll` does not commit a spec list identical to the one already on the panel (`CoverLayerSpec.matches`), and
  `OverlayPanel.apply` guards every layer write and skips the `CATransaction.flush` when a pass changed nothing.
- A frame's `dirtyRects` are trusted only when the previous `applyAll` committed **nothing** (`Pipeline.ownDamage`). After a real
  commit a cover may still be reused, but only on the movement test — which is exactly the case that ends the cycle.

Result: browsing 30.0 → 5.6 %, near-static 30.5 → 0.5 %, commits per frame 1.00 → 0.35 / 0.02. Video is unchanged by this,
because there the screen genuinely changes 15 times a second and the commits add nothing to the frame supply.

### 2.3 Reuse a cover's pixels while its box and its pixels hold still — **paid only after 2.2**
`coverCanReuse`: the padded rect moved less than 1.5 pt (one capture pixel) and no trusted changed region touches it → the layer
keeps the surface it has. On its own this fired **zero** times; behind 2.2 it fires 3.5 times per frame on a near-static screen
and 0.38 on browsing, and it is what makes the identical-commit check above have anything to be identical about.

### 2.4 Submit a frame's cover renders together — **paid, small**
`CoverRenderer.prepare` / `finish`: all of a frame's covers are handed to the GPU, then waited for once, instead of one
`waitUntilCompleted` stall each (that stall was 1036 of the 1192 samples in `startTask`). Same for the Curtain pre-covers.

### 2.5 Render a big Gaussian reduced — **paid**
A Gaussian of σ carries no detail finer than about σ, so a cover with σ ≥ 8 is rendered at half and σ ≥ 16 at a quarter of
capture resolution with σ/k, and the layer scales it back (`contentsGravity .resize`). `docs/spike/blur.md` §1 names this
outright ("cap the radius or blur a 2–4× downsampled crop (visually identical)"). Never fewer than 4 samples per σ, so the
reduction can only remove detail the blur was going to remove anyway — it cannot make a cover *less* unrecognizable. Cover
render p95 in the app: browsing 46.5 → 20.1 ms per frame, video 28.0 → 14.3 ms.

### 2.6 Lanczos only where the frame is really being reduced — **paid, biggest single item after 2.2**
The person detector resampled every frame into its 1280×768 canvas with `CILanczosScaleTransform`. In the `video` profile that
one Core Image call was **4967 of the detector's 4947 samples** — the CoreML prediction itself was 835. But the app captures at
the model's own long side, so the scale factor is ~0.92: there is nothing to alias away. `CoreMLPersonDetector.lanczosBelow`
(default 0.9) keeps Lanczos for a real reduction — a COCO photo, a 2560 px screenshot — and takes the affine transform's bilinear
tap otherwise. The grey letterbox is also cropped to the strip the image does not cover instead of an infinite colour plane.
Detector Core Image cost: **4947 → 2826 samples**, −43 %. Recall is unchanged and measured three ways (§4).

### 2.7 Ask Vision for faces only when a face could change a cover — **paid where tracks are stable**
Faces feed nothing but `classifiable` and `categorize`. `needsFaces` skips the request when every detected person already sits on
a known track with a fresh answer; when the prediction from last frame's tracks says faces are wanted, the two detectors still
run concurrently as before, so no frame that needs a face pays for serialization. A frame that skipped faces keeps each person's
tracked category instead of calling them all Unknown (that branch is explicit in `Pipeline.run` and unit-tested).
Fires 6–12 times per 1600 frames in browsing/video; the tracks churn under continuous motion, so it rarely fires there.

## 3. What did not pay, and what was not done

- **Cover-render reuse on its own** did nothing (0 reuses in 1300 frames) until the commit loop in §2.2 was closed. Reported
  because it is the trap: the metric that looked like a scene property was our own output.
- **Ignoring `dirtyRects` that are contained in our own cover rects** (the first attempt at §2.2) never matched once. SCK
  coalesces damage into one or two large bounding boxes — a measured example is a 572×895 pt rect covering two 157×412 and
  215×686 pt covers — so containment is the wrong test. Replaced by the `ownDamage` rule and deleted.
- **Skipping detection when every changed region is too small to hold a body and touches no track**
  (`nothingDetectableChanged`, the first item on the spike report's fix list) **never fired** — `detect_skips=0` in every
  scenario measured, for the same coalescing reason: SCK's changed regions are hundreds of points across even for a small
  change. It is kept because it is a handful of lines, is unit-tested, and is correct where the compositor reports finely, but
  it bought nothing here and should not be counted as a win.
- **Detection ROI from `dirtyRects` plus tracked boxes** (named in the task line as the fallback if CPU was still missed): not
  implemented, and it is not a CPU lever. The network input is a fixed 1280×768; cropping to an ROI and scaling *that* into the
  same canvas costs the same ANE time and more Core Image time. It would buy **recall** on small people, which is a different
  task (`docs/bench.md`'s 77.6 % on 20–40 px bodies), and it is worth doing for that reason.
- **`WindowTracker.refresh`** (484 samples, 10 Hz on the main thread) was left alone: it is another task's file, its own unit
  test measures 0.08 % of a core, and it is now a visible share of a much smaller total rather than a problem.
- **The classifier's own Core Image crop path** (one Lanczos per crop) was left alone: §2.1 cut the number of crops by 4–13×,
  which is the same saving for none of the risk.
- **Batching all of a frame's covers into one Core Image pass** (one graph, one destination, instead of one per cover) is the
  next real lever for the video row and was not attempted — it changes the overlay's one-layer-per-cover model.

## 4. Recall: unchanged, measured three ways

The only change to what the detector sees is §2.6. `sitr-bench` gained `--lanczos-below` so the same binary measures the
before, the shipped default, and a version far past what the app ever asks for. 199 of 200 COCO images (one URL failed to
download; the same 199 in all three runs), quiet machine, `load1` 2.6–2.9, `noisy=false`:

| `--lanczos-below` | all | ≥ 80 px | large | medium | large+medium | small | back | partial |
|---|---|---|---|---|---|---|---|---|
| `2` — always Lanczos (**before**) | **84.5** | 88.5 | 93.2 | 90.4 | 91.6 | 77.6 | 92.9 | 84.1 |
| `0.9` — **shipped default** | **84.6** | 88.7 | 93.2 | 90.9 | 91.8 | 77.6 | 92.9 | 84.1 |
| `0` — never Lanczos | **84.7** | 89.0 | 93.2 | 90.9 | 91.8 | 77.6 | 92.9 | 84.1 |

Recall does not move (+0.1 to +0.5 points at the extreme setting is one to three boxes of 793 — noise, and in the safe
direction). The "before" row reproduces `docs/bench.md` and `docs/spike-report.md` exactly (84.5 / 88.5 / 91.6), which is the
check that the harness is measuring the same thing. `bothResamplePathsSeeTheSamePerson` in `Tests/SitrDetectTests` keeps the two
paths agreeing on the shipped fixture.

Nothing else changed what is fed to any model: the detector input is the same full frame at the same size, the classifier crop
rule is untouched, and no downscale, stride or ROI was introduced.

## 5. The "static screen" row, which the M1 spike could not measure

M1 recorded this row as **unmeasurable**: the user's desktop was never static (7.6 complete fps with Sitr not running), and the
neighbouring case — idle user, 7 people permanently on screen — cost 30–37 %.

In this session the desktop *was* nearly still, and that was verified independently rather than assumed: `sitr-spike capture
--seconds 30`, with no Sitr and no stimulus, measured **0.45 complete fps** (14 complete, 300 idle in 31 s) in the same window.
With 7 people on screen and 7 covers up:

```
perf_legacy=1  cpu_mean=30.5  cpu_exact=32.1  frames_in=1323 (11.0 fps)  crops/frame=3.00  renders/frame=7.00  applies=1323
perf_legacy=0  cpu_mean= 0.5  cpu_exact= 1.1  frames_in=  48 ( 0.4 fps)  crops/frame=1.48  renders/frame=3.50  applies=  24
```

So the PRD's `< 1 %` row is **met** — 0.5 % sampled, 1.1 % from the `cputime` delta — on a screen delivering 0.45 complete fps
with seven covers on it. Two honest qualifications: "static" here means 0.45 complete fps, not zero; and this is still the M3,
not the M1 8 GB. The M1 number of 30 % for the same scene was almost entirely the app watching its own covers redraw.

## 6. Curtain exposure: not re-measured

`Sitr --selftest curtain` could not run on this machine: every trial reports `missed`, because the remote stimulus never answers
(`curtain_exposure_ms n=0 missed=31`). The cause is the harness, not the pipeline — a sandboxed `Stimulus.app` cannot write into
the channel directory the unsandboxed parent hands it in its own temp dir. Verified as pre-existing: **identical with
`SITR_PERF_LEGACY=1`** and identical from the debug build. `docs/m3/integration.md` owns that recipe.

What could be measured is the half Sitr controls, from the same runs — capture callback → pre-cover on screen:

```
perf_legacy=1  fast_ms=11.20/47.89  pre_render_ms=1.87/26.03  clear_ms=0.03/0.06
perf_legacy=0  fast_ms=11.54/45.44  pre_render_ms=2.67/17.94  clear_ms=0.03/0.08
```

Unchanged, as expected: the Curtain fast path runs *before* detection and every change in this pass is after it. **The amended
≤ 60 ms p95 target is still not demonstrated** (M3-T05 measured 84.8 ms at 30 fps on a shared machine), and it stays open.

## 7. Still missed

1. **CPU, 1080p video with people: 26.1–28.5 % against ≤ 25 %.** Missed by 1.1–3.5 points. The video scenario is the only one
   where the frame supply is real: two large person photos travelling on Lissajous paths at 30 fps across a 1300×860 pt panel
   means every cover moves on every frame, so nothing can be reused, nothing can be left uncommitted, and the screen changes
   fast enough to keep the stream at its 15 fps ceiling. Per processed frame the cost fell 22 % (e2e p50 45.3 → 31.6 ms), and
   the app spends the saving on processing more of the frames it is offered (1533 → 1644 in 120 s) rather than on being idle.
   The named next lever is §3's one-Core-Image-pass-per-frame for covers. **Not moved: the target stays at 25 %.**
2. **Blur exposure p95 is at the line, not clear of it.** Five quiet-ish runs: 121.0, 143.3, 152.3, 166.4, 185.7 ms (p50 67–120).
   The two genuinely quiet runs (`noisy=false`, load1 2.2 and 2.9) are 121.0 and 143.3 — in. The structural floor is capture
   latency, which `docs/spike/latency.md` measures at 80 ms p95 on its own at 15 fps; one pipeline pass (e2e p95 51–101 ms) sits
   on top of it. On a machine with 4 % of a core to spare this passes; under the load this one carries it does not.
3. **Curtain exposure**: not measurable here (§6).
4. **Everything is pending an M1 8 GB re-take.** An M3 has 4 P-cores and a faster ANE; the two rows that pass with margin
   (browsing at 2× under, static at 2× under) will likely survive the move, and the two that are at the line (video, exposure
   p95) may well not. Nothing in this document settles the PRD gate.
5. Not re-checked here and still open from M1: two displays, GPU/ANE utilisation (needs `sudo powermetrics`), the 3-reviewer
   unrecognizability review of the blur curve.

## 8. Regression protection

`Sitr --selftest pipeline` (the Blur exposure test, which already drives the real `Runtime` over a still photo) gained a
`perf_budget` line that **gates the run**:

```
perf_budget frames=244 applies_per_frame=0.574/0.900 crops_per_frame=0.217/0.500 renders_per_frame=2.037 reuses_per_frame=2.311 ok=true
```

Both gated ratios are per processed frame, so they do not depend on how fast the machine is or what its load was:

- `applies_per_frame ≤ 0.90` — the §2.2 loop. Before the pass this is exactly **1.000** and the gate fails; after it is 0.56–0.58.
- `crops_per_frame ≤ 0.50` — the §2.1 cadence. 0.19–0.22 after; a return to classifying every frame on a screen with faces on
  it puts it back over 0.5.

`renders_per_frame` and `reuses_per_frame` are printed but not gated: how many covers can keep their pixels depends on how much
of the user's own screen is moving, which the test does not control. Verified red before green:

```
SITR_PERF_LEGACY=1 → perf_budget applies_per_frame=1.000/0.900 … reuses_per_frame=0.000 ok=false   (selftest_pipeline ok=false)
                   → perf_budget applies_per_frame=0.574/0.900 … reuses_per_frame=2.311 ok=true    (selftest_pipeline ok=true)
```

`--selftest pipeline --motion` prints the same counters as `motion_frame_work` without gating them (continuous motion has
nothing to reuse), next to the existing backlog and RSS check.

Unit tests (`Tests/SitrTests/PerfPassTests.swift`, 7 tests): every shortcut's decision is a pure function and each test is
really a correctness test — `classificationOrder` with freshness, `needsFaces`, `coverCanReuse`, `CoverLayerSpec.matches`,
`nothingDetectableChanged`, `CoverGeometry.blurDownscale` (including "at least 4 samples per σ at every step"), and
`PerFrameBudget` itself. `Tests/SitrDetectTests` gained `bothResamplePathsSeeTheSamePerson`.

## 9. Reproduce

```
swift build -c release && scripts/build-app.sh
scripts/measure-system.sh browsing 120                  # after
SITR_PERF_LEGACY=1 scripts/measure-system.sh browsing 120   # before, same binary — interleave them
scripts/measure-system.sh video 120 ; scripts/measure-system.sh static 120
.build/release/Sitr --selftest pipeline --trials 30     # Blur exposure + the perf_budget gate
.build/release/Sitr --selftest pipeline --motion --seconds 180   # backlog, RSS, per-frame counters
.build/release/Sitr --selftest category                 # the classifier cadence has not broken a category
python3 Bench/download.py --labels Bench/labels/recall-coco.json
.build/release/sitr-bench Bench/labels/recall-coco.json [--lanczos-below 2|0]
```

Profiling, which needs no sudo and no Instruments UI: start the release bundle with `SITR_METRICS=1 SITR_DEV_BLUR=1`, start
`.build/debug/Sitr --selftest stimulus --mode browsing` in a second process, and `sample <pid> 30 -f out.txt`.

## Shortcuts (`// ponytail:`)

- `SITR_PERF_LEGACY` is an environment switch rather than a second build, like `SITR_FPS` / `SITR_CAPTURE_SIDE`. Nothing in the
  product reads it. Delete it once the numbers are re-taken on the M1 8 GB baseline.
- `classifyRefresh` is a flat 1 s for every track. The upgrade path is the ≤ 10 MB MobileNetV3 of `docs/spike/classifier.md`,
  cheap enough to run on every track on every frame and to close the 3 s category-flip window in §2.1.
- `coverCanReuse`'s tolerance is a fixed 1.5 pt rather than a fraction of the cover's padding.
- `nothingDetectableChanged` is kept although it never fired here (§3).
