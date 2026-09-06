# M1-T05 — Face-gender classifier: candidates, licenses, numbers, decision

Rig: `sitr-spike classifier` (`Sources/SitrSpike/Classifier.swift`); scripts and the shipped model in `Models/`
(`Models/README.md` has every command). Hardware: Apple M3, 24 GB, macOS 26.6.2, Xcode 26.6, coremltools 9.0.
Timing numbers below were taken while other jobs ran on the machine (downloads, Vision cropping) and are **noisy**;
they get re-measured in the quiet phase with `sitr-spike classifier --bench` (one `classifier_ms …` line per run).

## 1. License verdicts (weights AND training data must be Apache-2.0 / MIT / CC BY / CC0)

| Candidate | Weights | Training data | Verdict |
|---|---|---|---|
| `dima806/fairface_gender_image_detection` (ViT-B/16, HF rev `a8e129d`) | Apache-2.0 — model card front matter `license: apache-2.0`, `base_model: google/vit-base-patch16-224-in21k` (Apache-2.0) | FairFace (`datasets: nateraw/fairface`) — FairFace README: "License: CC BY 4.0"; HF dataset card `license: cc-by-4.0` | **accepted** |
| `crangana/trained-gender` (ResNet-50, HF rev `5cdda77`) | Apache-2.0 — card `license: apache-2.0`, `base_model: microsoft/resnet-50` (Apache-2.0) | FairFace (`datasets: fair_face`, config 0.25) — CC BY 4.0 as above | **accepted** |
| Home-grown Create ML classifier (this repo, `Models/train_createml.swift`) | Ours; Apple scene-print feature extractor ships with macOS and is used through the OS API | FairFace 1.25, CC BY 4.0 | **accepted** |
| Home-grown MobileNetV3-Large fine-tune (this repo, `Models/train_torch.py`) | Ours; backbone `timm/mobilenetv3_large_100.ra_in1k`, HF card `license: apache-2.0`, timm repo Apache-2.0 | FairFace 1.25, CC BY 4.0 | **accepted** |
| `vladmandic/human-models` `gender` + `gender-ssrnet-imdb` | MIT (repo LICENSE) | Human wiki "Models": "Gender Detection: Oarriaga Gender", "SSR-Net Gender (IMDB)". Both trained on IMDB-WIKI, whose page says: "Please notice that this dataset is made available for academic research purpose only." | **rejected** (training data) |
| SSR-Net (`shamangary/SSR-Net`) | Apache-2.0 (repo LICENSE) | README: "This repository is for IMDB, WIKI, and Morph2 datasets." IMDB-WIKI: academic research only; MORPH2 "requires application form" (commercial dataset) | **rejected** (training data) |
| Intel OMZ `age-gender-recognition-retail-0013` | Apache-2.0 (OMZ LICENSE) | Model card: "Validation Dataset - Internal … ~20,000 unique subjects", training set undisclosed; "not applicable for children since their faces were not in the training set" | **rejected** (training data not verifiable, no children) |
| `abhilash88/age-gender-prediction` (ViT) | Apache-2.0 | `datasets: UTKFace` — UTKFace site: "The UTKFace dataset is avaiable for non-commercial research purposes only." | **rejected** |
| `rizvandwiki/gender-classification`, `hungdang1610/gender`, `Leilab/gender_class`, `cledoux42/GenderNew_v002` (ViT) | none stated / Apache-2.0 (hungdang1610) | HuggingPics (web-search scrape, no license) / "1827 images … from ShotX" (private) | **rejected** (no license or unlicensed data) |
| `prithivMLmods/Gender-Classifier-Mini`, `Realistic-Gender-Classification` (SigLIP2-base, 372 MB) | Apache-2.0 | `myvision/gender-classification` (card not reachable, provenance unknown) / synthetic "realistic portraits" (Apache-2.0) | **rejected** (size 6x over the 60 MB flag, first has unverifiable data) |
| Apple MobileCLIP, InsightFace, VGG-Face derivatives | research-only / non-commercial | — | **rejected** per PRD FR2 |

Pre-training note: both HF models fine-tune ImageNet-pretrained backbones published under Apache-2.0 by Google and
Microsoft; the ImageNet terms attach to the dataset, not to those released weights. Recorded as an assumption.

## 2. Evaluation set

`Models/eval/manifest.json` (metadata only; images downloaded to `Models/work/faces/` by `Models/fetch_eval_faces.py`
and `Models/fairface.py children`). Labels come from Wikimedia Commons category names, never from hand labeling;
only CC0 / CC BY / CC BY-SA files (`extmetadata.LicenseShortName`) are kept; attributions in `Models/eval/ATTRIBUTIONS.md`.

| Tag | Source (label) | Notes |
|---|---|---|
| general | "Portrait photographs of women" / "… of men" | |
| hijab | "Women wearing hijabs" + 15 sub-categories (woman) | mostly event/group photos; only single-face images survive the rig's filter |
| child | "Portrait photographs of girls" / "… of boys" + FairFace validation faces aged 0–19 (CC BY 4.0) | |
| profile | "Profile portrait photographs of women" / "… of men" | |
| low-light | synthetic: untagged faces, gamma 2.2 then brightness x0.35 | stated as synthetic |

The rig detects faces with Vision, keeps images with exactly one face (others are counted and skipped), crops a square of
1.4x the longer face side (20 % margin each side) and resizes to the model input. A FairFace validation subset
(1000 faces at padding 1.25, `Models/fairface.py benchmark`) is run through the same pipeline as a second, larger check.

Manifest: 528 entries (80 general, 280 hijab, 90 child, 48 profile, 30 low-light). Faces that passed the filter
(exactly one Vision face, ≥ 32 px): general 68/80, hijab 134/280, child 69/90, low-light 26/30, profile 37/48 — 334 in
all. Hijab drop-outs are 119 multi-face group shots and 23 with no detected face; 6 profile images had no Vision face
(strong profiles are a detector weakness before they are a classifier one). Labels were not hand-checked; the errors
that were inspected (short-haired older women, athletes, a hazelnut photo filed under hijab) were real errors or
category noise, not crop bugs.

## 3. Candidates converted and measured

All converted with `coremltools` 9.0 to ML Program, fp16, macOS 15+, 224x224 RGB input with normalisation in-graph,
`probs = [P(woman), P(man)]` (`Models/convert_hf.py`, `Models/train_torch.py`). Torch-vs-CoreML parity on a random image:
0.0015 (ResNet-50), 0.0011 (ViT fp16), 0.0028 (ViT int8), 0.0017 (MobileNetV3).

| Candidate | What it is | Size on disk |
|---|---|---|
| `crangana_resnet50` | ResNet-50 fine-tuned on FairFace 0.25 (HF) | 47.1 MB |
| `dima806_vitb16` | ViT-B/16 fine-tuned on FairFace (HF) | 171.7 MB |
| `dima806_vitb16_int8` | same, int8 per-channel linear weight quantisation (`--int8`) | 86.2 MB |
| `createml_fairface` | Create ML scene-print r2 + logistic regression, 4,672 FairFace 1.25 Vision crops, 50 iterations | 6.8 KB (+ OS feature extractor), input 360x360 |
| `sitr_mnv3` | timm MobileNetV3-Large-100 fine-tune, 15,253 FairFace 1.25 Vision crops, 4 epochs on MPS, best val 89.4 % | 8.5 MB |

### Commons set — 334 faces, threshold 0.80
Accuracy = argmax vs label over faces found. Unknown = max class probability < 0.80. Misclassified = wrong among non-Unknown.

| Model | Accuracy | Unknown | Misclassified (non-Unknown) | general (68) | hijab (134) | child (69) | low-light (26) | profile (37) |
|---|---|---|---|---|---|---|---|---|
| crangana_resnet50 | 89.5 % | 15.3 % | 5.3 % | 91.2 % | 95.5 % | 84.1 % | 84.6 % | 78.4 % |
| dima806_vitb16 (fp16) | **93.7 %** | **3.6 %** | 5.6 % | 92.6 % | 97.0 % | 92.8 % | 88.5 % | 89.2 % |
| dima806_vitb16_int8 | **93.7 %** | **3.6 %** | 5.6 % | 92.6 % | 97.0 % | 92.8 % | 88.5 % | 89.2 % |
| createml_fairface | 88.9 % | 17.7 % | 7.3 % | 91.2 % | 94.8 % | 82.6 % | 92.3 % | 73.0 % |
| sitr_mnv3 | 78.1 % | 42.5 % | 7.8 % | 85.3 % | 79.9 % | 72.5 % | 88.5 % | 62.2 % |

Unknown rate per tag:

| Model | general | hijab | child | low-light | profile |
|---|---|---|---|---|---|
| crangana_resnet50 | 8.8 % | 6.7 % | 27.5 % | 34.6 % | 21.6 % |
| dima806_vitb16 / int8 | 1.5 % | 3.0 % | 7.2 % | 3.8 % | 2.7 % |
| createml_fairface | 7.4 % | 14.2 % | 29.0 % | 7.7 % | 35.1 % |
| sitr_mnv3 | 33.8 % | 40.3 % | 44.9 % | 50.0 % | 56.8 % |

### FairFace validation subset — 1000 rows at padding 1.25, 762 faces passed the filter (571 adult, 191 child)

| Model | Accuracy | Unknown | Misclassified (non-Unknown) | adult acc | child acc | Unknown adult / child |
|---|---|---|---|---|---|---|
| crangana_resnet50 | 89.5 % | 16.8 % | 6.3 % | 91.9 % | 82.2 % | 14.9 % / 22.5 % |
| dima806_vitb16 (fp16) | **95.0 %** | 3.9 % | **3.6 %** | 97.2 % | 88.5 % | 1.8 % / 10.5 % |
| dima806_vitb16_int8 | **95.0 %** | 3.8 % | 3.7 % | 97.2 % | 88.5 % | 1.8 % / 9.9 % |
| createml_fairface | 87.3 % | 19.9 % | 7.0 % | 89.7 % | 80.1 % | 17.0 % / 28.8 % |
| sitr_mnv3 | 86.6 % | 26.2 % | 6.0 % | 88.8 % | 80.1 % | 23.8 % / 33.5 % |

### ms per crop — `sitr-spike classifier --bench`, release build, batch 1, 20 warm + 200 timed, pre-sized 224x224 BGRA buffer (model time only, no resize)

**Quiet phase, shipped model** (2026-09-06, nothing else of ours running, load1 2.6–2.8, `.build/release/sitr-spike classifier
--bench Models/dist/GenderClassifier.mlpackage`, three processes):

| Model | `.all` p50 / p95 | `.cpuAndNeuralEngine` p50 / p95 |
|---|---|---|
| dima806_vitb16_int8 (shipped), ANE model alone in the process | – | **5.74 / 6.98** |
| dima806_vitb16_int8 (shipped), default run (`.all` loaded first, then ANE) | 6.40 / 8.15; 6.42 / 8.16 | 12.24 / 17.56; 9.64 / 17.29 |

The ANE number depends on what else is loaded in the process: alone it is 5.7 / 7.0 ms; as the second model after `.all` it
is 9.6–12.2 ms p50 with a 17 ms p95. The app loads the detector and the classifier on the ANE together, so its own
`classify_ms` (5–8 ms per crop including crop + resize, docs/spike/system.md) is the number that counts.

Preliminary (2026-09-05, busy machine; several runs each because the numbers moved between runs; superseded for the shipped model):

| Model | `.all` p50 / p95 | `.cpuAndNeuralEngine` p50 / p95 |
|---|---|---|
| crangana_resnet50 | 2.55 / 12.92; 4.12 / 11.95 | 4.59 / 24.12; 4.62 / 24.37 |
| dima806_vitb16 (fp16) | 9.87 / 21.77; 17.24 / 39.25; 17.17 / 21.08 | 9.63 / 20.33; 16.99 / 18.00; 10.75 / 17.18 |
| dima806_vitb16_int8 (shipped) | 17.52 / 18.99; 6.11 / 7.04 | 8.43 / 9.91; 9.55 / 17.15 |
| createml_fairface (360x360) | 6.09 / 6.44; 9.92 / 10.98 | 6.10 / 6.73; 6.20 / 6.69 |
| sitr_mnv3 | 1.26 / 1.88 | **0.76 / 0.87** |

Summary lines are parseable: `classifier_ms model=<name> units=<all|cpuAndNeuralEngine> p50=<ms> p95=<ms> n=200 input=WxH size_mb=<MB>`.

## 4. Decision

**Ship `dima806/fairface_gender_image_detection` (ViT-B/16) with int8 weights** as `Models/dist/GenderClassifier.mlpackage`
(`Models/dist/SOURCE.md`, `LICENSE-dima806_fairface_gender_image_detection.txt`, `CHECKSUMS.txt`).

- Accuracy: the only candidate above 90 % — 93.7 % on the Commons set, 95.0 % on FairFace validation — with a low Unknown
  rate (3.6–3.9 %). Every tag is ≥ 88.5 %; hijab 97.0 %, child 92.8 % / 88.5 %, profile 89.2 %, low-light 88.5 %.
- Unknown at 0.80: 3.6 % overall; children 7–10 % (acceptable, and Strict Mode blurs Unknown anyway).
- Misclassification among non-Unknown: 5.6 % (Commons) / 3.7 % (FairFace). The PRD's ≤ 2 % "hidden-category person shown"
  is a pipeline number (tracker stickiness over frames, faces ≥ 32 px); the classifier alone does not reach it on single
  crops. M2-T07/M4-T08 must confirm it end to end, or raise the threshold (0.90 would trade Unknown for misclassification).
- Speed: ANE p50 5.7 / p95 7.0 ms on a quiet M3 (model alone; 8.4–9.6 ms preliminary) — inside the ≤ ~10 ms/crop target;
  `.all` sometimes schedules the ViT partly on the GPU and doubled the latency in the preliminary runs, so the app sets
  `.cpuAndNeuralEngine`. With the detector loaded in the same process the crop costs 5–8 ms in the app (docs/spike/system.md).
- **Size flag: 86 MB exceeds the 60 MB guideline** (fp16 would be 172 MB). int8 costs nothing in accuracy (identical on
  both sets). Cheaper models did not make the accuracy bar: ResNet-50 (47 MB) is at 89.5 % with 15 % Unknown; the Create
  ML scene-print head (7 KB) is at 88 % with 18 % Unknown; the MobileNetV3 fine-tune (8.5 MB, 0.8 ms) reached only
  89 % FairFace val after 4 epochs on one shard and collapsed to 78 % on the Commons set (42 % Unknown) — under-trained,
  not a dead end.
- License: weights Apache-2.0, training data FairFace CC BY 4.0, base model Apache-2.0 — quotes in section 1.

Interface for M2-T07: input `image` 224x224 RGB (0–255), output `probs[0] = P(woman)`, `probs[1] = P(man)`; crop =
largest Vision face, square 1.4x the longer side around the centre, clamped, scale-fill resize; face < 32 px → Unknown;
`max(probs) < 0.80` → Unknown; `computeUnits = .cpuAndNeuralEngine`.

## 5. Follow-ups, shortcuts, assumptions
- Replace the 86 MB ViT with the home-grown MobileNetV3 once `Models/train_torch.py` is run properly (all 4 FairFace
  train shards ≈ 87 k faces, 10+ epochs, ~6 min/epoch on M3 for 15 k crops); the pipeline, crop rule and eval already
  exist, and the target is ≥ 93 % on the Commons set with < 5 % Unknown at 8.5 MB / < 1 ms.
- Scope cuts made in this spike: fine-tune stopped at 4 epochs on one shard; Create ML trained on the first 4.7 k-crop
  export, not the 15 k one; Commons `low-light` is synthetic; child labels partly come from FairFace age buckets; the
  eval set is 528 entries / 334 usable faces rather than exactly 200 because single-face filtering removes most hijab
  event photos; nothing was hand-labeled.
- `.all` vs `.cpuAndNeuralEngine` and the run-to-run spread mean every ms number above is provisional.
- Public-domain Commons files were excluded on purpose (the instructions name CC0/CC BY/CC BY-SA); that removed most
  19th-century profile portraits, which is why the `profile` tag is small (37 faces).
- Ponytail markers in code: `Sources/SitrSpike/Classifier.swift` (main-thread semaphore), `Models/convert_hf.py`
  (hand-parsed preprocessor config), `Models/fetch_eval_faces.py` (skip broken downloads), `Models/train_createml.swift`
  (no augmentation).
