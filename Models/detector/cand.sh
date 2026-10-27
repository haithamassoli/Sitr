#!/bin/zsh
# Research for docs/models-2026.md: sitr-bench on a candidate PersonDetector (recall set + the person-free set from
# fetch_negatives.py). <pkg> is only compiled when Models/work/cand/<name>/PersonDetector.mlmodelc does not exist yet.
# usage: Models/detector/cand.sh <name> <PersonDetector.mlpackage> [extra sitr-bench args]
# -> Models/work/cand/<name>/{pos,neg}.{json,log}; prints one summary line
set -e
name=$1; pkg=$2; shift 2
d=Models/work/cand/$name; mkdir -p $d
[[ -d $d/PersonDetector.mlmodelc ]] || { xcrun coremlcompiler compile $pkg $d >/dev/null && mv $d/$(basename $pkg .mlpackage).mlmodelc $d/PersonDetector.mlmodelc; }
[[ -e $d/GenderClassifier.mlpackage ]] || ln -s $PWD/Models/dist/GenderClassifier.mlpackage $d/GenderClassifier.mlpackage
for set in pos neg; do
  labels=Bench/labels/recall-coco.json; [[ $set == neg ]] && labels=Models/work/neg/neg.json
  .build/release/sitr-bench $labels --models $d --json $d/$set.json --verbose "$@" > $d/$set.log 2>&1
done
python3 - $d $name <<'PY'
import json, re, sys
d, name = sys.argv[1:]
p, n = json.load(open(f"{d}/pos.json")), json.load(open(f"{d}/neg.json"))
r = lambda t: f"{100*p['recall'][t]['hit']/p['recall'][t]['total']:.1f}"
def dets(f):
    s = m = 0
    for l in open(f):
        if l.startswith("image "):
            kv = dict(x.split("=", 1) for x in l.split()[1:] if "=" in x); s += int(kv["persons"]); m += int(kv["matched"])
    return s, m
ps, pm = dets(f"{d}/pos.log"); ns, _ = dets(f"{d}/neg.log")
ms = p["ms"]["detect"]; nms = n["ms"]["detect"]
print(f"cand {name}: recall all={r('all')} ge80={r('ge80px')} small={r('small')} large={r('large')} back={r('back')} partial={r('partial')} | "
      f"unmatched_pos={ps-pm}/{ps} neg_fp={ns} (on 200 person-free) | detect p50/p95 pos={ms['p50']:.1f}/{ms['p95']:.1f} neg={nms['p50']:.1f}/{nms['p95']:.1f} load1={p['load1']}/{n['load1']}")
PY
