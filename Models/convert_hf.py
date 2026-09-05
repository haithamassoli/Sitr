#!/usr/bin/env python
"""Convert a Hugging Face image-classification checkpoint (ViT / ResNet / ...) to CoreML.

usage: Models/venv/bin/python Models/convert_hf.py <hf-repo-or-local-dir> <out.mlpackage> [--revision SHA] [--license TEXT]

Result: ML Program, fp16 weights, macOS 15+. Input `image` (RGB, the model's native size, 0-255 pixels;
mean/std normalisation lives inside the graph), output `probs` = softmax [P(woman), P(man)].
Ends with a PyTorch-vs-CoreML parity check on a random image (CoreML runs in-process on macOS).
"""
import argparse
import json
import os

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import hf_hub_download
from PIL import Image
from transformers import AutoModelForImageClassification

ap = argparse.ArgumentParser()
ap.add_argument("src")
ap.add_argument("out")
ap.add_argument("--revision", default=None)
ap.add_argument("--license", default="see Models/dist/SOURCE.md")
ap.add_argument("--int8", action="store_true", help="linear per-channel int8 weight quantization (halves the fp16 size)")
a = ap.parse_args()

model = AutoModelForImageClassification.from_pretrained(a.src, revision=a.revision).eval()
# ponytail: read preprocessor_config.json by hand; transformers 5 no longer knows old processor class names
pp = os.path.join(a.src, "preprocessor_config.json") if os.path.isdir(a.src) else hf_hub_download(a.src, "preprocessor_config.json", revision=a.revision)
proc = json.load(open(pp))
size = proc["size"].get("height") or proc["size"].get("shortest_edge")
mean = torch.tensor(proc["image_mean"]).view(1, 3, 1, 1)
std = torch.tensor(proc["image_std"]).view(1, 3, 1, 1)
labels = {int(k): v.lower() for k, v in model.config.id2label.items()}
woman = next(i for i, l in labels.items() if l.startswith(("f", "w")))  # "Female" / "woman"
man = next(i for i in labels if i != woman)
print(f"labels {labels} -> probs[0]={labels[woman]} probs[1]={labels[man]}; input {size}x{size}; mean {proc['image_mean']} std {proc['image_std']}")


class Wrapped(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.m = model.requires_grad_(False)
        self.register_buffer("mean", mean)
        self.register_buffer("std", std)

    def forward(self, x):  # x: 1x3xHxW in [0, 1]
        p = torch.softmax(self.m(pixel_values=(x - self.mean) / self.std).logits, dim=-1)
        return torch.stack([p[:, woman], p[:, man]], dim=-1)


w = Wrapped().eval()
example = torch.rand(1, 3, size, size)
with torch.no_grad():
    traced = torch.jit.trace(w, example)
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="probs")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
if a.int8:
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

    ml = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")))
ml.short_description = f"Face gender classifier, probs = [P(woman), P(man)]. Converted from {a.src}{' (int8 weights)' if a.int8 else ''}."
ml.license = a.license
ml.user_defined_metadata["source"] = a.src
ml.user_defined_metadata["revision"] = str(a.revision)
ml.user_defined_metadata["labels"] = "probs[0]=woman probs[1]=man"
ml.save(a.out)
mb = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(a.out) for f in fs) / 1e6
print(f"saved {a.out} ({mb:.1f} MB)")

# parity: full-precision torch vs fp16 CoreML on the same random image
img = Image.fromarray((np.random.RandomState(0).rand(size, size, 3) * 255).astype("uint8"))
with torch.no_grad():
    ref = w(torch.from_numpy(np.asarray(img).astype("float32") / 255).permute(2, 0, 1)[None]).numpy()[0]
got = np.asarray(ml.predict({"image": img})["probs"]).reshape(-1)
print(f"parity torch={ref} coreml={got} maxdiff={float(np.abs(ref - got).max()):.4f}")
