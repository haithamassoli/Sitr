#!/usr/bin/env python
"""Fine-tune a small ImageNet-pretrained CNN (timm, Apache-2.0 weights) on FairFace face crops and export CoreML.

usage: Models/venv/bin/python Models/train_torch.py [--arch mobilenetv3_large_100.ra_in1k] [--epochs 4]
                                                   [--data Models/work/fairface_1.25_crops] [--out Models/work/sitr_mnv3.mlpackage]

Data layout: <data>/{train,val}/{woman,man}/*.jpg — produced by `Models/fairface.py export` followed by
`sitr-spike classifier --crop-dir`, so the model trains on exactly the crop the app produces. Output contract is the
same as convert_hf.py: image input (0-255, normalisation in-graph), `probs` = softmax [P(woman), P(man)].
Trains on Apple GPU (MPS) when available.
"""
import argparse
import os
import time

import coremltools as ct
import numpy as np
import timm
import torch
from PIL import Image
from torchvision import datasets, transforms

HERE = os.path.dirname(os.path.abspath(__file__))
MEAN, STD = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]


class Wrapped(torch.nn.Module):
    """[0,1] image -> normalise -> backbone -> softmax -> [P(woman), P(man)]."""

    def __init__(self, model, woman):
        super().__init__()
        self.m = model.requires_grad_(False)
        self.woman, self.man = woman, 1 - woman
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, x):
        p = torch.softmax(self.m((x - self.mean) / self.std), dim=-1)
        return torch.stack([p[:, self.woman], p[:, self.man]], dim=-1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="mobilenetv3_large_100.ra_in1k")
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--size", type=int, default=224)
    ap.add_argument("--data", default=os.path.join(HERE, "work", "fairface_1.25_crops"))
    ap.add_argument("--out", default=os.path.join(HERE, "work", "sitr_mnv3.mlpackage"))
    a = ap.parse_args()

    torch.manual_seed(0)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    # augmentation mirrors what the app sees: loose/tight framing, mirrored faces, dark or greyscale (B/W photos) frames
    train_tf = transforms.Compose([
        transforms.RandomResizedCrop(a.size, scale=(0.6, 1.0), ratio=(0.9, 1.1)),
        transforms.RandomHorizontalFlip(),
        transforms.ColorJitter(brightness=(0.25, 1.2), contrast=0.3, saturation=0.3),
        transforms.RandomGrayscale(p=0.15),
        transforms.ToTensor(),
        transforms.Normalize(MEAN, STD),
    ])
    val_tf = transforms.Compose([transforms.Resize((a.size, a.size)), transforms.ToTensor(), transforms.Normalize(MEAN, STD)])
    train_ds = datasets.ImageFolder(os.path.join(a.data, "train"), train_tf)
    val_ds = datasets.ImageFolder(os.path.join(a.data, "val"), val_tf)
    woman = train_ds.classes.index("woman")
    train_dl = torch.utils.data.DataLoader(train_ds, batch_size=a.batch, shuffle=True, num_workers=6, persistent_workers=True)
    val_dl = torch.utils.data.DataLoader(val_ds, batch_size=a.batch, shuffle=False, num_workers=6, persistent_workers=True)
    print(f"device {dev}; train {len(train_ds)} val {len(val_ds)} classes {train_ds.classes}", flush=True)

    model = timm.create_model(a.arch, pretrained=True, num_classes=2).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.02)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=a.epochs * len(train_dl), pct_start=0.15)
    loss_fn = torch.nn.CrossEntropyLoss(label_smoothing=0.05)

    def evaluate():
        model.eval()
        correct = n = 0
        with torch.no_grad():
            for x, y in val_dl:
                correct += (model(x.to(dev)).argmax(1).cpu() == y).sum().item()
                n += len(y)
        model.train()
        return correct / n

    best, best_state = 0.0, None
    for epoch in range(a.epochs):
        t0 = time.time()
        model.train()
        for i, (x, y) in enumerate(train_dl):
            loss = loss_fn(model(x.to(dev)), y.to(dev))
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            if i % 50 == 0:
                print(f"  epoch {epoch} step {i}/{len(train_dl)} loss {loss.item():.3f}", flush=True)
        acc = evaluate()
        print(f"epoch {epoch} val_acc {acc:.4f} seconds {time.time() - t0:.0f}", flush=True)
        if acc > best:
            best, best_state = acc, {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}

    model.load_state_dict(best_state)
    model.cpu().eval()
    torch.save(best_state, a.out.replace(".mlpackage", ".pt"))
    print(f"best val_acc {best:.4f}")

    w = Wrapped(model, woman).eval()
    example = torch.rand(1, 3, a.size, a.size)
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
    ml.author = "Sitr"
    ml.license = f"Apache-2.0 (weights, Sitr; backbone timm/{a.arch} Apache-2.0). Training data: FairFace, CC BY 4.0."
    ml.short_description = f"Face gender classifier, probs = [P(woman), P(man)]. {a.arch} fine-tuned on FairFace 1.25 crops."
    ml.user_defined_metadata["source"] = f"Models/train_torch.py --arch {a.arch} --epochs {a.epochs} --size {a.size}; val_acc {best:.4f}"
    ml.user_defined_metadata["labels"] = "probs[0]=woman probs[1]=man"
    ml.save(a.out)
    mb = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(a.out) for f in fs) / 1e6
    img = Image.fromarray((np.random.RandomState(0).rand(a.size, a.size, 3) * 255).astype("uint8"))
    with torch.no_grad():
        ref = w(torch.from_numpy(np.asarray(img).astype("float32") / 255).permute(2, 0, 1)[None]).numpy()[0]
    got = np.asarray(ml.predict({"image": img})["probs"]).reshape(-1)
    print(f"saved {a.out} ({mb:.1f} MB); parity torch={ref} coreml={got} maxdiff={float(np.abs(ref - got).max()):.4f}")


if __name__ == "__main__":
    main()
