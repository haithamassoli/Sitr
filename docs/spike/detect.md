# Spike notes: detection cost (M1-T03) and person recall (M1-T06)

Machine: Apple M3, 24 GB, macOS 26.6.2, Xcode 26.6, Vision `DetectHumanRectanglesRequest` revision 2. M1 8 GB: pending.
Numbers below are **preliminary/noisy** (other agents were building in parallel); re-run in the quiet phase with the
commands in "Reproduce". The rigs print one parseable line per metric (`detect_ms …`, `recall …`, `recall_ms …`).

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

| config       | 1280 p50 / p95 ms | 1920 p50 / p95 ms | 2560 p50 / p95 ms | found (of ~21 people / 4 clear faces) |
|--------------|-------------------|-------------------|-------------------|-----------------------|
| full body    | 14.0 / 24.1       | 11.1 / 15.8       | 15.9 / 26.6       | 1 person              |
| upperBodyOnly| 12.4 / 20.5       |  8.4 / 10.7       |  9.6 / 10.7       | 6–7 persons           |
| faces        | 21.6 / 39.1       | 10.0 / 11.1       | 23.3 / 45.3       | 3 faces               |
| full + faces | 22.7 / 34.3       | 10.9 / 21.7       | 11.7 / 21.8       | 1 + 3                 |

M1 (8 GB): pending.

Reading it:
- Cost is flat in input size (1280 ≈ 1920 ≈ 2560): Vision resizes to its own network input, so the capture long side is
  not a detection-cost lever. The 1280-vs-1920 differences above are noise (1280 ran first, `thermalState` = fair).
- One frame of person + face detection costs 11–23 ms p50 on M3, well inside the 66 ms budget of 15 fps. Two requests
  on one handler cost about as much as the dearer request alone (shared preprocessing).
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
