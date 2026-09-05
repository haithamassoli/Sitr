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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenSet = Self.load(key: "hiddenSet", from: defaults) ?? .everyone
        strictMode = defaults.object(forKey: "strictMode") as? Bool ?? true
        hotkey = Self.load(key: "hotkey", from: defaults) ?? .default
    }

    private func store(_ value: some Encodable, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
