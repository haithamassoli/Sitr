#!/usr/bin/env python3
"""200 person-free COCO val2017 images (seeded pick) for false-positive counts -> Models/work/neg/{neg.json,img/}.
Research for docs/models-2026.md; nothing here is committed (Models/work is gitignored). Stdlib only.

  python3 Models/detector/fetch_negatives.py
"""
import io
import json
import random
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NEG = ROOT / "Models/work/neg"
ZIP = ROOT / "Models/work/coco_ann/ann.zip"

if not ZIP.exists():
    ZIP.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve("http://images.cocodataset.org/annotations/annotations_trainval2017.zip", ZIP)
with zipfile.ZipFile(ZIP) as z:
    d = json.load(io.TextIOWrapper(z.open("annotations/instances_val2017.json")))
person = {a["image_id"] for a in d["annotations"] if a["category_id"] == 1}
annotated = {a["image_id"] for a in d["annotations"]}
pool = sorted((im for im in d["images"] if im["id"] in annotated and im["id"] not in person), key=lambda i: i["id"])
random.Random(2026).shuffle(pool)
(NEG / "img").mkdir(parents=True, exist_ok=True)
out = {"set": "neg-coco", "images_dir": "img", "images": []}
for im in pool[:200]:
    path = NEG / "img" / im["file_name"]
    if not path.exists():
        urllib.request.urlretrieve(im["coco_url"], path)
    out["images"].append({"file": im["file_name"], "width": im["width"], "height": im["height"], "persons": []})
(NEG / "neg.json").write_text(json.dumps(out, indent=1))
print(f"{len(pool)} person-free annotated images; picked {len(out['images'])} -> {NEG}")
