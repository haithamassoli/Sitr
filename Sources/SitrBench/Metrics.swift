// Metric math for sitr-bench (M4-T08), free of CoreML/Vision so `--selfcheck` drives it with synthetic detections.
// Matching mirrors Sources/SitrSpike/Recall.swift: GT boxes scaled to the frame (long side 1280), non-crowd GT matched to
// detections one-to-one greedily by confidence at IoU >= 0.5, tallied when the GT is >= 40 px tall. Derived tags as there:
// large = GT height >= 50 % of the frame height, medium = 20-50 %; plus ge80px (GT >= 80 px) and large+medium.
// Classification numbers come from the matched GT: Unknown rate over every matched person, misclassification over the
// labeled ones whose predicted category is not Unknown (the PRD's "hidden-category person shown due to misclassification").
import Foundation
import SitrCore
import enum SitrCore.Category

/// Bench/labels/*.json (Bench/convert_labels.py).
struct Labels: Decodable {
    struct Person: Decodable {
        var box: [Double]
        var category: String?
        var tags: [String]
    }
    struct Darken: Decodable {
        var gamma: Double
        var gain: Double
    }
    struct Image: Decodable {
        var file: String
        var width: Int
        var height: Int
        var persons: [Person]
        var darken: Darken?
    }
    var set: String
    var imagesDir: String?
    var images: [Image]

    enum CodingKeys: String, CodingKey {
        case set, images
        case imagesDir = "images_dir"
    }
}

/// What the pipeline produced for one image, everything in frame pixels (top-left origin).
struct Observed: Sendable {
    struct GT: Sendable {
        var box: Rect
        /// `.woman` / `.man` from the labels; nil when the set carries no gender label.
        var category: Category?
        var tags: [String]
    }
    struct Det: Sendable {
        var box: Rect
        var confidence: Float
        /// The assigned face's size; nil when no face landed on this person.
        var face: Size?
        /// P(woman) when the classifier ran (face >= 32 px on a body >= 40 px); nil otherwise.
        var pWoman: Double?
    }
    var frame: Size
    var gt: [GT]
    var dets: [Det]
}

/// One eligible GT (>= 40 px, not crowd) with its tags (given + derived) and the detection matched to it, if any.
struct Matched {
    var gt: Observed.GT
    var tags: [String]
    var det: Observed.Det?
}

struct Tally {
    var hit = 0, total = 0
    var percent: String { pct(hit, total) }
}

struct ClassTally {
    /// Matched eligible persons; how many the rule left Unknown, split by reason.
    var matched = 0, unknown = 0, noFace = 0, smallFace = 0, smallBody = 0, lowConfidence = 0
    /// Labeled subset: matched, predicted non-Unknown, predicted as the other gender; labeled persons with no detection.
    var labeled = 0, known = 0, wrong = 0, unmatched = 0
    var misclassification: String { pct(wrong, known) }
    var unknownRate: String { pct(unknown, matched) }
}

/// The app's rule (`categorize`, PRD FR2) with the Unknown threshold as a parameter: woman when P(woman) >= t, man when
/// P(man) = 1 - P(woman) >= t, Unknown between; no face, face short side < 32 px, body < 40 px or no probability → Unknown.
/// `--selfcheck` asserts it equals `categorize` at 0.80.
func category(face: Size?, body: Size, pWoman: Double?, threshold: Double) -> Category {
    guard let face, min(face.width, face.height) >= Category.minFaceSide, body.height >= Category.minBodyHeight, let p = pWoman
    else { return .unknown }
    if p >= threshold { return .woman }
    if 1 - p >= threshold { return .man }
    return .unknown
}

/// One-to-one greedy (Recall.swift `matchIoU`): detections by confidence, each takes the unmatched GT with the highest IoU >= 0.5.
func match(_ o: Observed, iou threshold: Double = 0.5) -> [Matched] {
    let people = o.gt.indices.filter { !o.gt[$0].tags.contains("crowd") }
    var matched = [Int?](repeating: nil, count: people.count)
    for (d, det) in o.dets.enumerated().sorted(by: { $0.element.confidence > $1.element.confidence }) {
        var best = -1, bestIoU = threshold
        for (k, i) in people.enumerated() where matched[k] == nil {
            let v = o.gt[i].box.iou(det.box)
            if v >= bestIoU { bestIoU = v; best = k }
        }
        if best >= 0 { matched[best] = d }
    }
    return people.enumerated().compactMap { k, i in
        let gt = o.gt[i]
        guard gt.box.height >= Category.minBodyHeight else { return nil }
        var tags = ["all"] + gt.tags
        if gt.box.height >= 80 { tags.append("ge80px") }
        let fraction = gt.box.height / o.frame.height
        if fraction >= 0.5 { tags.append("large") } else if fraction >= 0.2 { tags.append("medium") }
        if fraction >= 0.2 { tags.append("large+medium") }
        if gt.category != nil, gt.tags.isEmpty { tags.append("general") }
        return Matched(gt: gt, tags: tags, det: matched[k].map { o.dets[$0] })
    }
}

func recall(_ matches: [Matched]) -> [String: Tally] {
    var out: [String: Tally] = [:]
    for m in matches {
        for tag in m.tags {
            out[tag, default: Tally()].total += 1
            if m.det != nil { out[tag, default: Tally()].hit += 1 }
        }
    }
    return out
}

func classes(_ matches: [Matched], threshold: Double) -> [String: ClassTally] {
    var out: [String: ClassTally] = [:]
    for m in matches {
        for tag in m.tags {
            var t = out[tag, default: ClassTally()]
            defer { out[tag] = t }
            guard let det = m.det else {
                if m.gt.category != nil { t.unmatched += 1 }
                continue
            }
            t.matched += 1
            let predicted = category(face: det.face, body: Size(width: det.box.width, height: det.box.height), pWoman: det.pWoman, threshold: threshold)
            if predicted == .unknown {
                t.unknown += 1
                if det.face == nil { t.noFace += 1 } else if min(det.face!.width, det.face!.height) < Category.minFaceSide { t.smallFace += 1 } else if det.box.height < Category.minBodyHeight { t.smallBody += 1 } else { t.lowConfidence += 1 }
            }
            guard let label = m.gt.category else { continue }
            t.labeled += 1
            if predicted != .unknown {
                t.known += 1
                if predicted != label { t.wrong += 1 }
            }
        }
    }
    return out
}

/// Row order of the per-tag table; dataset tags not listed here are appended alphabetically.
let tagOrder = ["all", "ge80px", "large", "medium", "large+medium", "small", "back", "partial", "general", "hijab", "child", "low-light", "profile"]
let thresholds = [0.80, 0.85, 0.90]

struct Report {
    var set: String
    var threshold: Double
    var recall: [String: Tally]
    var classes: [String: ClassTally]
    /// "all" at each of `thresholds`.
    var byThreshold: [(threshold: Double, all: ClassTally)]
    var ms: [(stage: String, samples: [Double])]
    var processed = 0, missing = 0, unreadable = 0, classifierErrors = 0

    init(set: String, matches: [Matched], threshold: Double, ms: [(stage: String, samples: [Double])]) {
        self.set = set
        self.threshold = threshold
        recall = SitrBench.recall(matches)
        classes = SitrBench.classes(matches, threshold: threshold)
        byThreshold = thresholds.map { ($0, SitrBench.classes(matches, threshold: $0)["all"] ?? ClassTally()) }
        self.ms = ms
    }

    var tags: [String] {
        let present = Set(recall.keys)
        return tagOrder.filter(present.contains) + present.subtracting(tagOrder).sorted()
    }

    /// Table plus one parseable line per metric (`bench_recall …`, `bench_class …`, `bench_thresholds …`, `bench_ms …`).
    func print() {
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        Swift.print("bench_images set=\(set) processed=\(processed) missing=\(missing) unreadable=\(unreadable) classifier_errors=\(classifierErrors) threshold=\(f2(threshold)) long_side=1280 load1=\(f1(loads[0])) noisy=\(loads[0] > 4)")
        Swift.print("")
        Swift.print("tag            GT   recall %  (hit/total)   matched  Unknown %   labeled  known  wrong  misclass %  labeled missed")
        for tag in tags + ["drawn"] {
            let r = recall[tag] ?? Tally(), c = classes[tag] ?? ClassTally()
            guard r.total > 0 else {
                Swift.print("\(tag.pad(13)) n/a (no data)")
                continue
            }
            let misclass = c.labeled > 0 ? c.misclassification : "-"
            Swift.print("\(tag.pad(13)) \(String(r.total).lpad(4)) \(r.percent.lpad(9))  \("(\(r.hit)/\(r.total))".pad(13)) \(String(c.matched).lpad(7))  \(c.unknownRate.lpad(9))   \(String(c.labeled).lpad(7))  \(String(c.known).lpad(5))  \(String(c.wrong).lpad(5))  \(misclass.lpad(10))  \(String(c.unmatched).lpad(6))")
            Swift.print("bench_recall set=\(set) tag=\(tag) hit=\(r.hit) total=\(r.total) recall=\(r.percent)")
            Swift.print("bench_class set=\(set) threshold=\(f2(threshold)) tag=\(tag) matched=\(c.matched) unknown=\(c.unknown) unknown_noface=\(c.noFace) unknown_smallface=\(c.smallFace) unknown_smallbody=\(c.smallBody) unknown_lowp=\(c.lowConfidence) unknown_rate=\(c.unknownRate) labeled=\(c.labeled) known=\(c.known) wrong=\(c.wrong) misclass=\(misclass) labeled_missed=\(c.unmatched)")
        }
        Swift.print("")
        Swift.print("threshold  labeled  known  wrong  misclass %  Unknown %   (tag=all; misclass = wrong/known, Unknown = unknown/matched)")
        for (t, c) in byThreshold {
            Swift.print("\(f2(t).pad(10)) \(String(c.labeled).lpad(7))  \(String(c.known).lpad(5))  \(String(c.wrong).lpad(5))  \(c.misclassification.lpad(10))  \(c.unknownRate.lpad(9))")
            Swift.print("bench_thresholds set=\(set) threshold=\(f2(t)) matched=\(c.matched) unknown=\(c.unknown) labeled=\(c.labeled) known=\(c.known) wrong=\(c.wrong) misclass=\(c.misclassification) unknown_rate=\(c.unknownRate)")
        }
        if let all = classes["all"] {
            Swift.print("Unknown reasons (all, \(f2(threshold))): no face \(all.noFace), face < 32 px \(all.smallFace), body < 40 px \(all.smallBody), max(p, 1-p) < threshold \(all.lowConfidence)")
        }
        Swift.print("")
        Swift.print("stage             p50 ms   p95 ms      n")
        for (stage, samples) in ms where !samples.isEmpty {
            Swift.print("\(stage.pad(15)) \(f1(percentile(samples, 0.5)).lpad(8)) \(f1(percentile(samples, 0.95)).lpad(8)) \(String(samples.count).lpad(6))")
            Swift.print("bench_ms set=\(set) stage=\(stage) p50=\(f1(percentile(samples, 0.5))) p95=\(f1(percentile(samples, 0.95))) n=\(samples.count) load1=\(f1(loads[0]))")
        }
    }

    /// The same numbers for `--json`.
    var json: [String: Any] {
        var recallJSON: [String: Any] = [:], classJSON: [String: Any] = [:]
        for tag in tags {
            let r = recall[tag] ?? Tally(), c = classes[tag] ?? ClassTally()
            recallJSON[tag] = ["hit": r.hit, "total": r.total]
            classJSON[tag] = c.json
        }
        var ms: [String: Any] = [:]
        for (stage, samples) in self.ms where !samples.isEmpty {
            ms[stage] = ["p50": percentile(samples, 0.5), "p95": percentile(samples, 0.95), "n": samples.count]
        }
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        return [
            "set": set, "threshold": threshold, "long_side": 1280, "load1": loads[0],
            "images": ["processed": processed, "missing": missing, "unreadable": unreadable, "classifier_errors": classifierErrors],
            "recall": recallJSON, "classification": classJSON,
            "thresholds": Dictionary(uniqueKeysWithValues: byThreshold.map { (f2($0.threshold), $0.all.json) }),
            "ms": ms,
        ]
    }
}

extension ClassTally {
    var json: [String: Any] {
        ["matched": matched, "unknown": unknown, "unknown_noface": noFace, "unknown_smallface": smallFace, "unknown_smallbody": smallBody,
         "unknown_lowp": lowConfidence, "labeled": labeled, "known": known, "wrong": wrong, "labeled_missed": unmatched]
    }
}

// MARK: - formatting

/// Nearest-rank percentile, `p` in [0, 1] (Recall.swift / RigSupport convention).
func percentile(_ samples: [Double], _ p: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1)))]
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.1f", 100 * Double(a) / Double(b)) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

extension String {
    func pad(_ n: Int) -> String { self + String(repeating: " ", count: max(0, n - count)) }
    func lpad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

// MARK: - selfcheck

/// Runs the metric math on two synthetic frames and asserts the hand-computed numbers. Exits 1 on the first mismatch.
func selfcheck() {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

    // The category rule equals the app's `categorize` at 0.80 for every p in steps of 0.01 plus the boundaries.
    let face = Size(width: 60, height: 60), body = Size(width: 100, height: 300)
    for p in (0...100).map({ Double($0) / 100 }) + [0.2, 0.8, 0.19999, 0.20001, 0.79999, 0.80001, 1 - 0.2, 1 - 0.8] {
        expect(category(face: face, body: body, pWoman: p, threshold: 0.80) == categorize(face: face, body: body, pWoman: p), "rule mismatch at p=\(p)")
    }
    expect(category(face: nil, body: body, pWoman: 0.95, threshold: 0.8) == .unknown, "no face → unknown")
    expect(category(face: Size(width: 31, height: 60), body: body, pWoman: 0.95, threshold: 0.8) == .unknown, "face 31 px → unknown")
    expect(category(face: face, body: Size(width: 20, height: 39), pWoman: 0.95, threshold: 0.8) == .unknown, "body 39 px → unknown")
    expect(category(face: face, body: body, pWoman: nil, threshold: 0.8) == .unknown, "no p → unknown")
    expect(category(face: face, body: body, pWoman: 0.87, threshold: 0.90) == .unknown && category(face: face, body: body, pWoman: 0.87, threshold: 0.85) == .woman, "threshold applies")

    let frame = Size(width: 1280, height: 960)
    func gt(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Category?, _ tags: [String] = []) -> Observed.GT {
        Observed.GT(box: Rect(x: x, y: y, width: w, height: h), category: c, tags: tags)
    }
    func det(_ x: Double, _ y: Double, _ w: Double, _ h: Double, conf: Float, face: Size?, p: Double?) -> Observed.Det {
        Observed.Det(box: Rect(x: x, y: y, width: w, height: h), confidence: conf, face: face, pWoman: p)
    }
    let one = Observed(frame: frame, gt: [
        gt(100, 100, 200, 400, .woman),  // medium; matched by d0 (IoU 0.86), d3 must not double-match it
        gt(500, 100, 200, 400, .man),  // medium; matched exactly
        gt(900, 100, 20, 30, nil, ["small"]),  // 30 px tall: not eligible
        gt(0, 600, 1280, 300, nil, ["crowd"]),  // crowd: excluded from matching
    ], dets: [
        det(110, 110, 200, 400, conf: 0.9, face: face, p: 0.95),
        det(500, 100, 200, 400, conf: 0.8, face: Size(width: 50, height: 50), p: 0.10),
        det(900, 500, 100, 200, conf: 0.5, face: nil, p: nil),  // false positive
        det(120, 120, 200, 400, conf: 0.7, face: nil, p: nil),  // second box on g0: unmatched (one-to-one)
    ])
    let two = Observed(frame: frame, gt: [
        gt(0, 0, 300, 600, .woman, ["hijab"]),  // large; predicted man → misclassified at 0.80/0.85, Unknown at 0.90
        gt(400, 0, 300, 600, .man, ["profile"]),  // large; p 0.5 → Unknown
        gt(800, 0, 300, 600, nil, ["back"]),  // large, unlabeled; no face → Unknown
        gt(0, 700, 100, 60, .woman, ["child"]),  // p 0.87: woman at 0.80/0.85, Unknown at 0.90
        gt(200, 700, 100, 90, .man, ["low-light"]),  // ge80px; face 31 px → Unknown whatever p says
        gt(400, 700, 100, 100, .woman),  // ge80px, general; no detection → missed
        gt(600, 700, 100, 60, .woman),  // general; matched by a 39 px box (IoU 0.65) → body rule → Unknown
    ], dets: [
        det(0, 0, 300, 600, conf: 0.9, face: Size(width: 40, height: 40), p: 0.15),
        det(400, 0, 300, 600, conf: 0.9, face: Size(width: 40, height: 40), p: 0.5),
        det(800, 0, 300, 600, conf: 0.9, face: nil, p: nil),
        det(0, 700, 100, 60, conf: 0.9, face: Size(width: 32, height: 32), p: 0.87),
        det(200, 700, 100, 90, conf: 0.9, face: Size(width: 31, height: 40), p: 0.05),
        det(600, 700, 100, 39, conf: 0.9, face: Size(width: 40, height: 40), p: 0.95),
    ])
    let matches = [one, two].flatMap { match($0) }
    var report = Report(set: "selfcheck", matches: matches, threshold: 0.80, ms: [("detect", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])])
    report.processed = 2

    func check(_ tag: String, _ hit: Int, _ total: Int) {
        let t = report.recall[tag] ?? Tally()
        expect(t.hit == hit && t.total == total, "recall \(tag): expected \(hit)/\(total), got \(t.hit)/\(t.total)")
    }
    check("all", 8, 9)
    check("ge80px", 6, 7)
    check("large", 3, 3)
    check("medium", 2, 2)
    check("large+medium", 5, 5)
    check("back", 1, 1)
    check("general", 3, 4)
    check("hijab", 1, 1)
    expect(report.recall["small"] == nil && report.recall["crowd"] == nil, "small (< 40 px) and crowd GT are not tallied")

    let all = report.classes["all"] ?? ClassTally()
    expect(all.matched == 8 && all.unknown == 4 && all.labeled == 7 && all.known == 4 && all.wrong == 1 && all.unmatched == 1,
           "classes all @0.80: \(all)")
    expect(all.noFace == 1 && all.smallFace == 1 && all.smallBody == 1 && all.lowConfidence == 1, "unknown reasons: \(all)")
    expect(all.misclassification == "25.0" && all.unknownRate == "50.0", "rates all @0.80: \(all.misclassification) \(all.unknownRate)")
    let hijab = report.classes["hijab"] ?? ClassTally(), general = report.classes["general"] ?? ClassTally()
    expect(hijab.known == 1 && hijab.wrong == 1, "hijab @0.80: \(hijab)")
    expect(general.matched == 3 && general.unknown == 1 && general.known == 2 && general.wrong == 0 && general.unmatched == 1, "general @0.80: \(general)")
    let by = Dictionary(uniqueKeysWithValues: report.byThreshold.map { (f2($0.threshold), $0.all) })
    expect(by["0.85"]?.known == 4 && by["0.85"]?.wrong == 1 && by["0.85"]?.unknown == 4, "@0.85: \(String(describing: by["0.85"]))")
    expect(by["0.90"]?.known == 2 && by["0.90"]?.wrong == 0 && by["0.90"]?.unknown == 6, "@0.90: \(String(describing: by["0.90"]))")
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5 && percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 9, "percentile")

    report.print()
    if failures.isEmpty {
        print("\nselfcheck ok (\(matches.count) eligible GT over 2 synthetic frames)")
    } else {
        print("\nselfcheck FAILED:\n  " + failures.joined(separator: "\n  "))
        exit(1)
    }
}
