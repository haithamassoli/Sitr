// App rules (M3-T01, PRD FR6): the Default Rule plus per-app overrides, and their JSON store.
// Foundation here is JSON coding and FileManager only; the directory is injected so tests use a temp dir.

import Foundation

/// Per-app mode. `off`: never captured or analyzed. `blur`: detect, then cover. `curtain`: pre-cover changed regions.
public enum RuleMode: String, Hashable, Sendable, Codable, CaseIterable {
    case off, blur, curtain

    /// How a track in an app of this mode is covered; nil for Off (no cover).
    public var coverMode: CoverMode? {
        switch self {
        case .off: nil
        case .blur: .blur
        case .curtain: .curtain
        }
    }
}

/// One override. Apps are keyed by bundle ID so rules for apps that are not installed are allowed.
public struct AppRule: Hashable, Sendable, Codable {
    public var bundleID: String
    public var mode: RuleMode

    public init(bundleID: String, mode: RuleMode) {
        self.bundleID = bundleID
        self.mode = mode
    }
}

/// Default Rule (mode for every app without an override; initial Off, Blur or Curtain = "Entire Mac") and overrides.
public struct Rules: Hashable, Sendable, Codable {
    /// Bump when the JSON shape changes; `RulesStore.load` treats any other stored value as unreadable.
    public static let currentSchema = 1

    public var schemaVersion = Rules.currentSchema
    public var defaultMode: RuleMode
    public var overrides: [AppRule]

    public init(defaultMode: RuleMode = .off, overrides: [AppRule] = []) {
        self.defaultMode = defaultMode
        self.overrides = overrides
    }

    /// Override beats default; an unknown app, or nil (owner unknown), resolves to the Default Rule.
    public func mode(for bundleID: String?) -> RuleMode {
        overrides.first { $0.bundleID == bundleID }?.mode ?? defaultMode
    }

    /// Whether the app is captured at all (mode is not Off).
    public func isMonitored(_ bundleID: String?) -> Bool {
        mode(for: bundleID) != .off
    }

    /// Replaces the override for `rule.bundleID`, or appends one.
    public mutating func upsert(_ rule: AppRule) {
        if let i = overrides.firstIndex(where: { $0.bundleID == rule.bundleID }) {
            overrides[i] = rule
        } else {
            overrides.append(rule)
        }
    }

    public mutating func remove(bundleID: String) {
        overrides.removeAll { $0.bundleID == bundleID }
    }
}

/// `rules.json` in an injected directory (the app passes Application Support). Atomic writes; unreadable content is
/// kept aside as `rules.json.bak` and replaced by defaults, so a bad edit never blocks the app.
public struct RulesStore: Sendable {
    public static let fileName = "rules.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appending(path: Self.fileName) }
    public var backupURL: URL { directory.appending(path: Self.fileName + ".bak") }

    /// Missing file → `Rules()`. Undecodable or unknown `schemaVersion` → `Rules()`, with the file moved to
    /// `rules.json.bak`.
    public func load() -> Rules {
        guard let data = try? Data(contentsOf: fileURL) else { return Rules() }
        if let rules = try? JSONDecoder().decode(Rules.self, from: data), rules.schemaVersion == Rules.currentSchema {
            return rules
        }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return Rules()
    }

    /// Creates the directory if needed; the write is atomic. Pretty-printed with sorted keys, so the file is
    /// hand-editable.
    public func save(_ rules: Rules) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: fileURL, options: .atomic)
    }
}
