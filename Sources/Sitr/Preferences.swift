import Foundation
import Observation
import SitrCore

/// Settings that survive relaunch, one `UserDefaults` key each. `@Observable` so the menu and Settings follow changes.
@Observable final class Preferences {
    // ponytail: Everyone + Strict is an M2 placeholder, the PRD has no default hidden set; M4-T01 onboarding forces
    // the choice and these defaults go away.
    var hiddenSet: HiddenSet { didSet { store(hiddenSet, key: "hiddenSet") } }
    var strictMode: Bool { didSet { defaults.set(strictMode, forKey: "strictMode") } }
    var hotkey: KeyCombo { didSet { store(hotkey, key: "hotkey") } }
    /// Cover appearance (PRD FR3 defaults: Gaussian, strength 0.7, padding 0.15). M4-T02 Settings › Appearance edits these.
    var coverStyle: CoverStyle { didSet { defaults.set(coverStyle.rawValue, forKey: "coverStyle") } }
    var blurStrength: Double { didSet { defaults.set(blurStrength, forKey: "blurStrength") } }
    var bodyPadding: Double { didSet { defaults.set(bodyPadding, forKey: "bodyPadding") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenSet = Self.load(key: "hiddenSet", from: defaults) ?? .everyone
        strictMode = defaults.object(forKey: "strictMode") as? Bool ?? true
        hotkey = Self.load(key: "hotkey", from: defaults) ?? .default
        coverStyle = defaults.string(forKey: "coverStyle").flatMap(CoverStyle.init(rawValue:)) ?? .gaussian
        blurStrength = defaults.object(forKey: "blurStrength") as? Double ?? 0.7
        bodyPadding = defaults.object(forKey: "bodyPadding") as? Double ?? 0.15
    }

    private func store(_ value: some Encodable, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
