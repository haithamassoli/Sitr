#!/usr/bin/env python3
"""Fetch benchmark images into Bench/data/ (gitignored; never committed). Stdlib only.

  python3 Bench/download.py            # both sets
  python3 Bench/download.py --photos   # Wikimedia Commons CC0 photos -> Bench/data/photos/  (sitr-spike detect)
  python3 Bench/download.py --recall   # COCO val2017 images from Bench/recall/manifest.json -> Bench/data/recall/
  python3 Bench/download.py --labels Bench/labels/faces-commons.json [--limit 20] [--timeout 20]
                                       # images of a sitr-bench labels file -> its images_dir (Bench/data/faces/)
A file that fails is reported and skipped (re-run to retry it); the exit code is 1 when any requested file is missing.
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BENCH = Path(__file__).resolve().parent
DATA = BENCH / "data"
UA = "SitrBench/0.1 (contact: noreply@goldentik.com) python-urllib"

# CC0 photos of people from Wikimedia Commons; licenses verified on the file pages listed under `page`.
# Composed into one synthetic 2560x1664 "web page" frame by `sitr-spike detect`.
PHOTOS = [
    {"file": "01_gravel_path.jpg", "author": "Fons Heijnsbroek", "license": "CC0 1.0",
     "title": "File:People, walking over the gravel path along the canal Kattenburgervaart; free photo Amsterdam city, Fons Heijnsbroek 01-2022.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:People,_walking_over_the_gravel_path_along_the_canal_Kattenburgervaart;_free_photo_Amsterdam_city,_Fons_Heijnsbroek_01-2022.jpg"},
    {"file": "02_laughing_woman.jpg", "author": "Brooke Cagle (Unsplash)", "license": "CC0 1.0",
     "title": "File:Laughing woman in jean jacket (Unsplash).jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Laughing_woman_in_jean_jacket_(Unsplash).jpg"},
    {"file": "03_fashion_portrait.jpg", "author": "www.Pixel.la Free Stock Photos", "license": "CC0 1.0",
     "title": "File:Fashion-woman-model-portrait (24300464886).jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Fashion-woman-model-portrait_(24300464886).jpg"},
    {"file": "04_winter_quebec.jpg", "author": "Wilfredor", "license": "CC0 1.0",
     "title": "File:Person in winter clothing in Quebec City.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Person_in_winter_clothing_in_Quebec_City.jpg"},
    {"file": "05_kids_football.jpg", "author": "Rachelboo2", "license": "CC0 1.0",
     "title": "File:Kids playing football2.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Kids_playing_football2.jpg"},
    {"file": "06_back_view.jpg", "author": "Mostafameraji", "license": "CC0 1.0",
     "title": "File:Iranian peoples 03.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Iranian_peoples_03.jpg"},
    {"file": "07_walking_man.jpg", "author": "Fons Heijnsbroek", "license": "CC0 1.0",
     "title": "File:Walking man in front of the bronze Spinoza sculpture, Waterlooplein; free photo Amsterdam city, 12-10-2021.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Walking_man_in_front_of_the_bronze_Spinoza_sculpture,_Waterlooplein;_free_photo_Amsterdam_city,_12-10-2021.jpg"},
    {"file": "08_hikers.jpg", "author": "Sarita Blessing", "license": "CC0 1.0",
     "title": "File:Hikers in the Mount Cameroon National Park.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Hikers_in_the_Mount_Cameroon_National_Park.jpg"},
    {"file": "09_tour_group.jpg", "author": "BeraDigle", "license": "CC0 1.0",
     "title": "File:Participants de la visite touristique.jpg",
     "page": "https://commons.wikimedia.org/wiki/File:Participants_de_la_visite_touristique.jpg"},
]


def photo_url(title, width=1600):
    return "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(title[len("File:"):]) + f"?width={width}"


def fetch(url, dest, timeout=120):
    if dest.exists():
        return False
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    part = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        part.write_bytes(r.read())
    part.rename(dest)
    return True


def download_all(jobs, label, timeout=120):
    """Fetches every (url, dest); a failed file is printed and skipped. Returns the number of failures."""
    def one(job):
        try:
            return fetch(*job, timeout=timeout)
        except Exception as ex:  # ponytail: report and carry on so a flaky file does not lose the rest; re-run to retry
            print(f"  failed {job[1].name}: {ex}")
            return None

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, jobs))
    fetched, failed = sum(r is True for r in results), sum(r is None for r in results)
    print(f"{label}: {len(jobs)} files, {fetched} downloaded, {len(jobs) - fetched - failed} already present, {failed} failed")
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--photos", action="store_true")
    ap.add_argument("--recall", action="store_true")
    ap.add_argument("--labels", metavar="LABELS.json", help="images of a Bench/labels file -> its images_dir (sitr-bench)")
    ap.add_argument("--limit", type=int, help="with --labels: only the first N images (CI smoke)")
    ap.add_argument("--timeout", type=float, default=120, help="seconds per file (default 120)")
    args = ap.parse_args()
    both = not (args.photos or args.recall or args.labels)
    failed = 0
    if args.photos or both:
        out = DATA / "photos"
        out.mkdir(parents=True, exist_ok=True)
        failed += download_all([(photo_url(p["title"]), out / p["file"]) for p in PHOTOS], f"photos -> {out}", args.timeout)
    if args.recall or both:
        manifest = json.loads((BENCH / "recall" / "manifest.json").read_text())
        out = DATA / "recall"
        out.mkdir(parents=True, exist_ok=True)
        failed += download_all([(e["coco_url"], out / e["file_name"]) for e in manifest["images"]], f"recall -> {out}", args.timeout)
    if args.labels:
        labels_path = Path(args.labels)
        labels = json.loads(labels_path.read_text())
        out = (labels_path.parent / labels["images_dir"]).resolve()
        out.mkdir(parents=True, exist_ok=True)
        jobs = {e["file"]: (e["url"], out / e["file"]) for e in labels["images"][: args.limit]}  # low-light rows share a file
        failed += download_all(list(jobs.values()), f"{labels_path.name} -> {out}", args.timeout)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
