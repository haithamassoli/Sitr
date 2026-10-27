# PersonDetector.mlpackage — source and provenance

YOLOX-M (Megvii, Inc.) at 1024x640, converted to a CoreML ML Program (fp16) for Sitr's person detector. Chosen over the
M1-T06b YOLOX-S 1280x768 in October 2026 (docs/models-2026.md): recall on bodies >= 80 px 88.7 -> 91.1 %, every op on the
ANE on macOS 27, same latency.

## Upstream
- Project: https://github.com/Megvii-BaseDetection/YOLOX — license Apache-2.0 (`LICENSE-YOLOX.txt`, verbatim copy of the
  repository's LICENSE, copyright (c) 2021-2022 Megvii Inc.).
- Source used for the conversion: tag `0.3.0`,
  https://github.com/Megvii-BaseDetection/YOLOX/archive/refs/tags/0.3.0.tar.gz
  sha256 `972ddb9cb13d508fac3738e814449327cec29bc55fbd8a125c67d9080edfc02d`.
- Weights: `yolox_m.pth` from release `0.1.1rc0`,
  https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_m.pth
  sha256 `60076992b32da82951c90cfa7bd6ab70eba9eda243e08b940a396f60ac2d19b6`.
- Training data: COCO train2017 (80 classes; only class 0 "person" is used by Sitr). No fine-tuning, no data of ours.

## Conversion
```
Models/venv/bin/python Models/detector/convert_yolox.py --fetch
Models/venv/bin/python Models/detector/convert_yolox.py --models m --sizes 1024x640 --dist
```
`Models/detector/convert_yolox.py` (torch 2.14.0, coremltools 9.0, Python 3.12.13): builds `exps/default/yolox_m.py`
(depth 0.67, width 0.75, SiLU), loads the weights, `head.decode_in_inference = True`, replaces `decode_outputs` with the
same math without in-place slice writes, rewrites the SPP 9x9/13x13 max pools as stacked 5x5 pools (exact; keeps every
op on the Neural Engine), `torch.jit.trace` at 1x3x640x1024, `coremltools.convert(convert_to="mlprogram",
compute_precision=FLOAT16, minimum_deployment_target=macOS15)`. Same conversion path as the
YOLOX-S it replaced (whose PyTorch parity is in `Models/detector/README.md`); `Tests/SitrDetectTests` checks the shipped
model's box on `Tests/SitrDetectTests/Fixtures/person.jpg`. Recall, false positives and latency against the alternatives:
`docs/models-2026.md`.

## Input contract
- Input `image`: 1024x640 (WxH) color image, raw 0-255 pixel values, **BGR** channel order (declared in the model, CoreML
  reorders a BGRA `CVPixelBuffer` itself), no mean/std normalisation.
- Letterbox: r = min(1024 / w, 640 / h); scale the frame by r and paste it top-left on a canvas filled with
  (114, 114, 114) grey (YOLOX's own `ValTransform`). `CoreMLPersonDetector` does this with CoreImage.
- Output `predictions`: float32 [1, 13440, 85] — per row cx, cy, w, h in input pixels (already decoded), objectness,
  80 COCO class scores (sigmoid). Person = class 0; score = objectness x class score; threshold 0.25 in the app (`SitrApp.personThreshold`); NMS IoU 0.5 in Swift.
- Compute: fp16 ML Program; `MLComputePlan` places all 267 ops on the Neural Engine (macOS 27.0.1, M3).

## Integrity
`CHECKSUMS-PersonDetector.txt` lists the SHA-256 of every file in the package (`shasum -a 256 -c` from `Models/dist/`).
