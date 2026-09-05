// Train a Create ML image classifier (Apple's scene-print feature extractor, logistic-regression head) on
// labeled directories. Standalone script so Package.swift stays untouched.
//
//   xcrun swiftc -O -swift-version 6 -framework CreateML Models/train_createml.swift -o Models/work/train_createml
//   Models/work/train_createml <train-dir> <val-dir> <out.mlmodel> [iterations]
//
// <train-dir>/<val-dir> hold one folder per class (woman/, man/) of face crops in the app's framing
// (Models/fairface.py export, then `sitr-spike classifier --crop-dir`).
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: train_createml <train-dir> <val-dir> <out.mlmodel> [iterations]")
    exit(2)
}
let train = URL(fileURLWithPath: args[1])
let validation = URL(fileURLWithPath: args[2])
let output = URL(fileURLWithPath: args[3])
let iterations = args.count > 4 ? Int(args[4]) ?? 25 : 25

let parameters = MLImageClassifier.ModelParameters(
    validation: .dataSource(.labeledDirectories(at: validation)),
    maxIterations: iterations,
    augmentation: [],  // ponytail: FairFace is already in-the-wild; add flips/crops here if accuracy stalls
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))

let start = Date()
let classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: train), parameters: parameters)
let seconds = Int(Date().timeIntervalSince(start))
print("train_error=\(classifier.trainingMetrics.classificationError) val_error=\(classifier.validationMetrics.classificationError) seconds=\(seconds)")
print(classifier.validationMetrics.confusionDataFrame)

let metadata = MLModelMetadata(
    author: "Sitr",
    shortDescription: "Face gender classifier: Create ML transfer learning (scene-print r2 + logistic regression) on FairFace crops.",
    license: "Apache-2.0 (classifier head, Sitr). Training data: FairFace, CC BY 4.0.",
    version: "1.0")
try classifier.write(to: output, metadata: metadata)
print("wrote \(output.path)")
