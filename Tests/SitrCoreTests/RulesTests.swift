import Foundation
import Testing

@testable import SitrCore

@Suite struct RulesTests {
    let safari = AppRule(bundleID: "com.apple.Safari", mode: .curtain)
    let notes = AppRule(bundleID: "com.apple.Notes", mode: .off)

    @Test func defaultsAreOffWithNoOverrides() {
        let rules = Rules()
        #expect(rules.defaultMode == .off)
        #expect(rules.overrides.isEmpty)
        #expect(rules.schemaVersion == Rules.currentSchema)
        #expect(rules.mode(for: "com.apple.Safari") == .off)
        #expect(!rules.isMonitored("com.apple.Safari") && !rules.isMonitored(nil))
    }

    @Test func overrideBeatsDefaultAndUnknownAppTakesDefault() {
        let rules = Rules(defaultMode: .blur, overrides: [safari])
        #expect(rules.mode(for: "com.apple.Safari") == .curtain)
        #expect(rules.mode(for: "com.apple.Notes") == .blur)
        #expect(rules.mode(for: nil) == .blur)  // owner unknown
        #expect(rules.isMonitored("com.apple.Safari") && rules.isMonitored("com.apple.Notes") && rules.isMonitored(nil))
    }

    @Test func offOverrideWinsForThatAppOnly() {
        let rules = Rules(defaultMode: .curtain, overrides: [notes])
        #expect(rules.mode(for: "com.apple.Notes") == .off)
        #expect(!rules.isMonitored("com.apple.Notes"))
        #expect(rules.mode(for: "com.apple.Safari") == .curtain)
        #expect(rules.isMonitored("com.apple.Safari"))
        #expect(rules.mode(for: nil) == .curtain)
    }

    @Test func upsertReplacesInPlaceAndRemoveDeletes() {
        var rules = Rules()
        rules.upsert(safari)
        rules.upsert(notes)
        rules.upsert(AppRule(bundleID: "com.apple.Safari", mode: .blur))
        #expect(rules.overrides == [AppRule(bundleID: "com.apple.Safari", mode: .blur), notes])  // no duplicate
        rules.remove(bundleID: "com.apple.Safari")
        #expect(rules.overrides == [notes])
        rules.remove(bundleID: "com.example.NeverAdded")
        #expect(rules.overrides == [notes])
    }

    @Test func roundTripThroughTheStore() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.load() == Rules())  // missing file → defaults
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))  // and nothing written
        var rules = Rules(defaultMode: .blur, overrides: [safari, notes])
        try store.save(rules)  // creates the directory
        #expect(store.load() == rules)
        rules.defaultMode = .curtain
        rules.remove(bundleID: "com.apple.Notes")
        try store.save(rules)  // overwrite
        #expect(store.load() == rules)
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
    }

    @Test func fileIsHandEditableJSON() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(Rules(defaultMode: .blur, overrides: [safari]))
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"defaultMode\" : \"blur\""))
        #expect(text.contains("\"bundleID\" : \"com.apple.Safari\"") && text.contains("\"mode\" : \"curtain\""))
        let edited = """
            {"schemaVersion": 1, "defaultMode": "off",
             "overrides": [{"bundleID": "com.hnc.Discord", "mode": "curtain"}]}
            """
        try edited.write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(store.load() == Rules(overrides: [AppRule(bundleID: "com.hnc.Discord", mode: .curtain)]))
    }

    @Test(arguments: [
        "{\"schemaVersion\": 2, \"defaultMode\": \"blur\", \"overrides\": []}",  // future schema
        "{\"defaultMode\": \"blur\", \"overrides\": []}",  // no version
        "{\"schemaVersion\": 1, \"defaultMode\": \"sepia\", \"overrides\": []}",  // unknown mode
        "not json",
    ])
    func unreadableFileFallsBackToDefaultsAndPreservesRecoveryCopies(content: String) throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "older backup".write(to: store.backupURL, atomically: true, encoding: .utf8)
        try content.write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.loadChecked() }
        #expect(store.load() == Rules())
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == content)
        try store.preserveForRecovery()
        #expect(try String(contentsOf: store.backupURL, encoding: .utf8) == "older backup")
        let backups = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".bak") && $0.lastPathComponent != store.backupURL.lastPathComponent }
        #expect(backups.count == 1)
        #expect(try String(contentsOf: #require(backups.first), encoding: .utf8) == content)
        try store.save(Rules(defaultMode: .curtain))
        #expect(try store.loadChecked() == Rules(defaultMode: .curtain))
    }

    private func makeStore() -> RulesStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SitrRulesTests-\(UUID().uuidString)")
        return RulesStore(directory: directory)
    }
}
