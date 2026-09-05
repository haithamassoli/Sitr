# GenderClassifier.mlpackage — provenance

| | |
|---|---|
| Origin | Hugging Face `dima806/fairface_gender_image_detection`, revision `a8e129dc622dafa08bd2ee2e0fd05759850ae14e` (files `model.safetensors` 343,223,968 bytes, `config.json`, `preprocessor_config.json`) |
| Architecture | ViT-B/16, 224x224, fine-tuned from `google/vit-base-patch16-224-in21k` (Apache-2.0) |
| Weights license | Apache-2.0 (model card front matter `license: apache-2.0`); full text and notices in `LICENSE-dima806_fairface_gender_image_detection.txt` |
| Training data | FairFace (model card `datasets: nateraw/fairface`) — CC BY 4.0, https://github.com/joojs/fairface ("License: CC BY 4.0"), mirror https://huggingface.co/datasets/HuggingFaceM4/FairFace |
| Card metrics | 93.4 % accuracy on the author's FairFace split (Female recall 0.905, Male recall 0.960) |
| Conversion | `Models/venv/bin/python Models/convert_hf.py Models/work/hf/dima806__fairface_gender_image_detection Models/work/dima806_vitb16_int8.mlpackage --revision a8e129dc622dafa08bd2ee2e0fd05759850ae14e --int8 --license "Apache-2.0 (dima806/fairface_gender_image_detection); training data FairFace CC BY 4.0"` then copied to `Models/dist/GenderClassifier.mlpackage` (the local dir is `huggingface_hub.snapshot_download` of the revision above; passing the repo id works the same) |
| Toolchain | Python 3.12.13, torch 2.14.0 (CPU), transformers 5.16.1, coremltools 9.0, macOS 26.6.2 |
| Format | Core ML ML Program, minimum deployment macOS 15, fp16 activations, int8 per-channel linear-symmetric weights (`coremltools.optimize.coreml.linear_quantize_weights`); 86.2 MB on disk (fp16 variant: 171.7 MB, identical accuracy on both eval sets) |
| Input | `image`: RGB 224x224, pixel range 0-255. The graph rescales by 1/255 and applies the card's mean 0.5 / std 0.5 normalisation, so no preprocessing beyond the resize is needed |
| Output | `probs`: float32 `[1, 2]` = `[P(woman), P(man)]` (softmax). The card's labels are `Female` (0) / `Male` (1); the wrapper reorders them |
| Parity | torch fp32 vs Core ML on a random image: max abs diff 0.0011 (fp16), 0.0028 (int8) |
| Checksums | `CHECKSUMS.txt` (SHA-256 of every file in the package; regenerate with `find Models/dist/GenderClassifier.mlpackage -type f \| sort \| xargs shasum -a 256`) |

## How the app must feed it (from the spike, `docs/spike/classifier.md`)
- Crop: largest Vision face box, square of 1.4x the longer side around the box centre (20 % margin per side), clamped to
  the frame; scale-fill to 224x224 (`sitr-spike classifier --crop` / `FaceCrop` in `Sources/SitrSpike/Classifier.swift`).
- Faces under 32 px are Unknown before the model runs (PRD FR2).
- `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine` (`.all` let Core ML schedule parts of the ViT on the GPU and
  doubled the latency in the spike).
- Category rule: `max(P(woman), P(man)) < 0.80` → Unknown.
