# Third-party notices

Sitr is licensed under GPL-3.0-only (`LICENSE`). Everything below is third-party material that is either shipped
inside `Sitr.app`, committed to this repository, or downloaded by scripts for evaluation. Keep this file in step with
`Models/dist/`, `Package.swift`, and the `ATTRIBUTION*.md` files it points to.

## 1. Core ML models bundled in the app

Both packages live in `Models/dist/` and are compiled into `Sitr.app/Contents/Resources/*.mlmodelc` by
`scripts/build-app.sh`. `Tests/SitrDetectTests/ModelChecksumTests.swift` (run by CI) fails if any file in either
package differs from its checksum list.

### PersonDetector.mlpackage (YOLOX-S)
| | |
|---|---|
| Component | YOLOX-S object detector, Megvii Inc. (Ge, Z., Liu, S., Wang, F., Li, Z., Sun, J., "YOLOX: Exceeding YOLO Series in 2021") |
| Source | https://github.com/Megvii-BaseDetection/YOLOX, tag `0.3.0`; weights `yolox_s.pth` from release `0.1.1rc0` |
| License | Apache License 2.0, Copyright (c) 2021-2022 Megvii Inc. Full text: `Models/dist/LICENSE-YOLOX.txt` |
| Modifications | Converted to a Core ML ML Program (fp16, 1280x768 input) with the SPP pooling and box-decoding rewrites described in `Models/dist/SOURCE-PersonDetector.md`; no retraining |
| Training data | COCO train2017 (COCO Consortium). Annotations CC BY 4.0, https://cocodataset.org; images are Flickr photos under their individual licenses. Not redistributed by Sitr |
| Checksums | `Models/dist/CHECKSUMS-PersonDetector.txt` |
| Provenance | `Models/dist/SOURCE-PersonDetector.md`, `Models/detector/README.md` |

### GenderClassifier.mlpackage (FairFace ViT)
| | |
|---|---|
| Component | `dima806/fairface_gender_image_detection`, ViT-B/16 gender classifier, revision `a8e129dc622dafa08bd2ee2e0fd05759850ae14e` |
| Source | https://huggingface.co/dima806/fairface_gender_image_detection |
| License | Apache License 2.0 (model card `license: apache-2.0`). Full text and notices: `Models/dist/LICENSE-dima806_fairface_gender_image_detection.txt` |
| Base model | `google/vit-base-patch16-224-in21k` (Google), Apache License 2.0, https://huggingface.co/google/vit-base-patch16-224-in21k |
| Modifications | Converted to a Core ML ML Program (fp16 activations, int8 weights) by `Models/convert_hf.py`; no retraining |
| Training data | FairFace, Kärkkäinen, K. & Joo, J., "FairFace: Face Attribute Dataset for Balanced Race, Gender, and Age", WACV 2021, https://github.com/joojs/fairface. CC BY 4.0, © Kimmo Kärkkäinen and Jungseock Joo. Not redistributed by Sitr |
| Checksums | `Models/dist/CHECKSUMS.txt` |
| Provenance | `Models/dist/SOURCE.md` |

## 2. Datasets and images used for evaluation (never committed, never shipped)

Scripts download these into gitignored folders; the repository holds only URLs, authors and licenses.

- **FairFace** (CC BY 4.0, Kärkkäinen & Joo) — classifier training data (above) and 40 validation faces used in the
  spike evaluation: `Models/eval/ATTRIBUTIONS.md`, section "FairFace".
- **COCO 2017** — annotations CC BY 4.0 (COCO Consortium); the 200 recall-set images are Flickr photos restricted to
  CC BY 2.0, CC BY-SA 2.0 and "no known copyright restrictions", listed one per line with author URL and license in
  `Bench/ATTRIBUTIONS.md`, section "Recall set".
- **Wikimedia Commons** photographs (CC0 1.0, CC BY 2.0–4.0, CC BY-SA 2.0–4.0), used as classifier evaluation faces
  and as composite-frame inputs for the detection rigs: `Models/eval/ATTRIBUTIONS.md`, section "Wikimedia Commons",
  and `Bench/ATTRIBUTIONS.md`, section "Composite-frame photos". Each entry names the file, author and license.

## 3. Fixture photos committed to the repository (not in the app bundle)

- `Tests/SitrDetectTests/Fixtures/person.jpg` — "Laughing woman in jean jacket (Unsplash)" by Brooke Cagle,
  CC0 1.0, https://commons.wikimedia.org/wiki/File:Laughing_woman_in_jean_jacket_(Unsplash).jpg; downscaled to
  640x426 and re-encoded. Details: `Tests/SitrDetectTests/Fixtures/ATTRIBUTION.md`.
- `Sources/SitrSpike/Fixtures/person.jpg` — "Indian man standing in doorway (Unsplash)" by Abhas Mishra, CC0 1.0,
  https://commons.wikimedia.org/wiki/File:Indian_man_standing_in_doorway_(Unsplash).jpg; 500 px Commons thumbnail,
  unmodified. Details: `Sources/SitrSpike/Fixtures/ATTRIBUTION.md`.

## 4. Apple frameworks

Sitr links only Apple system frameworks (AppKit, SwiftUI, ScreenCaptureKit, Vision, Core ML, Core Image, Core Video,
Metal, Carbon HIToolbox, ServiceManagement, UserNotifications, os). They are part of macOS, linked dynamically and not
redistributed, so no third-party notice is required for them.

## 5. Swift package dependencies

None. `Package.swift` declares no external `dependencies` and there is no `Package.resolved`; the app is built from
this repository and Apple's SDK only. If a dependency is ever added, list it here (name, URL, version, license) and
copy its license text into a `Licenses/` folder inside the bundle.

## 6. Build and release tooling (not distributed)

Xcode, `hdiutil`, `codesign`, `notarytool` (Apple) and Homebrew packages used only at build or release time
(`create-dmg`, `actionlint`) are not part of the app or the repository and need no notice here.
