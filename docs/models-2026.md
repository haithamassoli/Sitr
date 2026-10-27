# Models, October 2026: is there a better person detector or classifier for Sitr?

Question: are better models available for Sitr's blocking than YOLOX-S 1280×768 and the ViT-B/16 gender classifier, judged
in this order: recall on people, ANE latency, few false positives, a GPL-3-compatible license, every op on the ANE?
Machine: Apple M3 24 GB, **macOS 27.0.1**, release build, 2026-10-26. The machine was shared with another agent running
live capture tests, so `load1` is recorded on every latency number. Its load went from 3 to 270 twice during the session.
Recall and false-positive counts are deterministic and unaffected by load.

## Answer

- **Detector: switch to YOLOX-M at 1024×640 (fp16) with person threshold 0.25.** Same family, same Apache-2.0 license, same
  I/O contract, so it drops in with no Swift change. On the repo bench it raises recall for bodies ≥ 80 px from
  88.7 to **91.1 %**, which clears the PRD's 90 % gate for the first time. Overall recall goes from 84.7 to 87.2 %, large
  from 92.6 to 96.6 %, back views from 92.9 to 96.5 % and partial from 83.3 to 89.5 %. False positives go from 9 to 11
  on 200 person-free images. All 267 ops run on the ANE.
- **It is not faster.** Model-only p50 is 15.3–15.6 ms against 14.2–19.2 ms for the shipped model. The app-path detect
  stage is about 21 ms for both. YOLOX-M's tail is tighter: p95 16.5–16.8 ms against 17.4–22.5. Speed has to come from
  the pipeline (fps, frames skipped), not from the detector. No candidate is both faster and at least as accurate. The two
  fast ones (YOLOX-S 1024×640, about 9.7 ms, and YOLOv9-S, about 8.5 ms) lose recall at equal false positives (table B).
- **Classifier: keep the ViT-B/16 int8.** On macOS 27, 290 of its 292 ops run on the ANE at 4.5 / 5.3 ms p50 / p95 per
  crop, and the perf pass already classifies each track only once a second. The MobileNetV3 path is under-trained
  (78 % on Commons vs 93.7 %, docs/spike/classifier.md). Retraining it on all of FairFace (~87 k faces, hours of MPS
  time) was out of scope here, and it would only save about 4 ms per crop.
- **Size cost:** 49 MB instead of 17 MB. 8-bit palettization brings it to 25 MB with no recall loss (B), but adds 1–3 ms
  p50. Use it only if bundle size matters more than those milliseconds.

Drop-in candidate: `Models/work/candidate/PersonDetector.mlpackage` (= `Models/work/out/yolox_m_1024x640.mlpackage`).
Check it with `.build/release/sitr-bench Bench/labels/recall-coco.json --models <dir with it + GenderClassifier> --person-threshold 0.25`.

## A. Every candidate at the shipped settings (threshold 0.30, NMS 0.5, `sitr-bench`, the app's Swift path)

Recall is on `Bench/labels/recall-coco.json` (796 eligible bodies; ≥80 = bodies ≥ 80 px; small = < 80 px in the ~640 px
original). FP = person detections on 200 person-free COCO val2017 images (`fetch_negatives.py`), i.e. covers on scenes
with nobody in them. ANE ms = model-only `MLModel.prediction` from `anebench` (fixed IOSurface input, 200–300 runs,
`.cpuAndNeuralEngine`); ranges are p50 / p95 over interleaved rounds. "Ops on ANE" comes from `MLComputePlan`.

| Model | Input | License | Recall all / ≥80 / small % | FP /200 | ANE ms p50 / p95 | Ops on ANE | Size |
|---|---|---|---|---|---|---|---|
| **YOLOX-S (shipped)** | 1280×768 | Apache-2.0 | 84.7 / 88.7 / 77.9 | 9 | 14.2–19.2 / 17.4–22.5 ᵃ | 195/212 (decode tail on CPU) | 17 MB |
| YOLOX-S | 1024×640 | Apache-2.0 | 82.9 / 87.7 / 74.2 | 10 | 9.1–9.8 / 10.8–11.5 ᵇ | 212/212 | 17 MB |
| YOLOX-S | 960×576 | Apache-2.0 | 80.9 / 86.9 / 70.6 | 7 | 11.1 / 12.6 ᶜ | 212/212 | 17 MB |
| YOLOX-tiny | 1280×768 | Apache-2.0 | 79.0 / 84.8 / 70.6 | 17 | 23.7 / 28.0 ᶜ | 195/212 | 10 MB |
| YOLOX-tiny | 1024×640 | Apache-2.0 | 78.8 / 85.6 / 68.2 | 13 | 8.4 / 9.5 ᶜ | 212/212 | 10 MB |
| YOLOX-tiny | 960×576 | Apache-2.0 | 77.6 / 84.4 / 64.8 | 16 | 10.9 / 12.0 ᶜ | 212/212 | 10 MB |
| YOLOX-M | 1280×768 | Apache-2.0 | 87.3 / 91.1 / 81.8 | 11 | 30.6–38.0 / 32.8–42.7 ᵇ | 250/267 | 49 MB |
| **YOLOX-M** | **1024×640** | **Apache-2.0** | **86.1 / 90.2 / 78.1** (0.25: **87.2 / 91.1 / 79.7**) | **9** (0.25: **11**) | **15.3–15.6 / 16.5–16.8** ᵃ | **267/267** | **49 MB** |
| YOLOX-M pal8 | 1024×640 | Apache-2.0 | = fp16 ±0.5 (0.20: 88.1 / 91.5 / 81.5) | 13 @0.20 | 16.7–18.6 / 17.8–25.6 ᵃ | 267/267 | 25 MB |
| YOLOX-M int8 (linear) | 1024×640 | Apache-2.0 | 82.7 / 88.7 / 71.6 † | 9 † | 13.1 / 16.0 ᵈ | 267/267 | 24 MB |
| YOLOX-M | 960×576 | Apache-2.0 | 84.2 / 89.8 / 73.7 | 9 | 18.0–19.2 / 20.9–24.4 ᵇ | 267/267 | 49 MB |
| YOLOv9-S | 1024×640 | GPL-3.0 (official) / MIT (re-release, same weights) | 74.7 / 82.1 / 57.6 | 8 | 8.1–9.3 / 9.3–10.8 ᵃ | 480/480 | 14 MB |
| YOLOv9-S | 1280×768 | GPL-3.0 / MIT | 76.4 / 82.9 / 61.5 † | 10 † | 23.2 / 152 ᵉ | 553/567 | 14 MB |
| YOLOv9-M | 1024×640 | GPL-3.0 / MIT | 75.6 / 82.3 / 58.3 † | 6 † | 32.8 / 35.8 ᵉ | 399/399 | 39 MB |
| YOLOv9-M | 1280×768 | GPL-3.0 / MIT | 77.1 / 84.0 / 61.2 † | 8 † | 41.6 / 46.1 ᵉ | 385/399 | 39 MB |
| YOLOv9-T | – | GPL-3.0 / MIT | MIT weights score the fixture person 0.013: broken release, dropped | – | – | – | 5 MB |
| D-FINE-S (HF `ustc-community/dfine-small-coco`) | 1280×768 | Apache-2.0 | 82.9 / 88.2 / 73.4 | **46** | **232 / 303 (CPU)**; `.all`: 47 / 48 on GPU | **0/634** | 21 MB |
| RF-DETR-S (`rfdetr` 1.11.2) | 1024×640 | Apache-2.0 | not run (latency rules it out) | – | 93.2 / 102.2 | 649/657 | 56 MB |
| RF-DETR-S | 512×512 (native) | Apache-2.0 | not run (a 40 px body becomes 16 px) | – | 23.9 / 25.1 | 648/656 | 55 MB |

Load during the latency runs: ᵃ quiet interleaved run, 3 rounds × 300, load1 3.0–4.0. ᵇ interleaved, 3 rounds × 200,
load1 4.1–4.8. ᶜ single pass, load1 3.0 at the start. ᵈ single run, load1 ≈ 5.5. ᵉ single pass during which load1 rose
from 3.0 to 167; treat these as upper bounds. † from `pr_curve.py` (the Python mirror, below) rather than sitr-bench.

## B. At equal false positives (the fair comparison)

Score calibration differs between families: YOLOv9 has no objectness term and its scores run lower, and a DETR's 300
queries behave differently again. So a fixed 0.30 says little about the model itself. `pr_curve.py` scores every
threshold in one pass. It mirrors the bench (it lands within ~1 point: shipped model 83.8 / 88.4 / 76.3 with 9 FP,
against 84.7 / 88.7 / 77.9 with 9 FP in sitr-bench). Rows are picked at ~10 FP on 200 person-free images, the strict end
where the app runs. Rows marked "Swift" were re-run in sitr-bench.

| Model, input | Threshold | Recall all / ≥80 / small % | FP /200 |
|---|---|---|---|
| YOLOX-S 1280×768 (shipped) | 0.30 | 83.8 / 88.4 / 76.3 (Swift 84.7 / 88.7 / 77.9) | 9 |
| YOLOX-S 1280×768 (shipped, threshold only) | 0.20 | 86.9 / 90.3 / 81.5 (Swift 87.7 / 90.8 / 82.8; large 94.0, back 94.1, partial 86.0) | 15 |
| **YOLOX-M 1024×640** | **0.25** | 86.2 / 90.0 / 78.9 (**Swift 87.2 / 91.1 / 79.7; large 96.6, back 96.5, partial 89.5**) | 9 (Swift 11) |
| YOLOX-M 1024×640 | 0.20 | 87.4 / 91.0 / 81.0 (Swift 87.9 / 91.5 / 81.0) | 10 (Swift 13) |
| YOLOX-M 1024×640 pal8 | 0.20 | 87.2 / 90.8 / 80.7 | 10 |
| YOLOX-M 1024×640 int8 | 0.25 | 83.3 / 89.0 / 72.9 | 9 |
| YOLOX-M 1280×768 | 0.30 | 86.9 / 90.5 / 81.8 | 12 |
| YOLOX-M 960×576 | 0.25 | 85.9 / 90.3 / 76.8 | 11 |
| YOLOX-S 1024×640 | 0.30 | 83.2 / 87.9 / 73.7 | 11 |
| YOLOX-S 960×576 | 0.20 | 83.7 / 88.7 / 75.5 | 9 |
| YOLOX-tiny 1024×640 | 0.30 | 78.5 / 85.6 / 68.0 | 11 |
| YOLOv9-S 1024×640 | 0.25 | 77.4 / 84.0 / 62.2 | 13 |
| YOLOv9-M 1024×640 | 0.20 | 80.5 / 85.8 / 66.9 | 9 |
| YOLOv9-M 1280×768 | 0.20 | 81.9 / 86.8 / 69.8 | 11 |
| D-FINE-S 1280×768 | 0.40 | 74.6 / 80.5 / 60.4 | 16 |

Reading it:
- **YOLOX-M 1024×640 is the best model at the strict end.** At about the shipped false-positive count (11 vs 9 in
  sitr-bench) it gains 2.5 points overall and 2.4 on ≥ 80 px. Its biggest gains are where screen content lives: large +4.0, back views +3.6,
  partial +6.2 (Swift, 0.25 vs the shipped 0.30).
- **Lowering the shipped model's threshold to 0.20** (no model change) reaches similar overall and better small-body
  recall, but at 15 false positives against 11, and lower large/back/partial (94.0 / 94.1 / 86.0 vs 96.6 / 96.5 / 89.5).
  At ~20 false positives the two models are level: shipped at 0.15 gives 88.6 / 91.6 / 83.9 with 20 FP, M 1024 at 0.15
  gives 88.3 / 91.5 / 82.6 with 22 FP. M's advantage is fewer covers on non-people for the same recall.
- **1024×640 is a sweet spot for YOLOX-M, not just a cheaper size.** It equals 1280×768 at equal false positives
  (87.4 / 91.0 / 81.0 with 10 FP vs 86.9 / 90.5 / 81.8 with 12) for half the ANE time. YOLOX was trained at 640, and
  large people do better closer to that scale (large 96.6 vs 94.0).
- **YOLOv9 is the fastest per op but weak on small people.** It needs about twice the false positives to match YOLOX
  (S 1024 at 0.10: Swift 86.2 / 91.6 / 75.5 with 21 FP). The official GPL-3 weights and the MIT re-release produce
  identical curves, so this is the model, not a bad port.
- **D-FINE-S:** no op runs on the ANE, it is the worst on false positives (46 at 0.30, 138 at 0.20), and its recall is
  below YOLOX-S. It was trained on plain 640² resize, not a grey letterbox at 1280×768, but no input size fixes a 232 ms CPU model.

## C. Findings beyond the ranking

- **On macOS 27 the shipped model is no longer all-ANE.** `MLComputePlan` puts its 17-op decode tail (slice, exp, mul,
  concat on the [1, 20160, 85] output) on the CPU; docs/spike/detect.md recorded 212/212 on macOS 26.6. Every
  1280×768 model shows this (YOLOX-tiny/S/M: 195/212 and 250/267; YOLOv9 S/M: 14 ops), and every ≤ 1024×640 model stays
  fully on the ANE. That extra ANE→CPU hop is why the shipped model's p50 moved from 14 to 19 ms with load while
  YOLOX-M 1024 held at 15.3–15.6. Whichever model ships, check placement after OS updates
  (`Models/work/anebench <pkg> --n 50`).
- **Lanczos is not needed at 1024.** With a 1024-wide model and 1280 capture, the scale is 0.8, under the wrapper's
  `lanczosBelow` of 0.9, so the app would pay the Lanczos resample perf.md flagged as expensive. Bilinear
  (`--lanczos-below 0.75`) gave identical recall (87.2 / 91.1 / 79.7, 11 FP). Lowering `CoreMLPersonDetector.lanczosBelow`
  to 0.75 alongside the model swap is a one-line change, not made here. The bench's wall-clock detect stage showed no
  difference (21.2 vs 21.9 ms p50, load ~3.5); the cost perf.md saw was Core Image CPU samples, which this bench does
  not isolate.
- **App-path detect stage** (sitr-bench: letterbox + prediction + NMS, back to back, load1 2.9–3.7): shipped
  21.3 / 23.2 and 23.0 / 37.4 ms; YOLOX-M 1024 21.2 / 29.9 (Lanczos) and 21.9 / 31.5 (bilinear); YOLOv9-S 1024
  11.4 / 17.1.
- **Classifier placement:** `GenderClassifier.mlpackage` runs 290/292 ops on the ANE on macOS 27 (only an output `mul`
  and `cast` on the CPU), at 4.53 / 5.30 ms p50 / p95 alone (load1 ~5). perf.md's "parts on CPU through BNNS" no longer
  applies.

## D. Licenses and what was not tested

| Candidate | License | Verdict |
|---|---|---|
| YOLOX (Megvii) | Apache-2.0 | OK; already shipped (`Models/dist/LICENSE-YOLOX.txt`) |
| YOLOv9 official (WongKinYiu/yolov9) | GPL-3.0 | OK for a GPL-3 app |
| YOLOv9 re-release (MultimediaTechLab/YOLO, v1.0, by the YOLOv9 authors) | MIT | OK, but the README says "work in progress, not for production" and its v9-T release is broken |
| D-FINE, DEIM v1, RT-DETR/RT-DETRv2, RF-DETR N–L | Apache-2.0 | OK; RF-DETR XL/2XL are under Roboflow's PML 1.0 (not used) |
| **DEIMv2** (Intellindust) | **"DEIMv2 License": non-commercial only**, commercial use needs a separate license (LICENSE.md, 2026) | **Not GPL-3-compatible** (adds a restriction). Excluded, not measured |
| Ultralytics YOLOv8 / YOLO11 / YOLO26 | **AGPL-3.0** | Excluded, as in the M1 spike |

Not tested, and why:
- **RT-DETRv2-S:** same deformable decoder family as D-FINE, whose `grid_sample` → `resample` graph got 0 ANE ops
  here. That is inferred, not measured.
- **RTMDet-s** (Apache-2.0): needs the mmdet stack; a YOLOX-style conv detector with COCO AP 44.6 vs YOLOX-S 40.5. It is
  the one untested candidate that could plausibly beat YOLOX-M 1024 on recall at ANE speed. Worth a time-boxed pass if
  the 90 % gate on small bodies becomes the target.
- **Person-specific (CrowdHuman/MOT) weights**, e.g. ByteTrack's YOLOX: the code is MIT, but MOT17 is
  CC BY-NC-SA and CrowdHuman is non-commercial, so the weights' license is unclear. Skipped.

## E. Reproduce

```
/opt/homebrew/opt/python@3.12/bin/python3.12 -m venv Models/venv
Models/venv/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
Models/venv/bin/pip install coremltools numpy pillow opencv-python-headless loguru thop psutil tabulate transformers \
    huggingface_hub timm scipy onnx safetensors einops omegaconf hydra-core rich requests scikit-learn pyyaml ipython
swift build -c release --product sitr-bench
xcrun swiftc -O -swift-version 5 Models/detector/anebench.swift -o Models/work/anebench
python3 Bench/download.py --labels Bench/labels/recall-coco.json
python3 Models/detector/fetch_negatives.py                       # 200 person-free COCO val2017 images -> Models/work/neg/

# The recommended candidate (YOLOX 0.3.0 source + yolox_m.pth 0.1.1rc0, sha256 60076992b32da82951c90cfa7bd6ab70eba9eda243e08b940a396f60ac2d19b6)
Models/venv/bin/python Models/detector/convert_yolox.py --fetch
Models/venv/bin/python Models/detector/convert_yolox.py --models m --sizes 1024x640
#   verify model=m size=1024x640 rows_ref=10 rows_coreml=10 max_abs_diff_box_px=1.915 max_abs_diff_score=0.0713
#   top_ref=[x=259,y=110,w=123,h=313,score=0.940] top_coreml=[x=259,y=110,w=122,h=312,score=0.939]   (fixture box 262,112,123,314: inside 5 %)
#   To ship: `--models m --sizes 1024x640 --dist`, then update SOURCE-PersonDetector.md (weights yolox_m.pth) and the checksums.
# Optional 25 MB variant:
Models/venv/bin/python -c "import coremltools as ct; from coremltools.optimize.coreml import *; \
  m = ct.models.MLModel('Models/work/out/yolox_m_1024x640.mlpackage', skip_model_load=True); \
  palettize_weights(m, OptimizationConfig(global_config=OpPalettizerConfig(mode='kmeans', nbits=8, granularity='per_grouped_channel', group_size=16))).save('Models/work/out/yolox_m_1024x640_pal8.mlpackage')"

# Other candidates
Models/venv/bin/python Models/detector/convert_yolox.py --models tiny,s,m --sizes 960x576,1024x640,1280x768
Models/venv/bin/python Models/detector/convert_yolov9.py --model s --size 1024x640            # MIT re-release (clone + weights: see its docstring)
Models/venv/bin/python Models/detector/convert_yolov9.py --official --model s --size 1024x640 # GPL-3 official
Models/venv/bin/python Models/detector/convert_detr.py ustc-community/dfine-small-coco --size 1280x768 --revision f79e65b5fb
(v=$PWD/Models/venv/bin/python; cd /tmp && $v -c "from rfdetr import RFDETRSmall; RFDETRSmall().export(output_dir='.', format='coreml', shape=(640, 1024), coreml_precision='float16')")

# Measure
Models/detector/cand.sh <name> <pkg> [--person-threshold T] [--lanczos-below X]   # sitr-bench recall + FP, one summary line
Models/venv/bin/python Models/detector/pr_curve.py <pkg> [...]                   # recall vs FP at 11 thresholds
Models/work/anebench <pkg> --n 300 [--units ane|all]                              # MLComputePlan placement + model-only ms
```

Tools added (research only, the app is untouched): `Models/detector/anebench.swift` (placement and latency),
`pr_curve.py`, `cand.sh`, `fetch_negatives.py`, `convert_yolov9.py`, `convert_detr.py` and `ct_patches.py` (fixes for
three coremltools 9.0 torch-frontend errors: `int()` on a shape-[1] constant, `outer` mixing int32/fp32, `linear` with a
1-D weight). Toolchain: Python 3.12, torch 2.14.1 (CPU), coremltools 9.0, transformers 5.21.0, rfdetr 1.11.2, Xcode on
macOS 27.0.1.

## Sources
- [RF-DETR (ICLR 2026), Apache-2.0 N–L](https://github.com/roboflow/rf-detr) and [Roboflow's 2026 detector overview](https://blog.roboflow.com/best-object-detection-models/)
- [DEIMv2 paper, arXiv 2509.20787](https://arxiv.org/abs/2509.20787) and [repo + LICENSE.md](https://github.com/Intellindust-AI-Lab/DEIMv2)
- [D-FINE](https://github.com/Peterande/D-FINE), [DEIM](https://github.com/Intellindust-AI-Lab/DEIM), [RT-DETR](https://github.com/lyuwenyu/RT-DETR)
- [YOLOv9 official, GPL-3.0](https://github.com/WongKinYiu/yolov9) and [MIT re-release](https://github.com/MultimediaTechLab/YOLO)
- [YOLOX](https://github.com/Megvii-BaseDetection/YOLOX)
