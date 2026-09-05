// M1-T06: person detector recall over Bench/recall/manifest.json (COCO val2017 person boxes, permissive licenses).
// Each image is resized so its long side is 1280, then 1920. GT bodies count when their height at that scale is
// >= 40 px and iscrowd = 0. Match rules:
//   full     one-to-one greedy by confidence, IoU >= 0.5 (also reported at 0.3)
//   upper    upperBodyOnly boxes cover head+torso, so IoU against a full-body GT is meaningless; match = detection
//            center inside the GT box and detection area >= 30 % of GT area (one-to-one, smallest containing GT)
//   union    GT hit by full (IoU 0.5) or by upper (center rule) — what "full body with upper-body fallback" would give
//   crowd    iscrowd regions are one box for many people; reported separately as "covered": >= 1 full-body detection
//            center inside the region
//   pose     DetectHumanBodyPoseRequest as a second native candidate; box = hull of joints with confidence > 0.1
//            (eyes to ankles, tighter than a body box), so the center rule applies; union3 = full | upper | pose
// Extra tags derived here (scale-free): large = GT height >= 50 % of image height, medium = 20-50 %.
// all_1280set = the GT eligible at 1280, so the 1920 row with that tag compares the same bodies.
import CoreGraphics
import Foundation
import SitrCore
import SitrDetect
import Vision

private let recallUsage = """
usage: sitr-spike recall <manifest.json> [--images <dir>] [--sides 1280,1920] [--limit N] [--dump <dir>]
  images default to <manifest dir>/../data/recall (python3 Bench/download.py --recall)
  --dump writes annotated PNGs (GT green, full-body red, upper-body blue) for the images run; public photos only.
"""

@MainActor
func runRecall(_ args: [String]) {
    guard let manifestPath = args.first(where: { !$0.hasPrefix("--") }), !args.contains("--help") else {
        print(recallUsage)
        exit(2)
    }
    let manifest = URL(fileURLWithPath: manifestPath)
    let images = Rig.value(for: "--images", in: args).map { URL(fileURLWithPath: $0) }
        ?? manifest.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data/recall")
    let sides = (Rig.value(for: "--sides", in: args) ?? "1280,1920").split(separator: ",").compactMap { Int($0) }
    let limit = Int(Rig.value(for: "--limit", in: args) ?? "") ?? .max
    let dump = Rig.value(for: "--dump", in: args).map { URL(fileURLWithPath: $0) }
    Task.detached {
        do {
            try await recall(manifest: manifest, imagesDir: images, sides: sides, limit: limit, dump: dump)
            exit(0)
        } catch {
            print("recall: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

private struct Manifest: Decodable {
    struct Person: Decodable {
        let bbox: [Double]
        let iscrowd: Int
        let tags: [String]
    }
    struct Image: Decodable {
        let fileName: String
        let width: Int
        let height: Int
        let persons: [Person]
    }
    let images: [Image]
}

private struct Tally {
    var hit = 0
    var total = 0
    mutating func add(_ matched: Bool) {
        total += 1
        if matched { hit += 1 }
    }
}

private let tagOrder = ["all", "all_1280set", "large", "medium", "small", "back", "partial"]

private func recall(manifest url: URL, imagesDir: URL, sides: [Int], limit: Int, dump: URL?) async throws {
    if let dump { try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: url))
    let full = PersonDetector(upperBodyOnly: false)
    let upper = PersonDetector(upperBodyOnly: true)
    print("recall_rig chip=\(Rig.chip) manifest=\(url.lastPathComponent) images=\(min(limit, manifest.images.count)) sides=\(sides) note=preliminary/noisy-unless-quiet-phase")
    print("compute persons: \(full.computeDeviceNote)")

    // key: "side|config|match|tag"
    var tallies: [String: Tally] = [:]
    var msFull: [Int: [Double]] = [:], msUpper: [Int: [Double]] = [:], msPose: [Int: [Double]] = [:]
    var missing = 0
    for image in manifest.images.prefix(limit) {
        let file = imagesDir.appendingPathComponent(image.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { missing += 1; continue }
        let original = try Rig.loadImage(file)
        let long = Double(max(image.width, image.height))
        for side in sides {
            let scale = Double(side) / long
            let resized = Rig.resized(original, longSide: side)
            let gt = image.persons.map { p in
                Rect(x: p.bbox[0] * scale, y: p.bbox[1] * scale, width: p.bbox[2] * scale, height: p.bbox[3] * scale)
            }
            var t0 = ContinuousClock.now
            let fullDet = try await full.detect(in: resized)
            msFull[side, default: []].append(Rig.ms(t0.duration(to: .now)))
            t0 = .now
            let upperDet = try await upper.detect(in: resized)
            msUpper[side, default: []].append(Rig.ms(t0.duration(to: .now)))
            t0 = .now
            let poseDet = try await poseDetections(in: resized)
            msPose[side, default: []].append(Rig.ms(t0.duration(to: .now)))

            if let dump {
                try Rig.writePNG(annotated(resized, gt: gt, full: fullDet, upper: upperDet),
                                 to: dump.appendingPathComponent("\(side)_\(image.fileName).png"))
                print("dump image=\(image.fileName) side=\(side) gt=\(gt.count) full=\(fullDet.count) upper=\(upperDet.count)")
            }

            let people = image.persons.indices.filter { image.persons[$0].iscrowd == 0 }
            let peopleGT = people.map { gt[$0] }
            let m50 = matchIoU(peopleGT, fullDet, 0.5), m30 = matchIoU(peopleGT, fullDet, 0.3)
            let mUp = matchCenter(peopleGT, upperDet), mPose = matchCenter(peopleGT, poseDet)
            for (k, i) in people.enumerated() where gt[i].height >= 40 {
                var tags = ["all"] + image.persons[i].tags.filter { $0 != "crowd" }
                if image.persons[i].bbox[3] * 1280 / long >= 40 { tags.append("all_1280set") }
                let fraction = gt[i].height / Double(resized.height)
                if fraction >= 0.5 { tags.append("large") } else if fraction >= 0.2 { tags.append("medium") }
                for tag in tags {
                    tallies["\(side)|full|iou0.5|\(tag)", default: Tally()].add(m50[k])
                    tallies["\(side)|full|iou0.3|\(tag)", default: Tally()].add(m30[k])
                    tallies["\(side)|upper|center30|\(tag)", default: Tally()].add(mUp[k])
                    tallies["\(side)|union|iou0.5+center30|\(tag)", default: Tally()].add(m50[k] || mUp[k])
                    tallies["\(side)|pose|center30|\(tag)", default: Tally()].add(mPose[k])
                    tallies["\(side)|union3|full|upper|pose|\(tag)", default: Tally()].add(m50[k] || mUp[k] || mPose[k])
                }
            }
            for i in image.persons.indices where image.persons[i].iscrowd == 1 && gt[i].height >= 40 {
                let covered = fullDet.contains { gt[i].contains(x: $0.box.midX, y: $0.box.midY) }
                tallies["\(side)|full|covered|crowd", default: Tally()].add(covered)
            }
        }
    }
    if missing > 0 { print("recall_missing_images=\(missing) (run: python3 Bench/download.py --recall)") }

    var table = ["side  config  match             tag          hit/total   recall%"]
    for side in sides {
        for (config, match) in [("full", "iou0.5"), ("full", "iou0.3"), ("upper", "center30"), ("pose", "center30"),
                                ("union", "iou0.5+center30"), ("union3", "full|upper|pose")] {
            for tag in tagOrder {
                guard let t = tallies["\(side)|\(config)|\(match)|\(tag)"] else { continue }
                print("recall side=\(side) config=\(config) match=\(match) tag=\(tag) hit=\(t.hit) total=\(t.total) recall=\(Rig.pct(t.hit, t.total))")
                table.append("\(side)  \(config.padding(toLength: 7, withPad: " ", startingAt: 0)) \(match.padding(toLength: 17, withPad: " ", startingAt: 0)) \(tag.padding(toLength: 12, withPad: " ", startingAt: 0)) \("\(t.hit)/\(t.total)".leftPad(9))   \(Rig.pct(t.hit, t.total).leftPad(6))")
            }
        }
        if let t = tallies["\(side)|full|covered|crowd"] {
            print("recall side=\(side) config=full match=covered tag=crowd hit=\(t.hit) total=\(t.total) recall=\(Rig.pct(t.hit, t.total))")
            table.append("\(side)  full    covered           crowd        \("\(t.hit)/\(t.total)".leftPad(9))   \(Rig.pct(t.hit, t.total).leftPad(6))")
        }
        for (name, samples) in [("full", msFull[side] ?? []), ("upper", msUpper[side] ?? []), ("pose", msPose[side] ?? [])] where !samples.isEmpty {
            print("recall_ms side=\(side) config=\(name) p50=\(Rig.f1(Rig.percentile(samples, 0.5))) p95=\(Rig.f1(Rig.percentile(samples, 0.95))) n=\(samples.count)")
        }
    }
    print(table.joined(separator: "\n"))
}

private let poseRequest = DetectHumanBodyPoseRequest()

/// Hull of confident joints per detected pose, in pixels (top-left origin). Spike-only; SitrDetect gets a wrapper if chosen.
private func poseDetections(in image: CGImage) async throws -> [Detection] {
    let size = Size(width: Double(image.width), height: Double(image.height))
    return try await poseRequest.perform(on: image).compactMap { observation in
        let points = observation.allJoints().values.filter { $0.confidence > 0.1 }.map(\.location.cgPoint)
        guard points.count >= 3, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX, maxY > minY
        else { return nil }
        let hull = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return Detection(box: hull.visionNormalizedToPixels(in: size), confidence: observation.confidence)
    }
}

/// Debug aid: image with GT (green), full-body (red) and upper-body (blue) boxes. Rects are top-left origin; CG is not.
private func annotated(_ image: CGImage, gt: [Rect], full: [Detection], upper: [Detection]) -> CGImage {
    let ctx = Rig.bgraContext(width: image.width, height: image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.setLineWidth(3)
    let h = Double(image.height)
    for (rects, color) in [(gt, CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
                           (full.map(\.box), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                           (upper.map(\.box), CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))] {
        ctx.setStrokeColor(color)
        for r in rects { ctx.stroke(CGRect(x: r.x, y: h - r.maxY, width: r.width, height: r.height)) }
    }
    return ctx.makeImage()!
}

/// One-to-one greedy: detections by confidence, each takes the unmatched GT with the highest IoU >= `threshold`.
private func matchIoU(_ gt: [Rect], _ detections: [Detection], _ threshold: Double) -> [Bool] {
    var matched = [Bool](repeating: false, count: gt.count)
    for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
        var best = -1, bestIoU = threshold
        for (i, g) in gt.enumerated() where !matched[i] {
            let v = g.iou(d.box)
            if v >= bestIoU { bestIoU = v; best = i }
        }
        if best >= 0 { matched[best] = true }
    }
    return matched
}

/// One-to-one greedy: detection center inside GT and detection area >= 30 % of GT area; smallest containing GT wins.
private func matchCenter(_ gt: [Rect], _ detections: [Detection]) -> [Bool] {
    var matched = [Bool](repeating: false, count: gt.count)
    for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
        var best = -1, bestArea = Double.infinity
        for (i, g) in gt.enumerated() where !matched[i] && g.contains(x: d.box.midX, y: d.box.midY) && d.box.area >= 0.3 * g.area {
            if g.area < bestArea { bestArea = g.area; best = i }
        }
        if best >= 0 { matched[best] = true }
    }
    return matched
}
