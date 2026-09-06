#!/usr/bin/env python3
"""Write the sitr-bench labels (Bench/labels/*.json, committed, stdlib only) from the two committed manifests.

  recall-coco.json    <- Bench/recall/manifest.json (M1-T06): COCO val2017 person boxes, tags small/crowd/back/partial,
                         category null (COCO has no gender labels).
  faces-commons.json  <- Models/eval/manifest.json (M1-T05): one labeled person per Wikimedia Commons portrait, gender from
                         the category name, tags hijab/child/profile/low-light. The manifest has no boxes, so the person box
                         is the WHOLE IMAGE: these are single-person portraits and the IoU >= 0.5 match then doubles as the
                         single-portrait filter (group shots leave the labeled person unmatched, which the bench reports).
                         `low-light` entries keep the source file and carry "darken" (gamma 2.2, then x0.35 — the spike's
                         synthetic transform); the bench darkens the frame itself, so no derived image is ever stored.
                         FairFace child rows have no URL and are left out (they need Models/fairface.py and the venv).

Labels format, one object per image:
  {"file", "url", "license", "width", "height", "persons": [{"box": [x, y, w, h], "category": "woman"|"man"|null, "tags": [..]}],
   "darken": {"gamma", "gain"} (optional)}
Top level: {"set", "source", "images_dir" (relative to the labels file), "tags": {tag: meaning}, "images": [..]}.

Image sizes for faces-commons are read from the local files (JPEG SOF / PNG IHDR); missing files are fetched first with
Bench/download.py's fetch into Bench/data/faces/ (gitignored). Usage: python3 Bench/convert_labels.py
"""
import json
import struct
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no Bench/__pycache__ in the repo
sys.path.insert(0, str(Path(__file__).resolve().parent))
from download import download_all  # noqa: E402

BENCH = Path(__file__).resolve().parent
LABELS = BENCH / "labels"
FACES = BENCH / "data" / "faces"
DARKEN = {"gamma": 2.2, "gain": 0.35}


def image_size(path):
    """(width, height) from a PNG IHDR or a JPEG SOFn marker; the file extension is not trusted (Commons originals may be PNG)."""
    with open(path, "rb") as f:
        head = f.read(24)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", head[16:24])
        if head[:2] != b"\xff\xd8":
            raise ValueError(f"{path}: not a JPEG or PNG")
        f.seek(2)
        while True:
            byte = f.read(1)
            if not byte:
                raise ValueError(f"{path}: no SOF marker")
            if byte != b"\xff":
                continue
            marker = f.read(1)[0]
            if marker in (0xFF, 0xD8) or 0xD0 <= marker <= 0xD7:  # padding, SOI, RSTn: no length field
                continue
            (length,) = struct.unpack(">H", f.read(2))
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):  # SOF0..15 minus DHT/JPG/DAC
                _, h, w = struct.unpack(">BHH", f.read(5))
                return w, h
            f.seek(length - 2, 1)


def recall_coco():
    m = json.loads((BENCH / "recall" / "manifest.json").read_text())
    images = [{
        "file": e["file_name"], "url": e["coco_url"], "license": e["license_name"], "width": e["width"], "height": e["height"],
        "persons": [{"box": p["bbox"], "category": None, "tags": p["tags"]} for p in e["persons"]],
    } for e in m["images"]]
    return {
        "set": "recall-coco",
        "source": m["source"] + "; converted from Bench/recall/manifest.json (Bench/build_manifest.py), attributions in Bench/ATTRIBUTIONS.md",
        "images_dir": "../data/recall",
        "tags": m["tags"],
        "images": images,
    }


def faces_commons():
    entries = json.loads((BENCH.parent / "Models" / "eval" / "manifest.json").read_text())["entries"]
    commons = [e for e in entries if e["thumb"]]  # Commons files and their low-light copies; FairFace rows have no URL
    source_file = lambda e: (e["derived_from"] or e["id"]) + ".jpg"  # noqa: E731
    url = lambda e: e["thumb"].split("?")[0]  # noqa: E731  (drop the utm_* tracking query)
    FACES.mkdir(parents=True, exist_ok=True)
    jobs = {source_file(e): (url(e), FACES / source_file(e)) for e in commons}
    if download_all(list(jobs.values()), f"faces -> {FACES}"):
        sys.exit("faces-commons: some images could not be fetched; re-run to retry the missing ones")
    images = []
    for e in commons:
        w, h = image_size(FACES / source_file(e))
        image = {"file": source_file(e), "url": url(e), "license": e["license"], "width": w, "height": h,
                 "persons": [{"box": [0, 0, w, h], "category": e["label"], "tags": e["tags"]}]}
        if e["derived_from"]:
            image["darken"] = DARKEN
        images.append(image)
    print(f"faces-commons: {len(images)} images ({len(entries) - len(commons)} FairFace rows without a URL left out)")
    return {
        "set": "faces-commons",
        "source": "Wikimedia Commons portraits (CC0 / CC BY / CC BY-SA), labels from category names; converted from "
                  "Models/eval/manifest.json (Models/fetch_eval_faces.py), attributions in Models/eval/ATTRIBUTIONS.md. "
                  "Person box = whole image.",
        "images_dir": "../data/faces",
        "tags": {
            "hijab": "Commons 'Women wearing hijabs' categories (woman)",
            "child": "Commons 'Portrait photographs of girls/boys'",
            "profile": "Commons 'Profile portrait photographs of women/men'",
            "low-light": "synthetic: the bench applies gamma 2.2, then brightness x0.35 to the source frame (`darken`)",
        },
        "images": images,
    }


def main():
    LABELS.mkdir(exist_ok=True)
    for build in (recall_coco, faces_commons):
        labels = build()
        out = LABELS / (labels["set"] + ".json")
        out.write_text(json.dumps(labels, indent=1, ensure_ascii=False) + "\n")
        persons = [p for im in labels["images"] for p in im["persons"]]
        print(f"wrote {out}: {len(labels['images'])} images, {len(persons)} persons")


if __name__ == "__main__":
    main()
