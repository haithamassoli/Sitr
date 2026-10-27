// Op placement (MLComputePlan) and model-only latency for one CoreML model with an image input. Research tool for
// docs/models-2026.md; the app's own path (letterbox + prediction + NMS) is measured by sitr-bench.
//   xcrun swiftc -O -swift-version 5 Models/detector/anebench.swift -o Models/work/anebench
//   Models/work/anebench <model.mlpackage|.mlmodelc> [--n 200] [--units ane|all|gpu|cpu]
// Prints: `plan ...` (ops per device, non-ANE op names) and `latency ... p50 p95 min`.
import CoreML
import CoreVideo
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: anebench <model> [--n 200] [--units ane|all|gpu|cpu]"); exit(2) }
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let n = Int(opt("--n") ?? "200")!
let units: MLComputeUnits = ["all": .all, "gpu": .cpuAndGPU, "cpu": .cpuOnly][opt("--units") ?? "ane"] ?? .cpuAndNeuralEngine

var url = URL(fileURLWithPath: args[1])
if url.pathExtension == "mlpackage" { url = try await MLModel.compileModel(at: url) }
let config = MLModelConfiguration()
config.computeUnits = units

// Placement: every op with a device usage (estimatedCost came back nil on macOS 27, so counts only).
let plan = try await MLComputePlan.load(contentsOf: url, configuration: config)
var count: [String: Int] = [:], offANE: [String: Int] = [:]
func walk(_ block: MLModelStructure.Program.Block) {
    for op in block.operations {
        op.blocks.forEach(walk)
        guard let usage = plan.deviceUsage(for: op) else { continue }
        let d: String
        switch usage.preferred { case .neuralEngine: d = "ane"; case .gpu: d = "gpu"; case .cpu: d = "cpu"; default: d = "other" }
        count[d, default: 0] += 1
        if d != "ane" { offANE[op.operatorName, default: 0] += 1 }
    }
}
if case .program(let program) = plan.modelStructure, let main = program.functions["main"] { walk(main.block) }
let total = count.values.reduce(0, +)
print("plan model=\(url.deletingPathExtension().lastPathComponent) ops=\(total) "
    + count.keys.sorted().map { "\($0)=\(count[$0]!)" }.joined(separator: " ")
    + " off_ane=\(offANE.sorted { $0.value > $1.value }.map { "\($0.key)x\($0.value)" }.joined(separator: ","))")

// Latency: one fixed input (BGRA buffer of mid grey + noise; a multiarray input gets the same noise), 10 warm-up, n timed.
let model = try MLModel(contentsOf: url, configuration: config)
let (name, desc) = model.modelDescription.inputDescriptionsByName.first!
let noise = { (i: Int) in UInt8(truncatingIfNeeded: 100 + (i * 2654435761 >> 13) % 56) }
let value: MLFeatureValue
var shape = "\(desc.multiArrayConstraint?.shape ?? [])"
if let c = desc.imageConstraint {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, c.pixelsWide, c.pixelsHigh, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(CVPixelBufferGetBytesPerRow(pb!) * c.pixelsHigh) { base[i] = noise(i) }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    value = MLFeatureValue(pixelBuffer: pb!)
    shape = "\(c.pixelsWide)x\(c.pixelsHigh)"
} else {
    let a = try MLMultiArray(shape: desc.multiArrayConstraint!.shape, dataType: .float32)
    for i in 0..<a.count { a[i] = NSNumber(value: Float(noise(i)) / 255) }
    value = MLFeatureValue(multiArray: a)
}
let input = try MLDictionaryFeatureProvider(dictionary: [name: value])
for _ in 0..<10 { _ = try model.prediction(from: input) }
var ms: [Double] = []
for _ in 0..<n {
    let t = DispatchTime.now().uptimeNanoseconds
    _ = try model.prediction(from: input)
    ms.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
}
ms.sort()
let f = { String(format: "%.2f", $0) }
print("latency model=\(url.deletingPathExtension().lastPathComponent) input=\(shape) units=\(opt("--units") ?? "ane") n=\(n) p50=\(f(ms[n / 2])) p95=\(f(ms[n * 95 / 100])) min=\(f(ms[0]))")
