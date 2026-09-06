# M1-T07 — Blur render cost + strength curve (`sitr-spike blur`)

Run: `swift run sitr-spike blur [--iterations N=200] [--faces DIR=Bench/data/faces] [--dump DIR] [--skip-cost] [--skip-curve]`
(≈ 40 s; first run downloads 5 CC0 portraits into `Bench/data/faces`, gitignored). Code: `Sources/SitrSpike/Blur.swift`.

## 1. Cost per cover

Setup: one `CIContext(mtlDevice:)` reused for everything. Input = a 1280×832 BGRA `CVPixelBuffer` (capture space at the PRD
long side) holding the fixture person (`Fixtures/person.jpg`) scaled so the face is 60 / 120 / 240 px tall. Cover = body
rectangle 3 × face wide, 7.4 × face tall, clamped to the frame. Per iteration: `CIImage(cvPixelBuffer:)` → crop →
`clampedToExtent` → `CIGaussianBlur` (sigma = the 70 % radius) or `CIPixellate` (block = the 70 % block) → crop → output →
`layer.contents` inside one `CATransaction` + `flush`, on a panel that is on screen so the commit really ships pixels.

Two output paths: **cgimage** = `createCGImage` (GPU render + CPU readback, then CA copies the bitmap at commit) and
**iosurface** = `startTask(toRender:…)` into an IOSurface-backed `CVPixelBuffer` + `waitUntilCompleted()` (GPU time included),
then `layer.contents = IOSurface` (zero-copy). p50 / p95 over 200 warm iterations (10 warm-ups discarded).

Quiet phase (2026-09-06, Apple M3, macOS 26.6.2, nothing else of ours running, load1 2.75; `.build/debug/sitr-spike blur`):

| Face | Cover (px) | Style | param (px) | cgimage p50 / p95 | iosurface p50 / p95 |
|---|---|---|---|---|---|
| 60 | 180×444 | Gaussian | 24.1 | 1.0 / 1.3 ms | **0.4 / 0.5 ms** |
| 60 | 180×444 | Pixellate | 24.6 | 0.8 / 0.8 ms | **0.3 / 0.3 ms** |
| 120 | 360×820 | Gaussian | 48.1 | 2.1 / 2.3 ms | **0.6 / 0.7 ms** |
| 120 | 360×820 | Pixellate | 49.2 | 1.7 / 2.1 ms | **0.3 / 0.4 ms** |
| 240 | 721×808 | Gaussian | 96.2 | 3.8 / 4.3 ms | **1.0 / 1.3 ms** |
| 240 | 721×808 | Pixellate | 98.4 | 2.9 / 3.0 ms | **0.4 / 0.4 ms** |

Preliminary (2026-09-05, other agents building in parallel; superseded): iosurface Gaussian 1.2 / 3.0, 2.1 / 4.1, 3.7 / 4.9 ms and
Pixellate 0.9 / 1.5, 1.1 / 1.5, 1.7 / 55.9 ms (one stall) for 60 / 120 / 240 px faces; cgimage 2.8–16.0 ms p50.

Reading: the M2-T11 gate "≤ 2 ms per cover at spike source size" holds on the **IOSurface path** at every size, with margin
(0.3–1.0 ms p50, 1.3 ms p95 for the 240 px Gaussian); the preliminary numbers were 3× higher because the GPU was shared with
other agents' jobs. Gaussian cost still grows with radius × area (0.4 → 0.6 → 1.0 ms), so for very big covers cap the radius or
blur a 2–4× downsampled crop (visually identical). The `createCGImage` path is 1–4 ms per cover (3–16 ms under contention) and
should not be used for live covers. Numbers in an earlier run before the GPU wait was added were 0.1 ms for iosurface:
`CIContext.render(to:)` returns before the GPU finishes, hence `startTask`.

## 2. Strength curve (strength s = 0–100 %, f = face height in capture pixels)

```
Gaussian radius = f × (0.17 + 0.33 · s/100)      60 px face: 10.2 px (0 %) · 24.1 px (70 %, default) · 30 px (100 %)
Pixel block     = f × (0.20 + 0.30 · s/100)      60 px face: 12.0 px (0 %) · 24.6 px (70 %) · 30 px (100 %)
                                                  = 5 → 2.4 → 2 blocks across the face
```

`gaussianRadius(strength:face:)` / `pixelBlock(strength:face:)` in `Blur.swift`. The product cover is a body box that may have no
face: use **f ≈ cover width / 3** (shoulders ≈ 3 face widths, true for full-body and upper-body boxes alike; a height ratio is not).

## 3. Unrecognizability proxy (objective, automated)

Proxy: after blurring the crop, Vision `DetectFaceRectanglesRequest` finds **no face** AND `DetectFaceLandmarksRequest` yields
**no landmarks**. Test set: the largest face in each of 5 CC0 Commons portraits, cropped with one face-height of margin (grey
canvas where the photo ends), scaled to a 60 px face (and to 120 px with the sweep values doubled, to separate "the blur
destroyed the face" from "Vision is at its own size floor"). All 5 baselines (unblurred) are detected with landmarks at both
sizes. Sweep: radius 1–30 px, block 2–30 px. "Unrecognizable from" = smallest value from which the proxy holds for every
larger value.

| Face | Gaussian, 60 px | Gaussian, 120 px | Pixellate, 60 px | Pixellate, 120 px |
|---|---|---|---|---|
| 0 Face portrait (W. Stitt) | 4 | 8 | 3 | 6 |
| 1 Into the Deep (JD Mason) | 3 | 6 | 3 | 6 |
| 2 Confident Eye Contact (T. Heffner) | 4 | 8 | 3 | 4 |
| 3 Karen Elder (zjtcpts) | 5 | 10 | 4 | 6 |
| 4 Experience brings character. (A. Harvey) | 1 | 2 | 3 | 4 |
| **minimum over all faces** | **5 px** (0.083 f) | 10 px (= 5 at 60) | **4 px** (0.067 f) | 6 px (= 3 at 60) |

```
blur_min_radius_px face_px=60 value=5.0 faces=5 proxy=no_face_rect_and_no_landmarks
blur_min_block_px  face_px=60 value=4.0 faces=5 proxy=no_face_rect_and_no_landmarks
```

Why the curve's 0 % point is 2–3× above the proxy minimum: Vision drops out long before a person stops recognizing a face.
Looking at the dumped crops (one engineer, **not** the reviewer panel): Gaussian 5 px on a 60 px face is still a face-shaped
blob, 10 px is a smear; pixellate 4 px (15 blocks across the face) is plainly a face with eyes and smile, 8 px still shows
eyes/glasses as blocks, 12 px (5 blocks across) removes the features.

**The 3-reviewer human check is PENDING.** Review set: `swift run sitr-spike blur --skip-cost --dump <dir>` writes
`face<i>_<60|120>px_original.png`, `..._gaussian_<r>.png`, `..._pixellate_<b>.png` (photo fixtures, never screen pixels). The
reviewers should confirm or move the 0 % anchors (0.17 f / 0.20 f); the code constants are the only thing to change.

### Faces (downloaded by the rig into `Bench/data/faces`, not committed; all CC0 1.0, Unsplash imports on Wikimedia Commons)
- https://commons.wikimedia.org/wiki/File:Face_portrait_(Unsplash).jpg — William Stitt
- https://commons.wikimedia.org/wiki/File:Into_the_Deep_(Unsplash).jpg — JD Mason
- https://commons.wikimedia.org/wiki/File:Confident_Eye_Contact_(Unsplash).jpg — Tanja Heffner
- https://commons.wikimedia.org/wiki/File:Karen_Elder_(Unsplash).jpg — "Capturing the human heart." (zjtcpts)
- https://commons.wikimedia.org/wiki/File:Experience_brings_character._(Unsplash).jpg — Alex Harvey

## Done when
- ms per cover: table above (quiet phase: IOSurface path 0.3–0.6 ms for 60/120 px faces, 0.4–1.0 ms at 240 px).
- strength → radius and strength → block curves: recorded above and in code.
- 5 faces × objective proxy: done; **3 reviewers: pending**.
