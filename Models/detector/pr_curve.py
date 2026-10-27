#!/usr/bin/env python3
"""Recall vs false positives for PersonDetector-contract CoreML models, all thresholds from one pass. Research for
docs/models-2026.md; sitr-bench stays the reference for a single operating point (this mirrors it: frame long side 1280
with Lanczos, top-left 114-grey letterbox, Lanczos only below 0.9 scale, score = obj x person, NMS 0.5, one-to-one greedy
IoU >= 0.5, eligible GT >= 40 px and not crowd; small/ge80 tags as the bench).

  Models/venv/bin/python Models/detector/pr_curve.py Models/work/out/yolox_s_1280x768.mlpackage [more.mlpackage ...]

Prints, per model and threshold: recall all / ge80 / small on Bench/labels/recall-coco.json and false positives = person
detections on the 200 person-free COCO val images in Models/work/neg/neg.json.
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from torchvision.ops import box_iou, nms

ROOT = Path(__file__).resolve().parents[2]
THRESHOLDS = [0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50]


def frame(path):
    img = Image.open(path).convert("RGB")
    s = 1280 / max(img.size)
    return img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)


def detect(model, w, h, img, floor):
    r = min(w / img.width, h / img.height)
    scaled = img.resize((round(img.width * r), round(img.height * r)), Image.LANCZOS if r < 0.9 else Image.BILINEAR)
    canvas = Image.new("RGB", (w, h), (114, 114, 114))
    canvas.paste(scaled, (0, 0))
    p = model.predict({"image": canvas})["predictions"][0]
    score = p[:, 4] * p[:, 5]
    keep = score >= floor
    p, score = torch.from_numpy(p[keep, :4]), torch.from_numpy(score[keep])
    boxes = torch.cat([p[:, :2] - p[:, 2:] / 2, p[:, :2] + p[:, 2:] / 2], 1) / r
    k = nms(boxes, score, 0.5)
    return boxes[k], score[k]


def run(pkg, labels, neg):
    model = ct.models.MLModel(str(pkg), compute_units=ct.ComputeUnit.CPU_AND_NE)
    shape = model.get_spec().description.input[0].type.imageType
    w, h = shape.width, shape.height
    tally = {t: {"all": [0, 0], "ge80": [0, 0], "small": [0, 0], "fp": 0} for t in THRESHOLDS}
    for im in labels["images"]:
        img = frame(ROOT / "Bench/labels" / labels["images_dir"] / im["file"])
        sx = img.width / im["width"]
        boxes, scores = detect(model, w, h, img, THRESHOLDS[0])
        gts = [(np.array(p["box"]) * sx, p["tags"]) for p in im["persons"]]
        people = [(b, tags) for b, tags in gts if "crowd" not in tags]
        g = torch.tensor(np.array([[b[0], b[1], b[0] + b[2], b[1] + b[3]] for b, _ in people]), dtype=torch.float32).reshape(-1, 4)
        iou = box_iou(boxes, g) if len(people) else torch.zeros(len(boxes), 0)
        for t in THRESHOLDS:
            hit = [False] * len(people)
            for d in (scores >= t).nonzero().flatten().tolist():  # nms() returns score order
                best, bi = -1, 0.5
                for k in range(len(people)):
                    if not hit[k] and iou[d, k] >= bi:
                        best, bi = k, iou[d, k]
                if best >= 0:
                    hit[best] = True
            for k, (b, tags) in enumerate(people):
                if b[3] < 40:
                    continue
                for tag in ["all"] + (["ge80"] if b[3] >= 80 else []) + (["small"] if "small" in tags else []):
                    tally[t][tag][0] += hit[k]
                    tally[t][tag][1] += 1
    for im in neg["images"]:
        _, scores = detect(model, w, h, frame(ROOT / "Models/work/neg" / neg["images_dir"] / im["file"]), THRESHOLDS[0])
        for t in THRESHOLDS:
            tally[t]["fp"] += int((scores >= t).sum())
    for t in THRESHOLDS:
        v = tally[t]
        pct = lambda k: f"{100 * v[k][0] / v[k][1]:.1f}"
        print(f"curve model={pkg.stem} input={w}x{h} t={t:.2f} all={pct('all')} ge80={pct('ge80')} small={pct('small')} neg_fp={v['fp']}", flush=True)


if __name__ == "__main__":
    labels = json.load(open(ROOT / "Bench/labels/recall-coco.json"))
    neg = json.load(open(ROOT / "Models/work/neg/neg.json"))
    for pkg in sys.argv[1:]:
        run(Path(pkg), labels, neg)
