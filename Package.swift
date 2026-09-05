// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sitr",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SitrCore", targets: ["SitrCore"]),
        .library(name: "SitrDetect", targets: ["SitrDetect"]),
        .executable(name: "sitr-spike", targets: ["SitrSpike"]),
    ],
    targets: [
        // Pure Swift, no AppKit/Vision. Policy, Tracker, Curtain, geometry, state machines.
        .target(name: "SitrCore"),
        // Vision + CoreML + CoreImage wrappers. No AppKit.
        .target(name: "SitrDetect", dependencies: ["SitrCore"]),
        // M1 measurement rigs. Kept after the spike; M2/M3 reuse them.
        .executableTarget(name: "SitrSpike", dependencies: ["SitrCore", "SitrDetect"]),
        .testTarget(name: "SitrCoreTests", dependencies: ["SitrCore"]),
        .testTarget(name: "SitrDetectTests", dependencies: ["SitrDetect"]),
    ]
)
