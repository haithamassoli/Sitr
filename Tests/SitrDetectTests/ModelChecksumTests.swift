import CryptoKit
import Foundation
import Testing

// Pins the shipped Core ML models: every Models/dist/CHECKSUMS*.txt line (`shasum -a 256` format, paths relative to
// Models/dist/) must match the file on disk, and every file inside a Models/dist/*.mlpackage must be listed somewhere.
// Regenerate a list with: cd Models/dist && find <Name>.mlpackage -type f | sort | xargs shasum -a 256 > CHECKSUMS-<...>.txt
private let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Models/dist", isDirectory: true)

private func checksumLists() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("CHECKSUMS") && $0.pathExtension == "txt" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Parses `<64 hex>  <path>` lines; a leading `*` on the path (shasum binary mode) is dropped.
private func entries(of list: URL) throws -> [(hash: String, path: String)] {
    try String(contentsOf: list, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].count == 64 else {
            Issue.record("malformed line in \(list.lastPathComponent): \(line)")
            return nil
        }
        return (String(parts[0]).lowercased(), String(parts[1].drop { $0 == " " || $0 == "*" }))
    }
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}

@Test func shippedModelFilesMatchTheirChecksums() throws {
    let lists = try checksumLists()
    #expect(!lists.isEmpty, "no Models/dist/CHECKSUMS*.txt found")
    for list in lists {
        let listed = try entries(of: list)
        #expect(!listed.isEmpty, "\(list.lastPathComponent) is empty")
        for entry in listed {
            let file = dist.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                Issue.record("\(list.lastPathComponent): missing file \(entry.path)")
                continue
            }
            #expect(try sha256(file) == entry.hash, "\(list.lastPathComponent): SHA-256 mismatch for \(entry.path)")
        }
    }
}

@Test func everyFileInEveryShippedPackageIsListed() throws {
    let listed = Set(try checksumLists().flatMap { try entries(of: $0).map(\.path) })
    let packages = try FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "mlpackage" }
    #expect(!packages.isEmpty, "no Models/dist/*.mlpackage found")
    for package in packages {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let files = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: Array(keys)))
        for case let file as URL in files where try file.resourceValues(forKeys: keys).isRegularFile == true {
            let relative = file.path.replacingOccurrences(of: dist.path + "/", with: "")
            #expect(listed.contains(relative), "\(relative) is not in any Models/dist/CHECKSUMS*.txt")
        }
    }
}
