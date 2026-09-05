# Models — face-gender classifier research (M1-T05)

Findings, tables and the decision live in `docs/spike/classifier.md`. The shipped model is `dist/GenderClassifier.mlpackage`
with `dist/LICENSE-*.txt`, `dist/SOURCE.md` and `dist/CHECKSUMS.txt`. Everything under `work/` and `venv/` is gitignored;
no image is ever committed — `eval/manifest.json` and `eval/ATTRIBUTIONS.md` hold URLs, authors and licenses only.

## Setup
```
/opt/homebrew/opt/python@3.12/bin/python3.12 -m venv Models/venv
Models/venv/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
Models/venv/bin/pip install transformers coremltools pillow numpy huggingface_hub datasets timm scikit-learn requests
swift build                                   # sitr-spike classifier rig (Sources/SitrSpike/Classifier.swift)
```

## Evaluation set (~300 faces, labels from category names, no hand labeling)
```
Models/venv/bin/python Models/fetch_eval_faces.py            # Wikimedia Commons, CC0 / CC BY / CC BY-SA only
Models/venv/bin/python Models/fairface.py children --n 40    # FairFace validation faces aged 0-19 (CC BY 4.0)
Models/venv/bin/python Models/fairface.py benchmark --n 1000 # FairFace validation subset -> Models/work/ffval/
```
Tags: `hijab`, `profile`, `child`, `low-light` (synthetic: gamma 2.2 then x0.35 of untagged faces), untagged = general.

## Candidates → CoreML
```
Models/venv/bin/python Models/convert_hf.py crangana/trained-gender Models/work/crangana_resnet50.mlpackage --revision 5cdda77753659b5a2910b793914f6edf98fc9600
Models/venv/bin/python Models/convert_hf.py dima806/fairface_gender_image_detection Models/work/dima806_vitb16.mlpackage --revision a8e129dc622dafa08bd2ee2e0fd05759850ae14e
Models/venv/bin/python Models/convert_hf.py dima806/fairface_gender_image_detection Models/work/dima806_vitb16_int8.mlpackage --revision a8e129dc622dafa08bd2ee2e0fd05759850ae14e --int8   # shipped
```
Output contract for every model: image input, `probs` = `[P(woman), P(man)]` (Create ML models expose a label dictionary
with `woman` instead; the rig accepts both). `--int8` = per-channel linear weight quantization, halves the fp16 size.

## Home-grown models (FairFace 1.25 crops in the app's framing)
```
Models/venv/bin/python Models/fairface.py export --padding 1.25 --train-per-class 10000 --val-per-class 500
swift build -c release && .build/release/sitr-spike classifier --crop-dir Models/work/fairface_1.25 Models/work/fairface_1.25_crops
# a) Create ML: Apple scene-print feature extractor + logistic regression (model file ~7 KB, extractor lives in macOS)
xcrun swiftc -O -swift-version 6 -framework CreateML Models/train_createml.swift -o Models/work/train_createml
Models/work/train_createml Models/work/fairface_1.25_crops/train Models/work/fairface_1.25_crops/val Models/work/createml_fairface.mlmodel
# b) PyTorch/timm MobileNetV3-Large fine-tune on Apple GPU (MPS), exported straight to CoreML
Models/venv/bin/python Models/train_torch.py --epochs 4 --out Models/work/sitr_mnv3.mlpackage
```

## Measure
```
swift run sitr-spike classifier --bench <model>                       # classifier_ms model=.. units=.. p50=.. p95=.. n=200
swift run sitr-spike classifier --eval Models/eval --model <m> [--model <m2>] [--verbose] [--dump-crops <dir>]
swift run sitr-spike classifier --eval Models/work/ffval --model <m>  # FairFace validation subset
swift run sitr-spike classifier --crop <in.jpg> <out.jpg>            # one face crop, 20 % margin, square
```
Face crop rule (shared with M2-T07): largest Vision face box, square of 1.4x its longer side around the centre, clamped to
the image; eval images must contain exactly one Vision face or they are skipped and counted.
