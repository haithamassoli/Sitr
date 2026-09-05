# Person detector (YOLOX -> CoreML), spike M1-T06b

Why: Vision `DetectHumanRectanglesRequest` reached 25.8 % recall (37.8 % with the upper-body union) on the COCO
recall set (`docs/spike/detect.md`); the PRD asks for >= 95 % on bodies >= 40 px. YOLOX (Megvii, Apache-2.0) is the
first permissive candidate the spike recommended. Ultralytics YOLO is AGPL and excluded.

## Reproduce
```
/opt/homebrew/opt/python@3.12/bin/python3.12 -m venv Models/venv            # gitignored
Models/venv/bin/pip install torch torchvision coremltools numpy pillow opencv-python-headless loguru thop psutil tabulate
Models/venv/bin/python Models/detector/convert_yolox.py --fetch              # YOLOX 0.3.0 source + 0.1.1rc0 weights -> Models/work/ (gitignored)
Models/venv/bin/python Models/detector/convert_yolox.py --models tiny,s,m --sizes 640x384,1280x768   # -> Models/work/out/*.mlpackage
Models/venv/bin/python Models/detector/convert_yolox.py --models s --sizes 1280x768 --dist            # -> Models/dist/PersonDetector.mlpackage + checksums + license
swift run -c release sitr-spike recall Bench/recall/manifest.json --detector coreml:Models/dist/PersonDetector.mlpackage
swift run -c release sitr-spike detect --detector coreml:Models/dist/PersonDetector.mlpackage --n 200 --sides 2560
swift test --filter CoreMLPersonDetector                                     # skips when Models/dist has no model
```
Versions used: Python 3.12.13, torch 2.14.0, coremltools 9.0 (warns that torch 2.14 is untested; conversions verified
against PyTorch, see below), macOS 26.6.2, Xcode 26.6.

## What the script does
- Builds the model from the YOLOX source tree (`exps/default/yolox_{tiny,s,m}.py`, `act = silu`), loads the official
  COCO weights, sets `head.decode_in_inference = True` so the network outputs decoded boxes.
- Replaces `YOLOXHead.decode_outputs` with the same math written without in-place slice writes
  (`outputs[..., :2] = ...`), which coremltools 9 rejects (`slice_update` shape error). Output is identical.
- Rewrites the SPP bottleneck's 9x9 and 13x13 stride-1 max pools as 2x and 3x stacked 5x5 pools (exact: max is
  associative, -inf padding). CoreML scheduled the big pools on the CPU (2 of 212 ops, two ANE->CPU->ANE hops per
  frame); afterwards `MLComputePlan` reports all 212 ops on the Neural Engine for every variant. The verify step
  asserts the rewrite changes the PyTorch output by 0 (`spp_rewrite_diff`).
- `torch.jit.trace` at the fixed input size, then `coremltools.convert(..., convert_to="mlprogram",
  compute_precision=FLOAT16, minimum_deployment_target=macOS15)` with `ImageType(color_layout=BGR, scale=1, bias=0)`,
  so the CoreML input is raw 0-255 BGR pixels exactly as YOLOX's non-legacy `ValTransform` feeds the network.
- Verifies every package against PyTorch on `Tests/SitrDetectTests/Fixtures/person.jpg`: max abs diff over the rows
  PyTorch scores as person >= 0.3 (box in input pixels, score = obj x cls) and the top person box in source pixels.

## Input contract (also in the model metadata)
- Image input `image`, WxH (640x384 or 1280x768; both multiples of 32, ~5:3 like the screen).
- Letterbox: r = min(W / w, H / h); scale the frame by r, paste top-left onto a canvas filled with (114, 114, 114);
  no mean/std normalisation. CoreML handles the BGRA -> BGR reorder from the declared layout.
- Output `predictions` [1, N, 85] float32: cx, cy, w, h in input pixels, objectness, 80 COCO class scores (sigmoid).
  Person = class 0, score = objectness x class score. N = sum over strides 8/16/32 of (W/s)(H/s): 5040 at 640x384,
  20160 at 1280x768. NMS is done in Swift (`CoreMLPersonDetector`, IoU 0.5).

## Verification (CoreML fp16 vs PyTorch fp32, person.jpg, rows with person score >= 0.3)

| model | input    | rows torch / coreml | max abs box diff (px) | max abs score diff | top box torch -> coreml (x,y,w,h,score) |
|-------|----------|---------------------|-----------------------|--------------------|------------------------------------------|
| tiny  | 640x384  | 8 / 9               | 0.79                  | 0.0033             | 260,102,124,321,0.900 -> 260,102,124,322,0.897 |
| tiny  | 1280x768 | 8 / 9               | 1.75                  | 0.0029             | 261,109,124,308,0.891 -> 261,109,124,308,0.890 |
| s     | 640x384  | 10 / 10             | 1.21                  | 0.0431             | 258,111,123,313,0.924 -> 258,111,123,312,0.923 |
| s     | 1280x768 | 9 / 9               | 1.48                  | 0.0058             | 258,108,125,313,0.891 -> 258,108,125,313,0.889 |
| m     | 640x384  | 9 / 9               | 0.93                  | 0.0019             | 258,107,123,316,0.934 -> 258,107,123,316,0.933 |
| m     | 1280x768 | 9 / 9               | 1.56                  | 0.0018             | 261,110,120,310,0.928 -> 261,111,120,310,0.926 |

Hand-checked body box of the fixture: x 262, y 112, w 123, h 314 (`DetectorTests.swift`); every variant is inside 5 %.
`spp_rewrite_diff` = 0 for all six. Package sizes (fp16): tiny 10.3 MB, s 18.2 MB, m 50.8 MB.

Op placement (`MLComputePlan`, macOS 26.6): 212 ops, all on the Neural Engine under both `.all` and
`.cpuAndNeuralEngine` (before the SPP rewrite: 210 ANE + 2 CPU `max_pool`).

## Sources
- Source: https://github.com/Megvii-BaseDetection/YOLOX, tag 0.3.0 (tarball sha256
  972ddb9cb13d508fac3738e814449327cec29bc55fbd8a125c67d9080edfc02d). License: Apache-2.0 (`Models/dist/LICENSE-YOLOX.txt`).
- Weights (release 0.1.1rc0, trained on COCO train2017):
  - yolox_tiny.pth sha256 9de513de589ac98bb92d3bca53b5af7b9acfa9b0bacb831f7999d0f7afaee8f0 (40 755 013 bytes)
  - yolox_s.pth sha256 f55ded7181e1b0c13285c56e7790b8f0e8f8db590fe4edb37f0b7f345c913a30 (72 089 125 bytes)
  - yolox_m.pth sha256 60076992b32da82951c90cfa7bd6ab70eba9eda243e08b940a396f60ac2d19b6 (203 114 461 bytes)

Results and the decision: `docs/spike/detect.md`, section "CoreML detector (M1-T06b)".
