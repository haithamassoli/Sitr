# Spike notes: detection cost (M1-T03) and person recall (M1-T06)

Machine: Apple M3, 24 GB, macOS 26.6.2, Xcode 26.6, Vision `DetectHumanRectanglesRequest` revision 2. M1 8 GB: pending.
Cost numbers were re-taken in the quiet phase (2026-09-06, nothing else of ours running, load1 2.5–2.7) for the Vision rig and
the shipped CoreML model; the tables below carry the quiet numbers with the preliminary (2026-09-05, other agents building)
ones kept in one line each. Recall is deterministic and was not re-run. The rigs print one parseable line per metric
(`detect_ms …`, `recall …`, `recall_ms …`).

## Reproduce
```
python3 Bench/build_manifest.py            # COCO annotations zip -> Bench/recall/manifest.json + Bench/ATTRIBUTIONS.md
python3 Bench/download.py                  # 9 CC0 photos -> Bench/data/photos, 200 COCO images -> Bench/data/recall
swift run sitr-spike detect                # M1-T03, add --dump frame.png to see the composite frame with boxes
swift run sitr-spike recall Bench/recall/manifest.json   # M1-T06, add --dump <dir> for annotated PNGs
swift test                                 # GeometryTests + DetectorTests (fixture Tests/SitrDetectTests/Fixtures/person.jpg)
```
Bench images are downloaded, never committed (`Bench/data/` is gitignored); licenses in `Bench/ATTRIBUTIONS.md`.

## M1-T03 Detection cost

Rig: a 2560x1664 synthetic "web page" frame (grey header, 3x3 grid of 9 CC0 Wikimedia photos, about 21 visible people,
person heights 90–450 px at native size) drawn into an IOSurface-backed 32BGRA `CVPixelBuffer` like an SCStream frame,
downscaled to long side 1280 and 1920, plus native 2560 for reference. 5 warm-up runs, then 100 timed runs per
configuration; time covers `ImageRequestHandler` creation + `perform`. `full+faces` runs both requests through one handler.

Compute unit: Vision picks (`setComputeDevice` not called; `computeDevice(for: .main)` = nil). Supported devices reported
for both requests: Neural Engine, GPU, CPU.

Quiet phase (2026-09-06, load1 2.66, `.build/debug/sitr-spike detect`, n=100 per cell):

| config       | 1280 p50 / p95 ms | 1920 p50 / p95 ms | 2560 p50 / p95 ms | found (of ~21 people / 4 clear faces) |
|--------------|-------------------|-------------------|-------------------|-----------------------|
| full body    |  2.7 / 2.8        |  2.9 / 3.0        |  3.6 / 3.8        | 1 person              |
| upperBodyOnly|  2.7 / 2.7        |  2.9 / 3.1        |  3.6 / 3.9        | 6–7 persons           |
| faces        |  4.1 / 4.6        |  4.4 / 4.7        |  5.4 / 6.2        | 3 faces               |
| full + faces |  4.2 / 4.4        |  4.7 / 5.2        |  5.6 / 6.4        | 1 + 3                 |

Preliminary (2026-09-05, other agents building; superseded): full 14.0 / 24.1, 11.1 / 15.8, 15.9 / 26.6; upper 12.4 / 20.5,
8.4 / 10.7, 9.6 / 10.7; faces 21.6 / 39.1, 10.0 / 11.1, 23.3 / 45.3; full + faces 22.7 / 34.3, 10.9 / 21.7, 11.7 / 21.8 ms.

M1 (8 GB): pending.

Reading it:
- Cost is nearly flat in input size (1280 → 2560 adds ~1 ms, the downscale into Vision's own network input), so the capture
  long side is not a detection-cost lever.
- One frame of person + face detection costs 4–6 ms p50 on a quiet M3, far inside the 66 ms budget of 15 fps; the
  preliminary 11–23 ms were ANE/CPU contention from the other agents' jobs. Two requests on one handler cost about as much as
  the dearer request alone (shared preprocessing).
- The `found` column is the real finding: on a realistic page the full-body detector found 1 of ~21 people (the man in
  the Spinoza photo); `upperBodyOnly` found 6–7; faces 3 of 4 clearly visible ones. See M1-T06.

## M1-T06 Person detector recall

Labeled set: 200 COCO val2017 images with 937 person boxes, restricted to permissive Flickr licenses (COCO license ids
4 CC BY 2.0, 5 CC BY-SA 2.0, 7 no known copyright restrictions); annotations CC BY 4.0. Tags derived automatically by
`Bench/build_manifest.py`: `small` (box height < 80 px at original size), `crowd` (iscrowd = 1), `back` (keypoints:
both shoulders visible, nose and eyes not), `partial` (box touches an image border). The rig adds `large` (GT height
≥ 50 % of image height) and `medium` (20–50 %). Selection is deterministic (≥ 30 images per tag, then fill by id).

Rules: each image resized so the long side is 1280, then 1920 (COCO images are ~640 px, so this is a 2–3x upscale).
GT bodies count when height ≥ 40 px at that scale and iscrowd = 0. Matching is one-to-one greedy by confidence:
- `full` (upperBodyOnly = false): IoU ≥ 0.5, also reported at IoU ≥ 0.3.
- `upper` (upperBodyOnly = true): its boxes cover head + torso, so IoU against a full-body GT is meaningless. Match =
  detection center inside the GT box and detection area ≥ 30 % of GT area (smallest containing GT wins).
- `pose` (`DetectHumanBodyPoseRequest`, extra native candidate): box = hull of joints with confidence > 0.1, center rule.
- `union` = full (IoU 0.5) or upper (center rule): what "full body with upper-body fallback" would give. `union3` adds pose.
- `crowd` regions (30) are reported separately as "covered": ≥ 1 full-body detection center inside the region.
- `all_1280set` = the bodies eligible at 1280, so the 1920 row compares the same bodies (at 1920 the ≥ 40 px rule admits
  63 more tiny people).

Recall, % (hit/total), 200 images — identical detections at 1280 and 1920 unless noted:

| config  | match             | all 1280        | all 1920        | large       | medium      | small (<80 px) | back      | partial    |
|---------|-------------------|-----------------|-----------------|-------------|-------------|----------------|-----------|------------|
| full    | IoU ≥ 0.5         | 25.8 (205/796)  | 23.9 (205/859)  | 67.8 (101/149) | 40.7 (90/221) | 1.6 (6/384)  | 43.5 (37/85) | 41.2 (47/114) |
| full    | IoU ≥ 0.3         | 26.8 (213/796)  | 24.8 (213/859)  | —           | —           | 1.8            | 44.7      | 43.0       |
| upper   | center + 30 % area| 28.1 (224/796)  | 26.0 (223/859)  | 57.7 (86/149)  | 45.2 (100/221) | 5.7 (22/384) | 44.7 (38/85) | 41.2 (47/114) |
| pose    | center + 30 % area| 16.6 (132/796)  | 16.1 (138/859)  | 54.4        | 23.1        | 0.0            | 22.4      | 21.9       |
| union   | full ∪ upper      | 37.8 (301/796)  | 35.0 (301/859)  | 79.2 (118/149) | 64.3 (142/221) | 6.0 (23/384) | 63.5 (54/85) | 53.5 (61/114) |
| union3  | full ∪ upper ∪ pose | 38.3 (305/796) | 35.4 (304/859) | 81.2 (121/149) | 64.7 (143/221) | 6.0          | 64.7      | 53.5       |
| crowd   | region covered    | 16.7 (5/30)     | 20.0 (6/30)     |             |             |                |           |            |

Per-tag columns are from the 1280 run; the 1920 run differs by at most 2 hits per cell (`all_1280set` at 1920:
full 25.8, upper 28.0, union 37.8). Per-image cost on these CGImage inputs at 1280 (noisy): full p50 18.6 / p95 35.9 ms,
upper 18.2 / 51.5 ms, pose 32.0 / 73.3 ms.

Sanity check of the rig: the fixture test (`Tests/SitrDetectTests/DetectorTests.swift`) passes with the detected box
within 5 % of a hand-checked box, and `--dump` overlays (GT green, full red, upper blue) show GT landing on the people and
detections aligned with them. The misses are real: a tennis player mid-stroke, a crouching catcher, a pitcher cut off at
the top, the second of two overlapping baseball players, a line judge, background people — all undetected by `full`.

Reading it:
- Vision's full-body detector is a "prominent upright person" detector: 68 % on people taller than half the image,
  41 % on medium people, ~0 % under 80 px (original) even after upscaling. `upperBodyOnly` helps on partial bodies;
  the union reaches 79 % on large people and 38 % overall. Body pose adds < 1 point at twice the cost.
- Recall is identical at 1280 and 1920: Vision downsizes internally, so a higher capture side buys nothing here.
  Choose the capture long side on capture/render cost (M1-T07/T08), not on detection.
- Caveat: COCO images are upscaled 2–3x and softer than screen content, but the composite frame (sharp photos at
  realistic on-screen sizes) shows the same behaviour (1 of ~21 people), so the gap is not an artefact of the set.

## Detector decision (input for M1-T09)

Vision `DetectHumanRectanglesRequest` misses the PRD target (recall ≥ 95 % for bodies ≥ 40 px) by a wide margin:
25.8 % full body, 37.8 % with the upper-body fallback, 81 % even when restricted to large people with every native
request combined. No Vision configuration reaches the 85 % no-go floor either, so the no-go question moves to the
permissive CoreML detectors — this spike did not convert one (per the task).

Recommended next step (before M2-T06 is finalised): evaluate, in this order, on the same manifest with the same rig
(`--detector` flag + a `CoreMLPersonDetector` producing `[Detection]`):
1. **YOLOX** (Apache-2.0; official COCO weights, ONNX → coremltools fp16; person class only). YOLOX-S at 640 is the
   likely sweet spot for the ANE; YOLOX-Tiny/Nano if cost matters more than small-person recall.
2. **RF-DETR** (Apache-2.0) if YOLOX falls short on medium/occluded people; heavier, ANE support to be checked.
3. **NanoDet-Plus** (Apache-2.0) as the low-power fallback.
Ultralytics YOLO stays excluded (AGPL). Gate: ≥ 95 % overall on `all_1280set`, ≥ 90 % `medium`; `small` reported, not
gated (a 40 px body in a 1280 capture is a 20 px person in the network input at 640 — tiling or dirty-rect ROI later).
Keep the Vision `PersonDetector` (`upperBodyOnly` configurable) and `FaceDetector` as the zero-dependency baseline and
for faces; the recall rig accepts any `[Detection]` source, so the comparison is a drop-in.

## Files
- `Sources/SitrCore/Geometry.swift` — `Rect`/`Size`, IoU, Vision-normalized → capture pixels → display points.
- `Sources/SitrDetect/{SitrDetect,PersonDetector,FaceDetector}.swift` — `Detection`, Vision wrappers (CGImage and
  CVPixelBuffer paths), `detectPersonsAndFaces` on one handler, compute-device note.
- `Sources/SitrSpike/DetectCost.swift`, `Sources/SitrSpike/Recall.swift` — the rigs (+ shared `Rig` helpers).
- `Bench/build_manifest.py`, `Bench/download.py`, `Bench/recall/manifest.json`, `Bench/ATTRIBUTIONS.md`.
- `Tests/SitrCoreTests/GeometryTests.swift`, `Tests/SitrDetectTests/DetectorTests.swift` + `Fixtures/`.

## CoreML detector (M1-T06b)

Follow-up to the decision above: YOLOX (Megvii, Apache-2.0) converted to CoreML and scored on the same manifest with
the same rig (`--detector coreml:<model>`, IoU ≥ 0.5 one-to-one, GT ≥ 40 px, crowd = region covered). Machine: Apple
M3, 24 GB, macOS 26.6.2. Numbers are **preliminary/noisy**: other agents were training a classifier and running a
CoreML eval during every run (load average 5–76 on 8 cores), so ms/frame is inflated and must be re-taken in the quiet
phase; recall is deterministic and unaffected. Conversion notes: `Models/detector/README.md`.

### Reproduce
```
Models/venv/bin/python Models/detector/convert_yolox.py --fetch                                     # source + weights (gitignored)
Models/venv/bin/python Models/detector/convert_yolox.py --models tiny,s,m --sizes 640x384,1280x768  # -> Models/work/out/*.mlpackage, verified
swift run -c release sitr-spike recall Bench/recall/manifest.json --detector coreml:Models/dist/PersonDetector.mlpackage
swift run -c release sitr-spike detect --detector coreml:Models/dist/PersonDetector.mlpackage --n 200 --sides 1280,2560
swift test --filter CoreMLPersonDetector      # fixture within 5 % of the hand-checked box; skips if Models/dist has no model
```

### Models
YOLOX tiny / s / m, official COCO train2017 weights (release 0.1.1rc0), source tag 0.3.0, `decode_in_inference` on,
ML Program fp16, image input (raw 0–255 **BGR**, 114-grey letterbox top-left, as YOLOX's `ValTransform`), output
`[1, N, 85]` float32. Two input sizes each, 640×384 and 1280×768 (both /32, 5:3 like the screen), as separate packages
(`EnumeratedShapes` not tried; fixed shapes are the safe ANE path). Two conversion fixes, both exact: the head's in-place
slice writes (`outputs[..., :2] = …`) are rewritten as a concat because coremltools 9 rejects them, and the SPP 9×9 /
13×13 max pools become 2× / 3× stacked 5×5 pools — CoreML scheduled the big pools on the CPU (2 of 212 ops, two
ANE→CPU→ANE hops per frame); after the rewrite `MLComputePlan` puts all 212 ops on the Neural Engine
(`spp_rewrite_diff = 0` in PyTorch). Package sizes: tiny 10.3 MB, s 18.2 MB, m 50.8 MB.

Conversion verification (CoreML fp16 on the ANE vs PyTorch fp32, `Tests/SitrDetectTests/Fixtures/person.jpg`, rows with
person score ≥ 0.3; box diff in network-input pixels):

| model | input    | rows torch / coreml | max abs box diff | max abs score diff | top box torch → coreml (x,y,w,h in source px; score) |
|-------|----------|---------------------|------------------|--------------------|------------------------------------------------------|
| tiny  | 640×384  | 8 / 9   | 0.79 px | 0.0033 | 260,102,124,321 0.900 → 260,102,124,322 0.897 |
| tiny  | 1280×768 | 8 / 9   | 1.75 px | 0.0029 | 261,109,124,308 0.891 → 261,109,124,308 0.890 |
| s     | 640×384  | 10 / 10 | 1.21 px | 0.0431 | 258,111,123,313 0.924 → 258,111,123,312 0.923 |
| s     | 1280×768 | 9 / 9   | 1.48 px | 0.0058 | 258,108,125,313 0.891 → 258,108,125,313 0.889 |
| m     | 640×384  | 9 / 9   | 0.93 px | 0.0019 | 258,107,123,316 0.934 → 258,107,123,316 0.933 |
| m     | 1280×768 | 9 / 9   | 1.56 px | 0.0018 | 261,110,120,310 0.928 → 261,111,120,310 0.926 |

The hand-checked fixture box is 262,112,123,314; every variant lands inside the 5 % tolerance of `DetectorTests`.

### Swift side
`Sources/SitrDetect/CoreMLPersonDetector.swift`: `MLModel(contentsOf:)` (compiles an `.mlpackage` on the fly, ~1–2 s;
the app should ship the compiled `.mlmodelc`), `computeUnits` configurable, CoreImage letterbox (Lanczos downscale,
114-grey canvas, top-left, no colour management) straight from the SCStream `CVPixelBuffer` or a `CGImage` into a pooled
IOSurface buffer, person = class 0 with score = objectness × class ≥ 0.30, greedy NMS IoU 0.5, un-letterbox to source
pixels, returns `[Detection]` like the Vision wrappers.

### Recall, % (hit/total), 200 images, side 1280, IoU ≥ 0.5, threshold 0.30
Vision rows repeated from above for comparison. `small` = GT height < 80 px in the original ~640 px photo (20–40 px
bodies after the ×2 resize, i.e. the hardest 48 % of the set); `crowd` = region covered.

| detector          | all             | large          | medium         | small          | back         | partial       | crowd (covered) |
|-------------------|-----------------|----------------|----------------|----------------|--------------|---------------|-----------------|
| Vision full       | 25.8 (205/796)  | 67.8 (101/149) | 40.7 (90/221)  | 1.6 (6/384)    | 43.5 (37/85) | 41.2 (47/114) | 16.7 (5/30)     |
| Vision full∪upper | 37.8 (301/796)  | 79.2 (118/149) | 64.3 (142/221) | 6.0 (23/384)   | 63.5 (54/85) | 53.5 (61/114) | —               |
| YOLOX-tiny 640×384  | 71.0 (565/796) | 94.0 (140/149) | 88.7 (196/221) | 51.6 (198/384) | 89.4 (76/85) | 82.5 (94/114) | 93.3 (28/30) |
| YOLOX-tiny 1280×768 | 78.9 (628/796) | 89.3 (133/149) | 87.8 (194/221) | 69.5 (267/384) | 89.4 (76/85) | 80.7 (92/114) | 96.7 (29/30) |
| YOLOX-s 640×384     | 72.2 (575/796) | 96.6 (144/149) | 87.8 (194/221) | 53.4 (205/384) | 91.8 (78/85) | 81.6 (93/114) | 86.7 (26/30) |
| **YOLOX-s 1280×768** | **85.1 (677/796)** | 93.3 (139/149) | **90.5 (200/221)** | 78.4 (301/384) | 91.8 (78/85) | 83.3 (95/114) | 96.7 (29/30) |
| YOLOX-m 640×384     | 76.0 (605/796) | 98.0 (146/149) | 92.3 (204/221) | 57.3 (220/384) | 96.5 (82/85) | 86.8 (99/114) | 90.0 (27/30) |
| YOLOX-m 1280×768    | 87.1 (693/796) | 94.6 (141/149) | 93.2 (206/221) | 80.5 (309/384) | 97.6 (83/85) | 87.7 (100/114) | 96.7 (29/30) |

At IoU ≥ 0.3 (looser box): all 74.6 / 82.0 / 74.5 / 87.8 / 77.6 / 89.6 in the same row order; medium 94.1 / 90.0 /
91.9 / 93.2 / 94.6 / 94.6. Side 1920 gives the same detections (`all_1280set` within ±1 hit of the 1280 run for every
variant; `all` over the 859 bodies eligible at 1920: 66.7 / 77.1 / 67.6 / 82.7 / 71.5 / 85.0) — as with Vision the
capture side is not a recall lever, the network input size is.

Reading it:
- Every YOLOX variant is 2–3× Vision; the miss pattern that sank Vision (mid-stroke, crouching, cut-off, overlapping,
  background people) is gone: medium 88–93 %, back 89–98 %, partial 81–88 %, 27–29 of 30 crowd regions covered.
- The gap to 95 % is entirely small people. Input size is the lever: 640×384 shows a 40 px body (capture scale) as a
  16–20 px blob and stalls at 51–57 % small; 1280×768 keeps it at ≥ 32 px and lifts small to 70–81 %, all to 79–87 %.
  Model size buys much less (tiny → s → m at 1280: +6.2, +2.0 points overall).
- Large people dip 3–5 points at 1280 (a person taller than half the frame exceeds YOLOX's 640-training scale). Not a
  floor issue; upgrade path if it matters: a second 640 pass or a dual-scale model.
- Composite 2560×1664 frame (`sitr-spike detect`, ~21 visible people): s 1280×768 finds 22, tiny 640×384 finds 19;
  Vision found 1 (full) / 6–7 (upper).

### Cost, ms/frame on the composite frame (200 warm runs, IOSurface BGRA input, letterbox + prediction + NMS)
Composite 2560×1664 frame (~21 visible people) as an IOSurface BGRA buffer, fed at side 2560 (native) and 1280, 5 warm-up
+ 200 timed runs per cell, release build; time = CoreImage letterbox + `MLModel.prediction` + NMS. `all` =
`MLComputeUnits.all`, `ane` = `.cpuAndNeuralEngine` (same placement: every op is on the ANE either way). `min` is the
best of 200 and approximates the uncontended cost; p50/p95 carry the load of the other agents' jobs (load average
3–14 while these ran) and are what the quiet phase must redo. Load = `CoreMLPersonDetector.init` on the `.mlpackage`,
i.e. compile + load (the app ships the compiled `.mlmodelc`, so only the load part remains).

| model, input        | units | side 1280 p50 / p95 / min ms | side 2560 p50 / p95 / min ms | found (~21) | load ms |
|---------------------|-------|------------------------------|------------------------------|-------------|---------|
| **s 1280×768**      | all   | 25.5 / 40.3 / 17.6           | 31.7 / 104.8 / 12.5          | 22          | 1687    |
| **s 1280×768**      | ane   | 24.3 / 49.6 / 17.4           | 23.8 / 60.7 / 19.2           | 22          | 3371    |
| tiny 1280×768       | all   | 22.9 / 74.4 / 10.1           | 26.3 / 96.1 / 13.5           | 22          | 2609    |
| tiny 1280×768       | ane   | 17.9 / 37.0 / 13.9           | 28.2 / 62.6 / 14.9           | 22          | 1751    |
| s 640×384           | all   | 16.7 / 42.1 / 5.0            | 9.1 / 33.9 / 6.2             | 17          | 2795    |
| s 640×384           | ane   | 9.7 / 44.6 / 4.2             | 13.5 / 20.6 / 7.6            | 17          | 2153    |
| tiny 640×384        | all   | 13.5 / 43.6 / 5.2            | 12.7 / 47.9 / 5.9            | 19          | 2316    |
| tiny 640×384        | ane   | 6.3 / 37.5 / 3.5             | 14.0 / 31.6 / 6.2            | 19          | 1497    |
| m 1280×768          | all   | 44.7 / 77.9 / 31.6           | 47.2 / 83.0 / 33.5           | 21          | 3071    |
| m 1280×768          | ane   | 44.2 / 76.1 / 29.5           | 46.5 / 104.2 / 30.3          | 21          | 2315    |
| m 640×384           | all   | 20.7 / 80.0 / 12.3           | 32.1 / 76.5 / 15.3           | 19          | 5351    |
| m 640×384           | ane   | 20.6 / 76.7 / 12.9           | 23.5 / 71.7 / 13.7           | 19          | 4817    |

Vision for reference (same frame, M1-T03): full body 11–16 ms p50, finding 1 person; upper body 8–12 ms, 6–7 persons.

**Quiet phase, shipped model only** (2026-09-06, load1 2.5–2.6, `.build/release/sitr-spike detect --detector
coreml:Models/dist/PersonDetector.mlpackage --n 200`; the tiny / m rows above stay preliminary):

| model, input | units | process | side 1280 p50 / p95 / min ms | side 2560 p50 / p95 / min ms | found | load ms |
|---|---|---|---|---|---|---|
| **s 1280×768** | **ane** | alone (`--units ane`, the app's configuration) | **15.2 / 16.9 / 11.7** | – | 22 | 1056 |
| s 1280×768 | all | first model in the process | 19.2 / 21.9 / 15.9 | 25.1 / 73.1 / 20.0 | 22 | 1765 |
| s 1280×768 | ane | second model in the same process (after `all`) | 23.4 / 34.3 / 17.6 | 25.1 / 59.7 / 21.2 | 22 | 3387 |

Reading it:
- s 1280×768 on the Neural Engine alone costs **15.2 / 16.9 ms p50 / p95** per frame (floor 11.7 ms) on a quiet M3: the 30 ms
  p95 budget holds with margin; the preliminary 24–32 ms p50 / 40–105 ms p95 were contention. M1 8 GB is pending.
  m 1280×768 has a 30 ms *floor* (p50 45 ms, preliminary), so it stays out on cost as well as size.
- Two CoreML models loaded in one process share the ANE: the second one measures 1.5× slower (23 ms p50, 34 ms p95) and the
  side-2560 rows show 60–70 ms p95 tails. The app loads two models (detector + classifier) plus Vision faces, so its own
  `detect_ms` (docs/spike/system.md: 17–18 ms p50 at 15 fps) is the number that counts for the budget, not the rig's.
- Vision-style `.all` is not faster here (19 ms vs 15 ms): keep `.cpuAndNeuralEngine`.
- Before the SPP rewrite the same s 1280×768 measured p50 132–185 ms under load 5–37: two CPU-scheduled ops in the
  middle of the network cost far more than their FLOPs when the CPU is busy. Keep every op on the ANE.
- The capture side barely matters (1280 vs 2560: same p50 within noise): the Lanczos letterbox on the GPU is cheap
  next to the network, so the capture side can follow render/latency cost (M1-T07/T08).
- Per-image cost inside the recall rig (CGImage path, 200 different images, load 7–14): s 1280×768 p50 38 ms, tiny
  1280×768 p50 29 ms — the CGImage → CoreImage upload adds ~10 ms over the IOSurface path; the app uses the buffer path.

### Decision (input for M1-T09 / M2-T06)
- **No variant reaches the PRD gate of 95 % overall on this COCO set**; best achievable is 87.1 % (m, 1280×768,
  50.8 MB) and 85.1 % (s, 1280×768, 18.2 MB). The shortfall is small people (COCO's 20–40 px bodies), where even m
  stops at 80.5 %; medium and larger bodies are at 90–98 %.
- **Ship YOLOX-s at 1280×768** (`Models/dist/PersonDetector.mlpackage`, 18.2 MB): the smallest variant that clears the
  M1 no-go floor (all ≥ 85 %, medium ≥ 90 %), 3.3× Vision overall, 2.2× Vision's union; m adds 2 points for 2.8× the
  weights (over the 40 MB budget) and roughly 2.5× the compute; tiny at 1280×768 (78.9 %) misses the floor.
- **Input size for M2: 1280×768** (network), fed from whatever capture side render cost prefers — recall does not depend
  on the capture side. If the quiet-phase ANE cost of s 1280×768 exceeds the 30 ms p95 budget, the fallbacks in order
  are: detect every other frame (the Tracker persists 300 ms), a 960×576 build (untested, `--sizes 960x576`), then
  tiny 1280×768 (78.9 %, below the floor, so Strict Mode / pre-cover would have to compensate).
- PRD delta to record in M1-T09: "recall ≥ 95 % for bodies ≥ 40 px" is not met by any permissive detector at this size
  budget on COCO-style photos; propose re-basing the gate on bodies ≥ 64 px at capture scale or accepting 85 % overall
  with medium ≥ 90 %. RF-DETR / NanoDet were not evaluated: YOLOX already clears the floor, and both would face the same
  small-person ceiling at 1280×768.
- Keep Vision `FaceDetector` for faces; drop the Vision person path from the pipeline once M2-T06 lands the CoreML one.

### Files
- `Models/detector/convert_yolox.py`, `Models/detector/README.md` — fetch, convert, verify, ship.
- `Models/dist/PersonDetector.mlpackage` + `LICENSE-YOLOX.txt`, `SOURCE-PersonDetector.md`, `CHECKSUMS-PersonDetector.txt`.
- `Sources/SitrDetect/CoreMLPersonDetector.swift`; `--detector coreml:` in `Sources/SitrSpike/{Recall,DetectCost}.swift`.
- `Tests/SitrDetectTests/CoreMLPersonDetectorTests.swift` — fixture within 5 %, pixel-buffer parity, NMS.
