# M2 Detect: CoreML person detector + face-gender classifier (M2-T06, M2-T07)

Makes the spike's two CoreML models the production detection path of the running pipeline (docs/m2/pipeline.md): YOLOX-s
1280×768 for persons (docs/spike/detect.md, M1-T06b) and the FairFace ViT-B/16 int8 for P(woman) (docs/spike/classifier.md,
M1-T05), through the pipeline's two plug-in protocols. Faces stay on Vision `FaceDetector`.

## Files
- `Sources/SitrDetect/GenderClassifier.swift` — `GenderClassifier`: loads the compiled model, crops faces with the spike's rule,
  scale-fills to the input, batch-predicts `probs[0]` = P(woman). `SitrDetect.swift` gains `bgraPool(width:height:)`, shared with
  `CoreMLPersonDetector` (otherwise untouched: threshold 0.30, NMS 0.5 as shipped).
- `Sources/Sitr/Pipeline/Pipeline.swift` — `CoreMLPersonDetector: PersonDetecting`, `GenderClassifier: GenderClassifying`
  (the protocol now takes `faces: [Rect]` → `[Double?]` so one call classifies a frame's faces), `classifiable`,
  `classificationOrder` (the 3-faces-per-frame cap), sticky categories for skipped faces, `classify_ms` / `crops` /
  `categories=w/m/u` metrics, `modelsNote` header line.
- `Sources/Sitr/SitrApp.swift` — `Runtime.loadModels()`: where the models come from and the fallbacks (below).
- `Sources/Sitr/Selftest.swift` — `--selftest category`; `Stimulus` shows any fixture at any scale; exposure / motion lines carry
  `classify_ms`, `crops` and the model names; the exposure test's clear/hit checks are scoped to the person rect.
- `Tests/SitrDetectTests/GenderClassifierTests.swift` + `Fixtures/{woman,man}.jpg` (CC0, `Fixtures/ATTRIBUTION.md`),
  `Tests/SitrTests/CategoryWiringTests.swift`.

## Where the models come from
`Runtime.start()` loads both models while capture connects, then creates the pipelines:
1. `Bundle.main.url(forResource: "PersonDetector" | "GenderClassifier", withExtension: "mlmodelc")` — `scripts/build-app.sh`
   compiles every `Models/dist/*.mlpackage` into `Contents/Resources`. Load: ~0.1 s per model with a warm ANE cache, 3–4.5 s
   each on the first launch after an install/update (CoreML compiles for the ANE and caches it).
2. Dev fallback (`.build/debug/Sitr`, `swift run`, the selftests — a shell-launched checkout, not a shipped app):
   `Models/dist/<name>.mlpackage` relative to `#filePath`, compiled on the fly (~0.6 s each).
3. Otherwise the pipeline keeps `VisionPersonDetector` (full ∪ upper body) and/or `NoClassifier` (every person Unknown), with
   one `os.Logger` line per missing model (`com.goldentik.Sitr` / `runtime`: "<model> unavailable, using the fallback: <reason>").
Both models run on `.cpuAndNeuralEngine`: the GPU stays free for the cover renderer, and `.all` let CoreML schedule parts of the
ViT on the GPU and doubled its latency in the spike. `SITR_METRICS=1` prints `pipeline display=N detector=… classifier=…` at start.

Note: the sandboxed `build/Sitr.app` cannot read the source tree, so selftests that show fixtures (`category`, `pipeline`,
`failstate`) run from `.build/debug/Sitr` (fallback 2 gives them the same models); the bundle is used for the manual metrics run.

## Per frame (what changed in `Pipeline.run`)
persons (`CoreMLPersonDetector`) ∥ faces (Vision) → `assignFaces` (largest overlap, unchanged) → `classifiable` (face short side
≥ 32 px and body ≥ 40 px in capture pixels — `categorize` would return Unknown anyway, so the model is not run) →
`classificationOrder` picks ≤ 3 faces: persons with no matching track (IoU ≥ 0.3 against the current tracks) or on an `.unknown`
track first, the rest after, both groups rotated by a per-frame round so nobody starves → one `GenderClassifier` call →
`categorize(face:body:pWoman:)`. A classifiable person skipped by the cap carries the category of the track it lands on (the
`Tracker` keeps it sticky anyway); everything else is Unknown by rule. Warm-up runs one prediction per model on a blank frame.

## GenderClassifier
- Contract verified from the compiled model's description: input `image` Color 224×224, output `probs` MultiArray **Float16**
  `[1, 2]` (SOURCE.md says float32; read through `NSNumber`, so both work) = `[P(woman), P(man)]`.
- Crop = `Sources/SitrSpike/Classifier.swift` `FaceCrop.cropRect` verbatim: square of 1.4× the longer face side around the face
  centre (20 % margin per side), clamped to the frame, `.integral`; scale-filled with `CILanczosScaleTransform` into a pooled
  224×224 BGRA buffer straight from the SCStream `CVPixelBuffer` (no CGImage round trip); CoreML maps BGRA → the model's RGB.
  Parity with the spike's `MLFeatureValue(cgImage:…scaleFill)` path on the 12 candidate portraits: within 0.02 on 11, one
  0.78 → 0.98 (ours more confident, same label).
- Batch vs loop (`predictions(fromBatch:)` vs three `prediction(from:)`, random 224×224 inputs, 100–200 runs each, load 4–7):
  per crop 6.11 vs 6.69 ms, then 9.18 vs 9.57 ms — batch 5–9 % cheaper, so faces go in one batch call. `.all` measured
  6.24 / 6.98 and 10.81 / 27.74 ms p50 / p95 in the same runs, `.cpuAndNeuralEngine` 6.76 / 17.16 and 9.61 / 15.89.
- The call is synchronous (CoreML has no async batch API); it runs inside the pipeline actor's turn, so it holds one cooperative
  thread for ~10–30 ms per frame with faces. Acceptable at ≤ 3 crops; noted as the first thing to move if the pool ever starves.

## Verified on this machine (Apple M3, macOS 26.6.2, 1470×956 pt @2×; other agents building throughout — load1 noted per line)
- `swift build`: 0 warnings in the files above. `swift test`: **118 tests pass** (7 new). `scripts/build-app.sh --debug` +
  `scripts/check-entitlements.sh`: OK. The classifier tests compile `Models/dist/GenderClassifier.mlpackage` once into the temp
  dir (keyed by the manifest mtime) and skip, not fail, without it.
- Fixtures (500 px Commons thumbnails, unmodified): `woman.jpg` P(woman) 0.991 (image path) / ≥ 0.98 (buffer path), `man.jpg`
  P(woman) 0.008. The test's per-crop time (3 crops per call, crop + resize + model, BGRA frame), two runs:
  `classifier_ms_per_crop p50=8.26 p95=29.25 n=20 crops_per_call=3 spike_p50_ms=8-10 load1=3.9 noisy=false` and
  `classifier_ms_per_crop p50=18.13 p95=21.82 n=20 crops_per_call=3 spike_p50_ms=8-10 load1=16.2 noisy=true`.
- `.build/debug/Sitr --selftest category` (5 consecutive passes after the checks were scoped to the photo; the user's screen had
  four other people in view the whole time — three women and one Unknown at the top — which the pipeline covered or not per policy,
  visible in the `category_debug` lines; quietest run, load1 4.9):
  ```
  category_check hidden=women strict=false fixture=man expect_cover=false covered=false first_cover_ms=- within_ms=- track=man expected_track=- ok=true
  category_check hidden=women strict=false fixture=woman expect_cover=true covered=true first_cover_ms=157 within_ms=1000 track=woman expected_track=woman ok=true
  category_check hidden=men strict=false fixture=woman expect_cover=false covered=false first_cover_ms=- within_ms=- track=woman expected_track=- ok=true
  category_check hidden=men strict=false fixture=man expect_cover=true covered=true first_cover_ms=106 within_ms=1000 track=man expected_track=man ok=true
  category_check hidden=men strict=true fixture=small_person expect_cover=true covered=true first_cover_ms=160 within_ms=2000 track=unknown expected_track=unknown ok=true
  category_summary ok=true detector=CoreMLPersonDetector classifier=GenderClassifier detect_ms=17.81/21.33 classify_ms=5.09/6.39 crops=552 errors=0 load1=4.928 noisy=true
  ```
  `small_person` is the spike's 500×749 photo at 0.6 (face ≈ 22 px in the capture, body ≈ 320 px). Across the five runs
  `first_cover_ms` ranged 106–472 (woman/man) and 102–316 (small person); `classify_ms` p50 per crop 5.1–13.7 ms, `detect_ms`
  p50 17.8–34.7 ms (YOLOX ∥ Vision faces, both on the ANE), load1 3.2–7.9. The quiet-run classifier number (5.09 / 6.39 ms per
  crop including crop + resize) is under the spike's 8–10 ms gate; loaded runs are not.
- `.build/debug/Sitr --selftest pipeline --trials 30` (Gaussian 0.7, padding 0.15; five covers per frame because of the four
  bystanders; load1 5.1, **noisy**):
  ```
  exposure_ms p50=116.78 p95=265.57 n=30 missed=0 target_p95_ms=150 within_target=false load1=5.147 noisy=true path=blur style=gaussian
  cover_control overlap_min=1.000 overlap_p50=1.000 layers_max=5 covers_cleared_between_trials=true ok=true
  pipeline_counts in=504 out=504 skipped=13 detections=504 errors=0 applies=504 detect_ms=35.81/69.03 classify_ms=15.96/26.33 crops=53 track_ms=0.09/0.24 render_ms=7.99/60.48 commit_ms=0.25/0.63 e2e_ms=53.72/177.65 health=ok detector=CoreMLPersonDetector classifier=GenderClassifier
  ```
  Against the Vision-detector run in docs/m2/pipeline.md (79 / 129 ms, one cover, load 3): detection is 36 vs 21 ms p50 (YOLOX
  and Vision faces share the ANE), and five Gaussian covers instead of one push render p95 to 60 ms on a contended GPU. The p95
  target is **not demonstrated here**; the quiet-phase run (nothing else on the machine, no bystanders) is pending, as before.
- `.build/debug/Sitr --selftest pipeline --motion --seconds 120` (two moving photos → two faces classified every frame; load1
  4.3–5.7, noisy):
  ```
  motion t=120 frames_in=1445 detections=1444 skipped=319 window_skip_ratio=0.262 tracks=2 layers=2 rss_mb=94 detect_ms=41.30/83.14 classify_ms=17.35/38.23 crops=1055 e2e_ms=92.74/183.52 errors=0 load1=4.620
  backlog_growth=false rss_mb_first=107 rss_mb_last=93 skip_ratio_first=0.223 skip_ratio_last=0.186 frames_in=1445 skipped_total=319 skip_ratio_total=0.181 layers_max=2 seconds=120 load1=4.620 detector=CoreMLPersonDetector classifier=GenderClassifier
  ```
  No backlog: RSS flat (107 → 93 MB), skip ratio flat. The pipeline now runs ~10–12 fps on this loaded machine (detect 41 + two
  crops ≈ 35 + render), so 18 % of frames are skipped by the drop-oldest stream (0.9 % with Vision). Every skipped frame is a frame
  the tracker never sees; covers persist 300 ms, so no flicker was observed.

- Manual-by-code: `scripts/build-app.sh --debug`, then `.build/debug/Sitr --selftest stimulus --seconds 30` (the spike photo
  drifting, second process) next to `SITR_METRICS=1 build/Sitr.app/Contents/MacOS/Sitr --quit-after 20` (the sandboxed bundle, so
  the models come from `Contents/Resources`; four bystanders on screen again, load1 4.2–4.5):
  ```
  pipeline display=1 detector=CoreMLPersonDetector classifier=GenderClassifier
  pipeline display=1 first_frame_at_ms=-2348 first_commit_at_ms=277 warmup_ms=167 layers=6
  pipeline display=1 t=5  in=49  out=48  skipped=0  detections=48  errors=0 applies=48  detect_ms=17.32/77.20 classify_ms=4.89/27.87 crops=144 track_ms=0.09/0.18 render_ms=3.27/90.55 commit_ms=0.14/0.39 e2e_ms=35.42/219.87 tracks=7 categories=w5/m0/u2 layers=6 rss_mb=135 load1=4.385
  pipeline display=1 t=10 in=80  out=79  skipped=12 detections=79  errors=0 applies=79  detect_ms=37.68/77.72 classify_ms=13.44/22.85 crops=237 track_ms=0.17/0.24 render_ms=46.51/155.64 commit_ms=0.27/0.37 e2e_ms=152.91/362.09 tracks=7 categories=w5/m0/u2 layers=6 rss_mb=131 load1=4.514
  pipeline display=1 t=15 in=154 out=153 skipped=12 detections=153 errors=0 applies=153 detect_ms=17.28/19.03 classify_ms=4.94/6.32 crops=459 track_ms=0.08/0.10 render_ms=3.08/3.83 commit_ms=0.13/0.17 e2e_ms=35.61/42.09 tracks=7 categories=w5/m0/u2 layers=6 rss_mb=123 load1=4.232
  ```
  The CoreML detector and classifier are named in the header, `layers ≥ 1` from the first commit (6: the two photos and the four
  bystanders, five of them women per the classifier), the app quit on `--quit-after` with exit 0 and no `Sitr` process left. The
  t=15 window is the cleanest number so far: detect 17.3 / 19.0, classify 4.9 / 6.3 ms per crop, render 3.1 / 3.8, e2e 35.6 / 42.1
  ms p50 / p95 at 15 fps with 7 tracks; the t=10 window shows what GPU contention from other agents does to `render_ms`.
  `first_frame_at_ms` is negative because pipelines are now created after the models load (2.3 s here: the sandboxed app's
  own ANE cache was cold for this build) and the stream's single buffered frame predates the pipeline; covers were up 277 ms after
  the pipeline started. RSS 123–135 MB with both models resident (62 MB with Vision only).

## Shortcuts (`ponytail:` in code)
- `classificationOrder`: 3 crops per frame. Ceiling: ten faces cost the same as three, each re-checked every ~3 frames; a known
  track with ≤ 3 faces on screen is re-classified every frame because the `Tracker` flips only on 3 *consecutive* contrary
  observations (a skipped frame feeds the sticky category and resets the streak). Upgrade path: a "no opinion" observation in the
  Tracker so known tracks are re-checked every N-th frame, or the ≤ 10 MB MobileNetV3 from docs/spike/classifier.md and no cap.
- `Runtime.modelURL`: `#filePath` dev fallback to `Models/dist` (checkout only; a shipped bundle never reaches it).
- The synchronous batch call inside the actor (above).
- `category_debug` lines print track rects and categories (geometry and counts only, never pixels).

## Pending / needs from other owners
- Quiet-phase exposure and 10-minute motion runs; the M1 8 GB baseline (PRD).
- docs/m2/pipeline.md's plug-in section describes the old per-face `GenderClassifying` signature; this file supersedes it.
- `Package.swift`, `SitrCore`: nothing needed. `Tests/SitrDetectTests/ModelChecksumTests.swift` belongs to another agent.
