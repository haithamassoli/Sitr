#!/usr/bin/env python3
"""YOLOv9 -> CoreML in the PersonDetector contract, so CoreMLPersonDetector and sitr-bench load it unchanged. Research
for docs/models-2026.md. Two weight sources:

MIT re-release by the YOLOv9 authors (MultimediaTechLab/YOLO, "work in progress, not for production"):
  git clone --depth 1 --branch v1.0 https://github.com/MultimediaTechLab/YOLO.git Models/work/YOLOmtl   # c4cb5f6f
  curl -L -o Models/work/weights/v9-s.pt https://github.com/MultimediaTechLab/YOLO/releases/download/v1.0-alpha/v9-s.pt
  Models/venv/bin/pip install einops omegaconf hydra-core rich requests
  Models/venv/bin/python Models/detector/convert_yolov9.py --model s --size 1024x640

Official GPL-3.0 release (WongKinYiu/yolov9, deploy weights `yolov9-<m>-converted.pt`, release v0.1):
  git clone --depth 1 https://github.com/WongKinYiu/yolov9.git Models/work/yolov9gpl                    # 5b1ea9a8
  curl -L -o Models/work/weights/yolov9-s-converted.pt https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-s-converted.pt
  Models/venv/bin/python Models/detector/convert_yolov9.py --official --model s --size 1024x640

Contract (as convert_yolox.py, except the declared channel order): `image` WxH, declared RGB 0-255, so CoreML reorders
the app's BGRA buffer itself (an in-graph flip was a CPU `reverse` op); the graph rescales 1/255 (both repos). The repos
letterbox centred with 114 grey; the app pastes top-left, which a conv net does not mind.
Output `predictions` [1, N, 85]: cx, cy, w, h in input pixels, objectness = 1, 80 sigmoid class scores (YOLOv9 has
no objectness; score = class score). MIT: only the "Main" head is exported (the auxiliary branch is training-only), and
`Anchor2Vec`'s Conv3d (DFL expectation) is rewritten as softmax + weighted sum on 4-D tensors (exact). Official: the
`DDetect` head in export mode already returns [1, 84, N] decoded xywh + sigmoid classes.
"""
import argparse
import sys
import types
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

import ct_patches  # noqa: F401  coremltools int() cast fix

ROOT = Path(__file__).resolve().parents[2]


def load_mit(name):
    repo = ROOT / "Models/work/YOLOmtl"
    # Import yolo.model.* without yolo/__init__.py (it pulls lightning, wandb, the trainer).
    pkg = types.ModuleType("yolo")
    pkg.__path__ = [str(repo / "yolo")]
    sys.modules["yolo"] = pkg
    log = types.ModuleType("yolo.utils.logger")  # the real one imports lightning for rank_zero_only
    from loguru import logger
    log.logger = logger
    sys.modules["yolo.utils.logger"] = log
    from omegaconf import OmegaConf
    from yolo.model.yolo import create_model
    cfg = OmegaConf.load(repo / f"yolo/config/model/v9-{name}.yaml")
    return create_model(cfg, weight_path=ROOT / f"Models/work/weights/v9-{name}.pt", class_num=80).eval()


def load_official(name):
    sys.path.insert(0, str(ROOT / "Models/work/yolov9gpl"))
    _load = torch.load  # the 2024 checkpoint pickles the model; torch >= 2.6 defaults to weights_only
    torch.load = lambda *a, **k: _load(*a, **{**k, "weights_only": False})
    from models.experimental import attempt_load
    model = attempt_load(str(ROOT / f"Models/work/weights/yolov9-{name}-converted.pt"), device="cpu", fuse=True).float().eval()
    torch.load = _load
    model.model[-1].export = True
    return model


class Official(torch.nn.Module):
    def __init__(self, model, n):
        super().__init__()
        self.model = model
        self.register_buffer("ones", torch.ones(1, n, 1))

    def forward(self, rgb):
        y = self.model(rgb / 255.0).transpose(1, 2)  # B N 84: cx cy w h (px), 80 sigmoid classes
        return torch.cat([y[..., :4], self.ones, y[..., 4:]], -1)


def generate_anchors(image_size, strides):
    """bounding_box_utils.generate_anchors (that module imports torchmetrics): cell centres in px and their stride."""
    w, h = image_size
    anchors, scaler = [], []
    for s in strides:
        ay, ax = torch.meshgrid(torch.arange(0, h, s) + s // 2, torch.arange(0, w, s) + s // 2, indexing="ij")
        anchors.append(torch.stack([ax.flatten(), ay.flatten()], -1))
        scaler.append(torch.full((ax.numel(),), s))
    return torch.cat(anchors), torch.cat(scaler)


class Wrapped(torch.nn.Module):
    def __init__(self, model, w, h, reg_max=16):
        super().__init__()
        self.model, self.reg_max = model, reg_max
        with torch.no_grad():
            heads = model(torch.zeros(1, 3, h, w))["Main"]
        strides = [w // head[2].shape[-1] for head in heads]
        anchors, scaler = generate_anchors([w, h], strides)
        self.register_buffer("anchors", anchors.float()[None])  # [1, N, 2] x, y
        self.register_buffer("scaler", scaler.float()[None, :, None])  # [1, N, 1]
        self.register_buffer("bins", torch.arange(reg_max, dtype=torch.float32).view(1, 1, reg_max, 1))
        self.register_buffer("ones", torch.ones(1, anchors.shape[0], 1))  # objectness; ones_like ran on the CPU

    def forward(self, rgb):
        heads = self.model(rgb / 255.0)["Main"]
        cls, ltrb = [], []
        for c, anchor_x, _ in heads:  # anchor_x: B R P h w (raw logits, rearranged by Anchor2Vec)
            b, _, _, hh, ww = anchor_x.shape
            cls.append(c.flatten(2))  # B 80 hw
            a = anchor_x.permute(0, 2, 1, 3, 4).reshape(b, 4, self.reg_max, hh * ww)
            ltrb.append((a.softmax(dim=2) * self.bins).sum(dim=2))  # B 4 hw
        cls = torch.cat(cls, 2).transpose(1, 2).sigmoid()  # B N 80
        d = torch.cat(ltrb, 2).transpose(1, 2) * self.scaler  # B N 4 (l, t, r, b) in px
        x1y1, x2y2 = self.anchors - d[..., :2], self.anchors + d[..., 2:]
        box = torch.cat([(x1y1 + x2y2) / 2, x2y2 - x1y1], -1)
        return torch.cat([box, self.ones, cls], -1)


def letterbox(path, w, h):
    img = Image.open(path).convert("RGB")
    r = min(w / img.width, h / img.height)
    canvas = Image.new("RGB", (w, h), (114, 114, 114))
    canvas.paste(img.resize((round(img.width * r), round(img.height * r)), Image.BILINEAR), (0, 0))
    return canvas, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="s", help="t, s, m, c")
    ap.add_argument("--official", action="store_true", help="WongKinYiu/yolov9 GPL-3.0 weights instead of the MIT re-release")
    ap.add_argument("--size", default="1024x640")
    ap.add_argument("--out")
    ap.add_argument("--image", default=str(ROOT / "Tests/SitrDetectTests/Fixtures/person.jpg"))
    a = ap.parse_args()
    w, h = map(int, a.size.split("x"))
    tag = "yolov9gpl" if a.official else "yolov9"
    out = Path(a.out or ROOT / f"Models/work/out/{tag}_{a.model}_{a.size}.mlpackage")

    if a.official:
        net = Official(load_official(a.model), sum((w // s) * (h // s) for s in (8, 16, 32))).eval()
    else:
        net = Wrapped(load_mit(a.model), w, h).eval()
    canvas, r = letterbox(a.image, w, h)
    x = torch.from_numpy(np.asarray(canvas).copy()).permute(2, 0, 1)[None].float()
    with torch.no_grad():
        ref = net(x)[0].numpy()
        traced = torch.jit.trace(net, x)
    ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                    minimum_deployment_target=ct.target.macOS15,
                    inputs=[ct.ImageType(name="image", shape=x.shape, color_layout=ct.colorlayout.RGB, scale=1, bias=[0, 0, 0])],
                    outputs=[ct.TensorType(name="predictions", dtype=np.float32)])
    ml.short_description = f"YOLOv9-{a.model} ({'WongKinYiu/yolov9 v0.1, GPL-3.0' if a.official else 'MultimediaTechLab/YOLO v1.0, MIT'}) person detector, PersonDetector contract, {w}x{h}"
    ml.save(out)
    got = ml.predict({"image": canvas})["predictions"][0]

    def top(rows):
        i = int(np.argmax(rows[:, 5]))
        cx, cy, bw, bh = rows[i, :4] / r
        return f"[x={cx - bw / 2:.0f},y={cy - bh / 2:.0f},w={bw:.0f},h={bh:.0f},score={rows[i, 5]:.3f}]"

    keep = ref[:, 5] >= 0.3
    print(f"verify model={tag}-{a.model} size={a.size} out={out} rows_ref={keep.sum()} rows_coreml={(got[:, 5] >= 0.3).sum()} "
          f"max_abs_diff_box_px={np.abs(ref[keep, :4] - got[keep, :4]).max(initial=0):.2f} max_abs_diff_score={np.abs(ref[keep, 5] - got[keep, 5]).max(initial=0):.4f} "
          f"top_ref={top(ref)} top_coreml={top(got)}")


if __name__ == "__main__":
    main()
