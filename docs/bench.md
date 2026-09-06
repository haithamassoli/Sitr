# Bench report (M4-T08): `sitr-bench` on the full labeled sets

Machine: Apple M3, 24 GB, macOS 26.6.2, Xcode 26.6, release build (`swift build -c release`). Run on 2026-09-06 with other
agents building and downloading throughout — **load average 5–9 on 8 cores during every run**, so every ms number below is
noisy (`noisy=true` in the output) and must be re-taken in a quiet phase; recall and classification are deterministic and
unaffected. How the bench works and the labels format: `Bench/README.md`.

## Reproduce
```
python3 Bench/download.py --labels Bench/labels/recall-coco.json      # 200 COCO val2017 images  (Bench/data/recall/)
python3 Bench/download.py --labels Bench/labels/faces-commons.json    # 458 Commons portraits    (Bench/data/faces/)
swift run -c release sitr-bench Bench/labels/recall-coco.json  [--json out.json]
swift run -c release sitr-bench Bench/labels/faces-commons.json [--json out.json]
swift run sitr-bench --selfcheck                                      # metric math on synthetic detections: "selfcheck ok"
```
Per image the bench runs the app's per-frame path: frame with the long side 1280 → `CoreMLPersonDetector` (YOLOX-s
1280×768, threshold 0.30, NMS 0.5) → Vision faces → face → person by largest overlap → `GenderClassifier` (shipped crop rule,
every face ≥ 32 px on a body ≥ 40 px) → `categorize`. Matching mirrors `Sources/SitrSpike/Recall.swift` (one-to-one greedy,
IoU ≥ 0.5, GT ≥ 40 px tall, crowd regions excluded). Both models on `.cpuAndNeuralEngine`, like the app.

## PRD gates
| Gate (PRD "Performance and quality targets") | Result | Status |
|---|---|---|
| Person recall, body ≥ 40 px, benchmark set ≥ 95 % | **84.5 %** (673/796) on COCO; ≥ 80 px 88.5 %; large+medium 91.6 % | **not met** — small people |
| Hidden-category person shown due to misclassification ≤ 2 % at the default threshold | **5.6 %** (14/252) on the Commons faces at 0.80; 5.7 % at 0.85, 5.4 % at 0.90 | **not met** — threshold is not the lever |
| Unknown rate (reported, not gated) | COCO 81.6 % of matched persons (537/673 have no detectable face); Commons faces 9.7 % | reported |

## Recall — `Bench/labels/recall-coco.json` (200 images, 937 boxes, 796 eligible at ≥ 40 px, 30 crowd regions excluded)
| tag | GT | recall % (hit/total) | Unknown % of matched |
|---|---|---|---|
| all | 796 | **84.5** (673/796) | 81.6 |
| ≥ 80 px at 1280 | 620 | 88.5 (549/620) | 77.4 |
| large (≥ 50 % of frame height) | 149 | 93.3 (139/149) | 41.0 |
| medium (20–50 %) | 221 | 90.5 (200/221) | 83.0 |
| large + medium | 370 | 91.6 (339/370) | 65.8 |
| small (< 80 px in the ~640 px original) | 384 | 77.6 (298/384) | 99.0 |
| back | 85 | 91.8 (78/85) | 96.2 |
| partial | 114 | 83.3 (95/114) | 71.6 |
| drawn | — | n/a (no labeled drawn-people set) | — |

Against the spike's numbers for the same model (docs/spike/detect.md: all 85.1, large 93.3, medium 90.5, small 78.4, back
91.8, partial 83.3): identical on large/medium/back/partial, 4 boxes lower overall (673 vs 677, all of them `small`). The
spike resized with a CGContext (`.medium` interpolation) and fed a `CGImage`; the bench resizes with Lanczos into a BGRA
pixel buffer, the app's input path, and a handful of 20–40 px people flip either way. Unknown reasons over the 673 matched
persons: no face 537, face < 32 px 0, body < 40 px 0, confidence below 0.80 12 — COCO people are small, far or turned away,
so in the app they are Unknown and covered only under Strict Mode / Everyone.

## Classification — `Bench/labels/faces-commons.json` (488 entries over 458 files; 279 matched)
The person box is the whole image, so the IoU ≥ 0.5 match doubles as the single-portrait filter: 209 labeled entries stay
unmatched (162 of them `hijab`, mostly event/group photos where no single box covers half the frame — the spike dropped 142
of the same 280 for having ≠ 1 face). Misclassification = predicted as the other gender / labeled persons whose predicted
category is not Unknown; Unknown % over matched persons.

| tag | labeled | matched | Unknown % | known | wrong | **misclass %** | labeled missed |
|---|---|---|---|---|---|---|---|
| all | 488 | 279 | 9.7 | 252 | 14 | **5.6** | 209 |
| general | 80 | 65 | 6.2 | 61 | 3 | 4.9 | 15 |
| hijab | 280 | 118 | 7.6 | 109 | 5 | 4.6 | 162 |
| child | 50 | 36 | 16.7 | 30 | 1 | 3.3 | 14 |
| low-light (synthetic) | 30 | 22 | 0.0 | 22 | 2 | 9.1 | 8 |
| profile | 48 | 38 | 21.1 | 30 | 3 | 10.0 | 10 |
| drawn | — | — | — | — | — | n/a (no data) | — |

Unknown threshold sweep (tag = all), the decision input for the PRD's threshold:

| threshold | known | wrong | misclass % | Unknown % |
|---|---|---|---|---|
| 0.80 (default) | 252 | 14 | 5.6 | 9.7 |
| 0.85 | 247 | 14 | 5.7 | 11.5 |
| 0.90 | 241 | 13 | 5.4 | 13.6 |

Reading it:
- 5.6 % matches the spike's classifier-only number on the same faces (5.6 %, docs/spike/classifier.md), so the app's crop,
  resize and pixel-buffer path add no error; the classifier itself is the ceiling.
- **Raising the threshold does not buy the gate**: 13 of the 14 errors survive at 0.90 because they are confident (P ≥ 0.90 for
  the wrong class) while the Unknown rate climbs from 9.7 to 13.6 %. Keep 0.80; the ≤ 2 % gate needs a better classifier
  (docs/spike/classifier.md follow-up: fine-tune the MobileNetV3 on all FairFace shards, or a larger eval to re-check ViT) —
  temporal voting in the Tracker will not fix a face that is confidently wrong in every frame.
- Unknown reasons over the 279 matched: no face 13 (Vision misses strong profiles and occluded faces), face < 32 px 0,
  body < 40 px 0, confidence below 0.80 14.
- Weak spots agree with the spike: profile 10 % / 21 % Unknown, synthetic low-light 9.1 %, children 16.7 % Unknown.
- The 9 errors in single-person frames (the other 5 sit in frames with several detections): `commons_100894451` (woman → man,
  also as its darkened copy), `commons_100887582` (darkened copy only), `commons_112431372` (boy → woman),
  `commons_25276646`, `commons_25286173`, `commons_37005313` (profile women → man), `commons_60121066` (woman → man),
  `commons_64144760` (hijab, woman → man). Four were inspected: a short-haired older woman, a woman with cropped hair, a woman
  half hidden behind plants, a boy in a helmet — real classifier errors on hard cases, not label noise.

## Cost, ms per image (release build, `.cpuAndNeuralEngine`, other agents running — noisy)
| run | load1 | detect p50 / p95 | faces p50 / p95 | classify per image p50 / p95 (n) | classify per crop p50 / p95 |
|---|---|---|---|---|---|
| recall-coco (200 frames 1280×~850) | 5.9–9.8 | 15.8 / 46.8 | 6.8 / 25.8 | 11.4 / 45.0 (87) | 7.3 / 22.7 |
| faces-commons (488 frames, mostly portrait ~960×1280) | 5.2–7.1 | 31.4 / 96.5 | 12.7 / 36.6 | 21.0 / 130.1 (445) | 18.1 / 52.9 |

The COCO run matches the spike's floor (detector 12–19 ms, classifier 8–10 ms per crop); the faces run started while another
agent's build ran and is 2× slower across every stage, which is contention, not the portrait orientation (the letterbox makes
portrait frames cheaper, not dearer). Detector and faces are timed one after the other here; the app runs them concurrently.
Quiet-phase numbers and the M1 8 GB baseline are pending, as for every other rig.

## Shortcuts and assumptions (`ponytail:` markers in `Sources/SitrBench/main.swift`, `Bench/download.py`)
- faces-commons person box = the whole image (the manifest has no boxes); recall on that set is therefore only the
  single-portrait match rate (57.2 %), not a detector number — use the COCO set for recall.
- `low-light` is synthetic (gamma 2.2, then ×0.35), applied by the bench to the frame after the resize; the spike darkened the
  800 px file and re-encoded it as JPEG, so the pixels differ slightly.
- The 40 FairFace child rows of the eval manifest are not in the labels (no URL; they need the Python venv), so `child` is
  the 50 Commons portraits of girls and boys.
- Every classifiable face is classified; the app caps at 3 per frame and catches up on later frames.
- Detector and faces timed sequentially (the app overlaps them). Models come from `Models/dist` relative to the cwd, else
  from the checkout via `#filePath`; `.mlpackage` is compiled once into the temp dir (keyed by the manifest mtime).
- `Bench/download.py` now reports and skips a file that fails instead of aborting the run (exit code 1 if anything is
  missing), so CI can run on a partial download.
- CI (`.github/workflows/ci.yml`): after the unit tests, download the first 20 entries of `faces-commons.json` (20 s per
  file); if nothing arrived print `::notice::bench smoke skipped (network)` and exit 0; otherwise run `--selfcheck` and the
  bench with `--limit 20` — a crash or 0 images processed fails the step (exit 1).
