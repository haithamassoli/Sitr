# Bench — labeled sets and the `sitr-bench` CLI (M4-T08)

Everything under `Bench/data/` is downloaded by script and gitignored; **no image is ever committed**. Licenses and
authors: `Bench/ATTRIBUTIONS.md` (COCO set) and `Models/eval/ATTRIBUTIONS.md` (Commons faces). Results: `docs/bench.md`.

## Run
```
python3 Bench/download.py --labels Bench/labels/recall-coco.json      # 200 COCO val2017 images  -> Bench/data/recall/
python3 Bench/download.py --labels Bench/labels/faces-commons.json    # 458 Commons portraits    -> Bench/data/faces/
swift run -c release sitr-bench Bench/labels/recall-coco.json         # person recall on COCO (no gender labels)
swift run -c release sitr-bench Bench/labels/faces-commons.json       # misclassification / Unknown on labeled faces
swift run sitr-bench --selfcheck                                      # metric math on synthetic detections
```
Options: `--images <dir>` (default: the labels file's `images_dir`), `--models <dir>` (default `Models/dist`; `.mlpackage`
is compiled once into the temp dir), `--threshold 0.80` (the Unknown threshold of the main table; 0.80/0.85/0.90 are always
reported as well), `--limit N`, `--json out.json`, `--verbose` (one line per image: counts and sizes only).
Exit code 1 when no image could be processed (download first), 2 on usage errors.

Layout: `Bench/labels/<set>.json` → images in `Bench/data/<set-dir>/` named by the labels' `file` field. `Bench/download.py
--labels` reads `url` and `images_dir` from the labels file, so any labels file in this format can be fetched and run.

## Labels format (`Bench/labels/*.json`, written by `Bench/convert_labels.py`)
```
{ "set": "recall-coco", "source": "...", "images_dir": "../data/recall", "tags": { "<tag>": "<meaning>" },
  "images": [ { "file": "000000000785.jpg", "url": "http://...", "license": "CC BY 2.0", "width": 640, "height": 425,
                "persons": [ { "box": [x, y, w, h], "category": "woman" | "man" | null, "tags": ["small", ...] } ],
                "darken": { "gamma": 2.2, "gain": 0.35 } } ] }            # optional, low-light entries only
```
Boxes are in pixels of the labeled image (top-left origin); the bench scales them to its 1280-px frame.

- `recall-coco.json` ← `Bench/recall/manifest.json` (COCO val2017 person boxes, CC BY 4.0 annotations, permissively
  licensed Flickr photos). 200 images, 937 boxes; tags `small` (box < 80 px tall at the ~640 px original), `crowd`
  (one box for a group; excluded from matching), `back` (keypoints: shoulders visible, face not), `partial` (touches a
  border). `category` is null: COCO has no gender labels.
- `faces-commons.json` ← `Models/eval/manifest.json` (M1-T05 Wikimedia Commons portraits, CC0 / CC BY / CC BY-SA; labels
  from the category names, never hand-labeled). 488 entries over 458 files: 80 general, 280 hijab, 50 child, 48 profile,
  30 low-light. **The person box is the whole image** — the manifest has no boxes; these are single-person portraits, and
  the IoU ≥ 0.5 match then acts as the single-portrait filter: in a group shot no box covers half the frame, the labeled
  person stays unmatched and is reported under "labeled missed" (the spike dropped those images the same way, by keeping
  only single-face images). `low-light` rows reuse the source file with `darken` (gamma 2.2, then ×0.35 — the spike's
  synthetic transform); the bench darkens the frame itself. The 40 FairFace child rows have no URL and are left out.

Regenerate with `python3 Bench/convert_labels.py` (stdlib; fetches any missing Commons file to read its size).

## What the bench does per image
Exactly the app's per-frame path (`Sources/Sitr/Pipeline/Pipeline.swift`, docs/m2/detect.md): the image becomes a BGRA
frame with the long side 1280 (Lanczos; EXIF orientation applied) → `CoreMLPersonDetector` (YOLOX-s 1280×768, threshold
0.30, NMS 0.5) → Vision `FaceDetector` → each face to the person it overlaps most → `GenderClassifier` on every face
≥ 32 px on a body ≥ 40 px (the app caps at 3 faces per frame and catches up on later frames; a still has none) → the
category rule (`categorize`: P ≥ t → woman, 1 − P ≥ t → man, else Unknown). Both models run on `.cpuAndNeuralEngine`
like the app.

Metrics (mirroring `Sources/SitrSpike/Recall.swift`): GT boxes scaled to the frame, non-crowd GT matched to detections
one-to-one greedily by confidence at IoU ≥ 0.5, tallied when ≥ 40 px tall. Derived tags: `ge80px` (GT ≥ 80 px), `large`
(≥ 50 % of the frame height), `medium` (20–50 %), `large+medium`, `general` (labeled, no dataset tag).
- **recall** = matched / eligible GT, per tag.
- **Unknown rate** = predicted Unknown / matched GT (labeled or not), with the reason split (no face, face < 32 px,
  body < 40 px, confidence below threshold).
- **misclassification** ("hidden-category person shown") = predicted as the other gender / labeled matched GT whose
  prediction is not Unknown. Also at 0.80 / 0.85 / 0.90 as input for the PRD's Unknown threshold.
- **ms per image**: detect, faces, classify (per image and per crop), p50/p95, plus the 1-minute load average
  (`noisy=true` above 4). `drawn` is printed as n/a: there is no labeled drawn-people set.

Output: a table plus one parseable line per number (`bench_images`, `bench_recall`, `bench_class`, `bench_thresholds`,
`bench_ms`); `--json` writes the same numbers. CI runs `--selfcheck` and the first 20 Commons faces as a smoke test
(`.github/workflows/ci.yml`); it skips with a notice when the images cannot be downloaded.
