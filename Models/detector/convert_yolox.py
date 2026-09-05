#!/usr/bin/env python3
"""YOLOX (Megvii, Apache-2.0) -> CoreML ML Program (fp16) person detector for Sitr. Spike M1-T06b.

  /opt/homebrew/opt/python@3.12/bin/python3.12 -m venv Models/venv
  Models/venv/bin/pip install torch torchvision coremltools numpy pillow opencv-python-headless loguru thop psutil tabulate
  Models/venv/bin/python Models/detector/convert_yolox.py --fetch                # source tarball + weights -> Models/work/
  Models/venv/bin/python Models/detector/convert_yolox.py --models tiny,s,m --sizes 640x384,1280x768
  Models/venv/bin/python Models/detector/convert_yolox.py --models s --sizes 1280x768 --dist   # -> Models/dist/PersonDetector.mlpackage

Every conversion is verified against PyTorch on --image (default: the test fixture) and prints one `verify ...` line.

Input contract (YOLOX's non-legacy ValTransform, see yolox/data/data_augment.py `preproc`): raw 0-255 pixels, BGR
channel order, resized by r = min(W/w, H/h) into a WxH canvas filled with 114 grey, top-left aligned, no mean/std.
Output `predictions` [1, N, 85] float32 per row: cx, cy, w, h in input pixels (decoded), objectness, 80 COCO class
scores (sigmoid). Person = class 0, score = objectness * class score.
"""
import argparse
import hashlib
import shutil
import sys
import tarfile
import types
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "Models" / "work"
YOLOX = WORK / "YOLOX"
WEIGHTS = WORK / "weights"
OUT = WORK / "out"
DIST = ROOT / "Models" / "dist"

SOURCE_TAG = "0.3.0"
SOURCE_URL = f"https://github.com/Megvii-BaseDetection/YOLOX/archive/refs/tags/{SOURCE_TAG}.tar.gz"
WEIGHTS_TAG = "0.1.1rc0"
WEIGHTS_URL = f"https://github.com/Megvii-BaseDetection/YOLOX/releases/download/{WEIGHTS_TAG}/"
MODELS = {"tiny": "yolox-tiny", "s": "yolox-s", "m": "yolox-m"}  # exp name; weights file = yolox_<name>.pth
PERSON_THRESHOLD = 0.3


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, dest):
    if dest.exists():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=120) as r, open(part, "wb") as f:
        shutil.copyfileobj(r, f)
    part.rename(dest)


def fetch_all():
    tarball = WORK / f"yolox-{SOURCE_TAG}.tar.gz"
    fetch(SOURCE_URL, tarball)
    if not YOLOX.exists():
        with tarfile.open(tarball) as t:
            t.extractall(WORK, filter="data")
        (WORK / f"YOLOX-{SOURCE_TAG}").rename(YOLOX)
    print(f"source tag={SOURCE_TAG} url={SOURCE_URL} sha256={sha256(tarball)}")
    for name in MODELS:
        dest = WEIGHTS / f"yolox_{name}.pth"
        fetch(WEIGHTS_URL + dest.name, dest)
        print(f"weights model={name} file={dest.name} url={WEIGHTS_URL + dest.name} sha256={sha256(dest)} bytes={dest.stat().st_size}")


def load_model(name):
    import torch

    sys.path.insert(0, str(YOLOX))
    from yolox.exp import get_exp

    exp = get_exp(None, MODELS[name])
    model = exp.get_model()
    ckpt = torch.load(WEIGHTS / f"yolox_{name}.pth", map_location="cpu", weights_only=False)
    model.load_state_dict(ckpt["model"])
    model.eval()
    model.head.decode_in_inference = True  # output [1, N, 85] with boxes in input pixels
    model.head.decode_outputs = types.MethodType(decode_outputs, model.head)
    ane_friendly_spp(model)
    return model


def ane_friendly_spp(model):
    """SPPBottleneck's 9x9 and 13x13 stride-1 max pools are scheduled on the CPU by CoreML (two ANE->CPU->ANE hops per
    frame). k stacked 5x5 stride-1 pools equal one (4k+1)x(4k+1) pool exactly (max is associative; -inf padding), so
    9 -> 2 x 5 and 13 -> 3 x 5 keep the network on the Neural Engine with identical outputs."""
    import torch.nn as nn
    from yolox.models.network_blocks import SPPBottleneck

    for module in model.modules():
        if isinstance(module, SPPBottleneck):
            sizes = [m.kernel_size for m in module.m]
            module.m = nn.ModuleList(nn.Sequential(*[nn.MaxPool2d(5, 1, 2) for _ in range((k - 1) // 4)]) for k in sizes)
            assert sizes == [5, 9, 13], sizes


def decode_outputs(self, outputs, dtype):
    """YOLOXHead.decode_outputs without the in-place slice writes (coremltools 9 rejects `outputs[..., :2] = ...`).
    Same math as yolox/models/yolo_head.py; the grid/stride tensors become constants in the trace."""
    import torch
    from yolox.utils import meshgrid

    grids, strides = [], []
    for (hsize, wsize), stride in zip(self.hw, self.strides):
        yv, xv = meshgrid([torch.arange(hsize), torch.arange(wsize)])
        grid = torch.stack((xv, yv), 2).view(1, -1, 2)
        grids.append(grid)
        strides.append(torch.full((*grid.shape[:2], 1), stride))
    grids = torch.cat(grids, dim=1).type(dtype)
    strides = torch.cat(strides, dim=1).type(dtype)
    return torch.cat([(outputs[..., :2] + grids) * strides, torch.exp(outputs[..., 2:4]) * strides, outputs[..., 4:]], dim=-1)


def preproc(img_bgr, w, h):
    """YOLOX ValTransform (legacy=False): 114-grey WxH canvas, image scaled by r and pasted top-left. CHW float32."""
    import cv2
    import numpy as np

    canvas = np.full((h, w, 3), 114, dtype=np.uint8)
    r = min(w / img_bgr.shape[1], h / img_bgr.shape[0])
    rw, rh = int(img_bgr.shape[1] * r), int(img_bgr.shape[0] * r)
    canvas[:rh, :rw] = cv2.resize(img_bgr, (rw, rh), interpolation=cv2.INTER_LINEAR)
    return canvas.transpose(2, 0, 1).astype(np.float32), r


def convert(name, w, h, force):
    import coremltools as ct
    import numpy as np
    import torch

    out = OUT / f"yolox_{name}_{w}x{h}.mlpackage"
    if out.exists() and not force:
        print(f"convert model={name} size={w}x{h} out={out.relative_to(ROOT)} (exists, skipped)")
        return out
    t0 = time.time()
    model = load_model(name)
    with torch.no_grad():
        traced = torch.jit.trace(model, torch.zeros(1, 3, h, w))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, h, w), color_layout=ct.colorlayout.BGR, scale=1.0, bias=[0.0, 0.0, 0.0])],
        outputs=[ct.TensorType(name="predictions", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.author = "Megvii, Inc. and its affiliates (YOLOX); converted for Sitr"
    mlmodel.license = "Apache-2.0 (see LICENSE-YOLOX.txt)"
    mlmodel.version = f"yolox-{name} weights {WEIGHTS_TAG}, source {SOURCE_TAG}"
    mlmodel.short_description = (
        f"YOLOX-{name} COCO detector. Input: {w}x{h} BGR 0-255, letterbox with 114 grey top-left. "
        "Output predictions [1,N,85]: cx,cy,w,h (input px), objectness, 80 class scores; person = class 0."
    )
    mlmodel.user_defined_metadata.update({
        "source": SOURCE_URL, "weights": WEIGHTS_URL + f"yolox_{name}.pth", "weights_sha256": sha256(WEIGHTS / f"yolox_{name}.pth"),
        "training_data": "COCO train2017", "input": f"{w}x{h} BGR 0-255 letterbox 114 top-left", "output": "[1,N,85] cx,cy,w,h,obj,80 cls",
    })
    if out.exists():
        shutil.rmtree(out)
    mlmodel.save(str(out))
    mb = sum(p.stat().st_size for p in out.rglob("*") if p.is_file()) / 1e6
    print(f"convert model={name} size={w}x{h} out={out.relative_to(ROOT)} package_mb={mb:.1f} seconds={time.time() - t0:.0f}")
    return out


def verify(name, w, h, package, image):
    """PyTorch vs CoreML on one image: max abs diff over the rows PyTorch scores as person >= threshold."""
    import coremltools as ct
    import cv2
    import numpy as np
    import torch
    from PIL import Image

    img = cv2.imread(str(image))  # BGR, like YOLOX's own loader
    x, r = preproc(img, w, h)
    with torch.no_grad():
        model = load_model(name)
        ref = model(torch.from_numpy(x).unsqueeze(0))[0].numpy()
        # the SPP rewrite must be an identity: compare against the stock 5/9/13 pools
        from yolox.models.network_blocks import SPPBottleneck
        import torch.nn as nn
        for module in model.modules():
            if isinstance(module, SPPBottleneck):
                module.m = nn.ModuleList([nn.MaxPool2d(k, 1, k // 2) for k in (5, 9, 13)])
        stock = model(torch.from_numpy(x).unsqueeze(0))[0].numpy()
        spp_diff = float(np.abs(stock - ref).max())
        assert spp_diff < 1e-3, f"SPP rewrite changed the PyTorch output by {spp_diff}"
    # coremltools takes a PIL (RGB) image; CoreML reorders to the model's declared BGR layout.
    pil = Image.fromarray(np.ascontiguousarray(x.transpose(1, 2, 0).astype(np.uint8)[:, :, ::-1]))
    got = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL).predict({"image": pil})["predictions"][0]
    score_ref, score_got = ref[:, 4] * ref[:, 5], got[:, 4] * got[:, 5]
    keep = score_ref >= PERSON_THRESHOLD
    box_diff = float(np.abs(ref[keep, :4] - got[keep, :4]).max()) if keep.any() else float("nan")
    score_diff = float(np.abs(score_ref[keep] - score_got[keep]).max()) if keep.any() else float("nan")

    def top(rows, scores):
        i = int(scores.argmax())
        cx, cy, bw, bh = rows[i, :4] / r  # back to source pixels
        return f"x={cx - bw / 2:.0f},y={cy - bh / 2:.0f},w={bw:.0f},h={bh:.0f},score={scores[i]:.3f}"

    print(f"verify model={name} size={w}x{h} image={Path(image).name} rows_ref={int(keep.sum())} rows_coreml={int((score_got >= PERSON_THRESHOLD).sum())} "
          f"max_abs_diff_box_px={box_diff:.3f} max_abs_diff_score={score_diff:.4f} spp_rewrite_diff={spp_diff:.2e} "
          f"top_ref=[{top(ref, score_ref)}] top_coreml=[{top(got, score_got)}]")


def ship(package):
    dest = DIST / "PersonDetector.mlpackage"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(package, dest)
    shutil.copy(YOLOX / "LICENSE", DIST / "LICENSE-YOLOX.txt")
    files = sorted(p for p in dest.rglob("*") if p.is_file())
    (DIST / "CHECKSUMS-PersonDetector.txt").write_text("".join(f"{sha256(p)}  {p.relative_to(DIST)}\n" for p in files))
    mb = sum(p.stat().st_size for p in files) / 1e6
    print(f"ship from={package.relative_to(ROOT)} to={dest.relative_to(ROOT)} files={len(files)} package_mb={mb:.1f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true", help="download YOLOX source tarball and weights into Models/work/")
    ap.add_argument("--models", default="", help="comma list of tiny,s,m")
    ap.add_argument("--sizes", default="640x384,1280x768", help="comma list of WxH (multiples of 32)")
    ap.add_argument("--image", default=str(ROOT / "Tests/SitrDetectTests/Fixtures/person.jpg"))
    ap.add_argument("--force", action="store_true", help="reconvert even if the package exists")
    ap.add_argument("--no-verify", action="store_true")
    ap.add_argument("--dist", action="store_true", help="copy the (single) converted package to Models/dist/PersonDetector.mlpackage")
    args = ap.parse_args()
    if args.fetch:
        fetch_all()
    OUT.mkdir(parents=True, exist_ok=True)
    jobs = [(m, *map(int, s.split("x"))) for m in filter(None, args.models.split(",")) for s in args.sizes.split(",")]
    packages = []
    for name, w, h in jobs:
        assert w % 32 == 0 and h % 32 == 0, "input sides must be multiples of 32"
        package = convert(name, w, h, args.force)
        if not args.no_verify:
            verify(name, w, h, package, args.image)
        packages.append(package)
    if args.dist:
        assert len(packages) == 1, "--dist ships exactly one model: pass one --models and one --sizes"
        ship(packages[0])


if __name__ == "__main__":
    main()
