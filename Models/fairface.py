#!/usr/bin/env python
"""FairFace helpers (HuggingFaceM4/FairFace, CC BY 4.0). Everything lands in Models/work/ (gitignored) except
the manifest entries `children` appends to Models/eval/manifest.json.

  fairface.py export    [--padding 1.25] [--train-per-class 3000] [--val-per-class 500]
      -> Models/work/fairface_<pad>/{train,val}/{woman,man}/<row>.jpg, Create ML labeled directories sampled
         from the first FairFace *train* shard (the FairFace validation split stays a benchmark).
  fairface.py children  [--padding 1.25] [--n 40]
      -> appends `child`-tagged validation faces (age buckets 0-2, 3-9, 10-19) to the eval manifest.
  fairface.py benchmark [--padding 1.25] [--n 1000]
      -> Models/work/ffval/manifest.json + images: a validation subset for `sitr-spike classifier --eval`.
Shards are downloaded on first use. Padding 1.25 gives loose crops so the app's Vision face box + 20 % margin
can be applied; 0.25 is the tight dlib chip the public FairFace models were trained on.
"""
import argparse
import os
import random
from io import BytesIO

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download
from PIL import Image

from fetch_eval_faces import FACES, load_manifest, save_manifest

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
REPO = "HuggingFaceM4/FairFace"
SHARDS = {  # (padding, split) -> parquet path in the repo
    ("0.25", "train"): "0.25/train-00000-of-00002-d405faba4f4b9b85.parquet",
    ("0.25", "validation"): "0.25/validation-00000-of-00001-951dbd63c8724ee1.parquet",
    ("1.25", "train"): "1.25/train-00000-of-00004-e715178553977907.parquet",
    ("1.25", "validation"): "1.25/validation-00000-of-00001-09e3e67bb00ab4ec.parquet",
}
GENDER = {0: "man", 1: "woman"}  # dataset: 0 Male, 1 Female
CHILD_AGES = {0, 1, 2}  # 0-2, 3-9, 10-19


def shard(padding, split):
    return hf_hub_download(REPO, SHARDS[(padding, split)], repo_type="dataset", local_dir=os.path.join(WORK, "fairface"))


def rows(path, wanted):
    """Yield (row_index, age, gender, jpeg_bytes) for the wanted row indices, streaming the parquet file."""
    wanted = set(wanted)
    i = 0
    for batch in pq.ParquetFile(path).iter_batches(batch_size=512, columns=["image", "age", "gender"]):
        cols = batch.to_pydict()
        for img, age, gender in zip(cols["image"], cols["age"], cols["gender"]):
            if i in wanted:
                yield i, age, gender, img["bytes"]
            i += 1


def save_jpeg(data, path):
    if data[:2] == b"\xff\xd8":
        open(path, "wb").write(data)
    else:
        Image.open(BytesIO(data)).convert("RGB").save(path, quality=92)


def labels(path):
    t = pq.read_table(path, columns=["age", "gender"]).to_pydict()
    return list(zip(t["age"], t["gender"]))


def cmd_export(a):
    path = shard(a.padding, "train")
    lab = labels(path)
    rng = random.Random(0)
    root = os.path.join(WORK, f"fairface_{a.padding}")
    plan = {}
    for g, name in GENDER.items():
        idx = [i for i, (_, gg) in enumerate(lab) if gg == g]
        rng.shuffle(idx)
        for i in idx[: a.train_per_class]:
            plan[i] = os.path.join(root, "train", name)
        for i in idx[a.train_per_class : a.train_per_class + a.val_per_class]:
            plan[i] = os.path.join(root, "val", name)
    for d in set(plan.values()):
        os.makedirs(d, exist_ok=True)
    for i, _, _, data in rows(path, plan):
        save_jpeg(data, os.path.join(plan[i], f"{i}.jpg"))
    print(f"exported {len(plan)} faces to {root}")


def cmd_children(a):
    path = shard(a.padding, "validation")
    lab = labels(path)
    rng = random.Random(0)
    picked = []
    for g in GENDER:
        idx = [i for i, (age, gg) in enumerate(lab) if gg == g and age in CHILD_AGES]
        rng.shuffle(idx)
        picked += idx[: a.n // 2]
    os.makedirs(FACES, exist_ok=True)
    entries = []
    for i, age, gender, data in rows(path, picked):
        eid = f"fairface_val_{i}"
        save_jpeg(data, os.path.join(FACES, eid + ".jpg"))
        entries.append({"id": eid, "file": eid + ".jpg", "label": GENDER[gender], "tags": ["child"],
                        "source": f"fairface {a.padding} validation row {i} (age bucket {age})", "title": eid, "page": "",
                        "url": "", "thumb": "", "author": "FairFace (Kärkkäinen & Joo)", "license": "CC BY 4.0",
                        "license_url": "https://creativecommons.org/licenses/by/4.0/", "derived_from": None, "transform": None})
    keep = [e for e in load_manifest() if not e["source"].startswith("fairface")]
    save_manifest(keep + entries)


def cmd_benchmark(a):
    path = shard(a.padding, "validation")
    lab = labels(path)
    idx = list(range(len(lab)))
    random.Random(0).shuffle(idx)
    picked = idx[: a.n]
    out = os.path.join(WORK, "ffval")
    os.makedirs(out, exist_ok=True)
    entries = []
    for i, age, gender, data in rows(path, picked):
        eid = f"fairface_val_{i}"
        save_jpeg(data, os.path.join(out, eid + ".jpg"))
        entries.append({"id": eid, "file": eid + ".jpg", "label": GENDER[gender], "tags": ["child"] if age in CHILD_AGES else [],
                        "source": f"fairface {a.padding} validation row {i}"})
    import json
    json.dump({"version": 1, "images_dir": ".", "entries": entries}, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    print(f"benchmark manifest: {len(entries)} faces in {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["export", "children", "benchmark"])
    ap.add_argument("--padding", default="1.25", choices=["0.25", "1.25"])
    ap.add_argument("--train-per-class", type=int, default=3000)
    ap.add_argument("--val-per-class", type=int, default=500)
    ap.add_argument("--n", type=int, default=None)
    a = ap.parse_args()
    if a.n is None:
        a.n = {"children": 40, "benchmark": 1000}.get(a.cmd, 0)
    {"export": cmd_export, "children": cmd_children, "benchmark": cmd_benchmark}[a.cmd](a)
