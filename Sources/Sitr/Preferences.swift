import Foundation
import Observation
import SitrCore

/// General › Language (M4-T04, FR12): the standard `AppleLanguages` override in the app's own defaults domain; the process
/// reads it at launch, hence the "Relaunch now" button. `system` removes the override.
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case system, english = "en", arabic = "ar"

    /// Value for `AppleLanguages`; nil = remove the key so the system language list applies again.
    var appleLanguages: [String]? { self == .system ? nil : [rawValue] }

    var title: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .arabic: "العربية"
        }
    }
}

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
    /// General (M4-T04). `language` also writes / removes `AppleLanguages` in the same domain.
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            if let languages = language.appleLanguages {
                defaults.set(languages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    /// "Reduce frame rate in Low Power Mode" (default on). The capture side that honours it is M4-T06.
    var lowPowerReducesFrameRate: Bool { didSet { defaults.set(lowPowerReducesFrameRate, forKey: "lowPowerReducesFrameRate") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenSet = Self.load(key: "hiddenSet", from: defaults) ?? .everyone
        strictMode = defaults.object(forKey: "strictMode") as? Bool ?? true
        hotkey = Self.load(key: "hotkey", from: defaults) ?? .default
        coverStyle = defaults.string(forKey: "coverStyle").flatMap(CoverStyle.init(rawValue:)) ?? .gaussian
        blurStrength = defaults.object(forKey: "blurStrength") as? Double ?? 0.7
        bodyPadding = defaults.object(forKey: "bodyPadding") as? Double ?? 0.15
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        lowPowerReducesFrameRate = defaults.object(forKey: "lowPowerReducesFrameRate") as? Bool ?? true
    }

    private func store(_ value: some Encodable, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
