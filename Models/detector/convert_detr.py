#!/usr/bin/env python3
"""Hugging Face DETR-family detectors (D-FINE, RT-DETRv2; Apache-2.0) -> CoreML in the PersonDetector contract, so
CoreMLPersonDetector and sitr-bench load them unchanged. Research for docs/models-2026.md.

  Models/venv/bin/python Models/detector/convert_detr.py ustc-community/dfine-small-coco --size 1280x768 [--revision <sha>]

Contract (same as convert_yolox.py): image input `image` WxH, CoreML declares BGR so a BGRA buffer feeds it as YOLOX does;
the graph reorders to RGB and rescales 1/255 (the checkpoints' processor: do_rescale, no normalisation). Output
`predictions` [1, Q, 85]: cx, cy, w, h in input pixels, objectness = 1, 80 sigmoid class scores. The app's 114-grey
top-left letterbox is fed to a model trained on plain resize; the bench measures what that costs.
"""
import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import AutoModelForObjectDetection

ROOT = Path(__file__).resolve().parents[2]

import ct_patches  # noqa: F401,E402  (sys.path[0] is this directory)


class Wrapped(torch.nn.Module):
    def __init__(self, model, w, h):
        super().__init__()
        self.model, self.w, self.h = model, w, h

    def forward(self, bgr):  # 0-255 BGR, as CoreML hands it over
        out = self.model(pixel_values=bgr.flip(1) / 255.0)
        b = out.pred_boxes * torch.tensor([self.w, self.h, self.w, self.h], dtype=bgr.dtype)
        cls = out.logits.sigmoid()
        return torch.cat([b, torch.ones_like(cls[..., :1]), cls], dim=-1)


def cached(fwd):
    memo = {}

    def run(*args, **kw):
        key = (args, tuple(sorted((k, str(v)) for k, v in kw.items())))
        if key not in memo:
            memo[key] = fwd(*args, **kw).detach()
        return memo[key]
    return run


def letterbox(path, w, h):
    img = Image.open(path).convert("RGB")
    r = min(w / img.width, h / img.height)
    canvas = Image.new("RGB", (w, h), (114, 114, 114))
    canvas.paste(img.resize((round(img.width * r), round(img.height * r)), Image.BILINEAR), (0, 0))
    return canvas, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--size", default="1280x768")
    ap.add_argument("--revision")
    ap.add_argument("--out")
    ap.add_argument("--image", default=str(ROOT / "Tests/SitrDetectTests/Fixtures/person.jpg"))
    a = ap.parse_args()
    w, h = map(int, a.size.split("x"))
    out = Path(a.out or ROOT / f"Models/work/out/{a.repo.split('/')[-1]}_{a.size}.mlpackage")

    # Anchors for the fixed input size are built at init (constants); sine position embeddings are cached by the eager
    # reference run below so the trace sees constants (coremltools mis-types their float64 arange/outer otherwise).
    model = AutoModelForObjectDetection.from_pretrained(a.repo, revision=a.revision, anchor_image_size=[h, w]).eval()
    for m in model.modules():
        if "PositionEmbedding" in type(m).__name__:
            m.forward = cached(m.forward)
    net = Wrapped(model, w, h).eval()
    canvas, r = letterbox(a.image, w, h)
    x = torch.from_numpy(np.asarray(canvas)[:, :, ::-1].copy()).permute(2, 0, 1)[None].float()  # BGR
    with torch.no_grad():
        ref = net(x)[0].numpy()
        traced = torch.jit.trace(net, x, check_trace=False)
    ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                    minimum_deployment_target=ct.target.macOS15,
                    inputs=[ct.ImageType(name="image", shape=x.shape, color_layout=ct.colorlayout.BGR, scale=1, bias=[0, 0, 0])],
                    outputs=[ct.TensorType(name="predictions", dtype=np.float32)])
    ml.short_description = f"{a.repo}@{a.revision or "main"} person detector, PersonDetector contract, {w}x{h}"
    ml.save(out)
    got = ml.predict({"image": canvas.convert("RGB")})["predictions"][0]  # PIL RGB; CoreML reorders to the declared BGR

    def top(rows):
        i = int(np.argmax(rows[:, 5]))
        cx, cy, bw, bh = rows[i, :4] / r
        return f"[x={cx - bw / 2:.0f},y={cy - bh / 2:.0f},w={bw:.0f},h={bh:.0f},score={rows[i, 5]:.3f}]"

    keep = ref[:, 5] >= 0.3
    print(f"verify repo={a.repo} size={a.size} out={out} rows_ref={keep.sum()} rows_coreml={(got[:, 5] >= 0.3).sum()} "
          f"max_abs_diff_box_px={np.abs(ref[keep, :4] - got[keep, :4]).max(initial=0):.2f} max_abs_diff_score={np.abs(ref[keep, 5] - got[keep, 5]).max(initial=0):.4f} "
          f"top_ref={top(ref)} top_coreml={top(got)}")


if __name__ == "__main__":
    main()
