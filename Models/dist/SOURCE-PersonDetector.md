# PersonDetector.mlpackage — source and provenance

YOLOX-S (Megvii, Inc.), converted to a CoreML ML Program (fp16) for Sitr's person detector. Spike M1-T06b.

## Upstream
- Project: https://github.com/Megvii-BaseDetection/YOLOX — license Apache-2.0 (`LICENSE-YOLOX.txt`, verbatim copy of the
  repository's LICENSE, copyright (c) 2021-2022 Megvii Inc.).
- Source used for the conversion: tag `0.3.0`,
  https://github.com/Megvii-BaseDetection/YOLOX/archive/refs/tags/0.3.0.tar.gz
  sha256 `972ddb9cb13d508fac3738e814449327cec29bc55fbd8a125c67d9080edfc02d`.
- Weights: `yolox_s.pth` from release `0.1.1rc0`,
  https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_s.pth
  sha256 `f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30`, 72 089 125 bytes.
- Training data: COCO train2017 (80 classes; only class 0 "person" is used by Sitr). No fine-tuning, no data of ours.

## Conversion
```
Models/venv/bin/python Models/detector/convert_yolox.py --fetch
Models/venv/bin/python Models/detector/convert_yolox.py --models s --sizes 1280x768 --dist
```
`Models/detector/convert_yolox.py` (torch 2.14.0, coremltools 9.0, Python 3.12.13): builds `exps/default/yolox_s.py`
(depth 0.33, width 0.50, SiLU), loads the weights, `head.decode_in_inference = True`, replaces `decode_outputs` with the
same math without in-place slice writes, rewrites the SPP 9x9/13x13 max pools as stacked 5x5 pools (exact; keeps every
op on the Neural Engine), `torch.jit.trace` at 1x3x768x1280, `coremltools.convert(convert_to="mlprogram",
compute_precision=FLOAT16, minimum_deployment_target=macOS15)`. Verified against PyTorch on
`Tests/SitrDetectTests/Fixtures/person.jpg`: max abs box diff 1.48 px, max abs score diff 0.0058 (rows with person
score >= 0.3); details in `Models/detector/README.md`.

## Input contract
- Input `image`: 1280x768 (WxH) color image, raw 0-255 pixel values, **BGR** channel order (declared in the model, CoreML
  reorders a BGRA `CVPixelBuffer` itself), no mean/std normalisation.
- Letterbox: r = min(1280 / w, 768 / h); scale the frame by r and paste it top-left on a canvas filled with
  (114, 114, 114) grey (YOLOX's own `ValTransform`). `CoreMLPersonDetector` does this with CoreImage.
- Output `predictions`: float32 [1, 20160, 85] — per row cx, cy, w, h in input pixels (already decoded), objectness,
  80 COCO class scores (sigmoid). Person = class 0; score = objectness x class score; threshold 0.30; NMS IoU 0.5 in Swift.
- Compute: fp16 ML Program; `MLComputePlan` places all 212 ops on the Neural Engine (macOS 26.6, M3).

## Integrity
`CHECKSUMS-PersonDetector.txt` lists the SHA-256 of every file in the package (`shasum -a 256 -c` from `Models/dist/`).
