#!/usr/bin/env python3
"""Build Bench/recall/manifest.json from COCO val2017 person annotations (stdlib only).

Images are filtered to permissive Flickr licenses (COCO license ids 4 = CC BY 2.0, 5 = CC BY-SA 2.0,
7 = no known copyright restrictions). Annotations themselves are CC BY 4.0 (COCO Consortium).
Tags per person box, derived automatically:
  small    box height < 80 px at original size
  crowd    iscrowd = 1 (region with many people; COCO gives one box for the group)
  back     keypoints: both shoulders visible, nose and both eyes not visible
  partial  box touches the image border on >= 1 side (1 px tolerance)
Also regenerates Bench/ATTRIBUTIONS.md (COCO images + the Wikimedia photos listed in download.py).
Usage: python3 Bench/build_manifest.py [--count 200] [--per-tag 30]
"""
import argparse
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True  # no Bench/__pycache__ in the repo
sys.path.insert(0, str(Path(__file__).resolve().parent))
from download import PHOTOS, UA  # noqa: E402

BENCH = Path(__file__).resolve().parent
DATA = BENCH / "data"
ZIP = DATA / "annotations_trainval2017.zip"
ZIP_URL = "http://images.cocodataset.org/annotations/annotations_trainval2017.zip"
MANIFEST = BENCH / "recall" / "manifest.json"
ATTRIBUTIONS = BENCH / "ATTRIBUTIONS.md"
PERMISSIVE = {4: "CC BY 2.0", 5: "CC BY-SA 2.0", 7: "No known copyright restrictions"}
TAGS = ["back", "crowd", "small", "partial"]
# COCO keypoint indices: 0 nose, 1 left eye, 2 right eye, 5 left shoulder, 6 right shoulder; v == 2 means visible.
NOSE, L_EYE, R_EYE, L_SHOULDER, R_SHOULDER = 0, 1, 2, 5, 6


def fetch_zip():
    if ZIP.exists():
        return
    DATA.mkdir(parents=True, exist_ok=True)
    print(f"downloading {ZIP_URL} (~250 MB) ...")
    req = urllib.request.Request(ZIP_URL, headers={"User-Agent": UA})
    part = ZIP.with_suffix(".part")
    with urllib.request.urlopen(req, timeout=120) as r, open(part, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    part.rename(ZIP)


def load(name):
    with zipfile.ZipFile(ZIP) as z, z.open(f"annotations/{name}") as f:
        return json.load(f)


def visible(kp, i):
    return kp[3 * i + 2] == 2


def is_back(kp):
    return (visible(kp, L_SHOULDER) and visible(kp, R_SHOULDER)
            and not visible(kp, NOSE) and not visible(kp, L_EYE) and not visible(kp, R_EYE))


def tags_for(ann, kp, w, h):
    x, y, bw, bh = ann["bbox"]
    tags = []
    if bh < 80:
        tags.append("small")
    if ann.get("iscrowd", 0) == 1:
        tags.append("crowd")
    if kp is not None and is_back(kp):
        tags.append("back")
    if x <= 1 or y <= 1 or x + bw >= w - 1 or y + bh >= h - 1:
        tags.append("partial")
    return tags


def build(count, per_tag):
    inst = load("instances_val2017.json")
    keypoints = {a["id"]: a["keypoints"] for a in load("person_keypoints_val2017.json")["annotations"]}
    images = {im["id"]: im for im in inst["images"] if im["license"] in PERMISSIVE}
    persons = {}
    for a in inst["annotations"]:
        if a["category_id"] == 1 and a["image_id"] in images:
            persons.setdefault(a["image_id"], []).append(a)

    entries = {}
    for image_id in sorted(persons):
        im = images[image_id]
        boxes = []
        for a in persons[image_id]:
            x, y, bw, bh = a["bbox"]
            boxes.append({
                "bbox": [round(x, 2), round(y, 2), round(bw, 2), round(bh, 2)],
                "iscrowd": a.get("iscrowd", 0),
                "tags": tags_for(a, keypoints.get(a["id"]), im["width"], im["height"]),
            })
        entries[image_id] = {
            "id": image_id,
            "file_name": im["file_name"],
            "coco_url": im["coco_url"],
            "flickr_url": im["flickr_url"],
            "license": im["license"],
            "license_name": PERMISSIVE[im["license"]],
            "width": im["width"],
            "height": im["height"],
            "persons": boxes,
        }

    # Deterministic selection: first guarantee `per_tag` images per tag (in id order), then fill to `count` in id order.
    chosen = []
    chosen_set = set()

    def take(image_id):
        if image_id not in chosen_set:
            chosen_set.add(image_id)
            chosen.append(image_id)

    for tag in TAGS:
        have = sum(any(tag in b["tags"] for b in entries[i]["persons"]) for i in chosen)
        for image_id in sorted(entries):
            if have >= per_tag:
                break
            if any(tag in b["tags"] for b in entries[image_id]["persons"]) and image_id not in chosen_set:
                take(image_id)
                have += 1
    for image_id in sorted(entries):
        if len(chosen) >= count:
            break
        take(image_id)
    return [entries[i] for i in sorted(chosen)], len(entries)


def write_attributions(manifest):
    lines = [
        "# Bench image attributions",
        "",
        "Images are downloaded by `Bench/download.py` into `Bench/data/` (gitignored) and never committed.",
        "",
        "## Composite-frame photos (Wikimedia Commons, `Bench/data/photos/`)",
        "",
        "Used by `sitr-spike detect` to compose a synthetic 2560x1664 screen frame.",
        "",
    ]
    for p in PHOTOS:
        lines.append(f"- `{p['file']}` — {p['title']} by {p['author']} — {p['license']} — {p['page']}")
    lines += [
        "",
        "## Recall set (COCO val2017, `Bench/data/recall/`)",
        "",
        "Annotations: COCO 2017 (CC BY 4.0, COCO Consortium, https://cocodataset.org). Images are Flickr photos under the",
        "license COCO recorded per image; only CC BY 2.0, CC BY-SA 2.0 and 'no known copyright restrictions' are used.",
        "Generated by `Bench/build_manifest.py`. One line per image: file, Flickr URL, license.",
        "",
    ]
    for e in manifest["images"]:
        lines.append(f"- `{e['file_name']}` — {e['flickr_url']} — {e['license_name']} (COCO license {e['license']})")
    ATTRIBUTIONS.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--per-tag", type=int, default=30, help="minimum images per tag before filling by id")
    args = ap.parse_args()
    fetch_zip()
    selected, qualifying = build(args.count, args.per_tag)
    manifest = {
        "source": "COCO val2017 person annotations (CC BY 4.0); images filtered to COCO license ids 4, 5, 7",
        "tags": {
            "small": "box height < 80 px at original size",
            "crowd": "iscrowd = 1",
            "back": "keypoints: both shoulders visible, nose and both eyes not visible",
            "partial": "box touches the image border on >= 1 side",
        },
        "images": selected,
    }
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")
    write_attributions(manifest)
    boxes = [b for e in selected for b in e["persons"]]
    print(f"qualifying images with persons: {qualifying}; selected {len(selected)} images, {len(boxes)} person boxes")
    for tag in TAGS:
        n_img = sum(any(tag in b["tags"] for b in e["persons"]) for e in selected)
        n_box = sum(tag in b["tags"] for b in boxes)
        print(f"  {tag:8} images={n_img:3} boxes={n_box}")
    print(f"wrote {MANIFEST} and {ATTRIBUTIONS}")


if __name__ == "__main__":
    main()
