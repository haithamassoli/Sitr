// M4-T05: the String Catalog parses, every key carries a translated Arabic value whose %-specifiers match the key, the
// FR7 status keys the code uses are present, and the compiled ar.lproj inside build/Sitr.app (when it has been built)
// carries the "Protected" status. Coverage of the code's literals is scripts/check-strings.sh (CI), not this file.
import Foundation
import Testing

@testable import Sitr

// Main actor: `Preferences` is main-actor isolated (the app target's default isolation).
@MainActor @Suite struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalogURL = root.appending(path: "App/Resources/Localizable.xcstrings")
    private static let compiledArabic = root.appending(path: "build/Sitr.app/Contents/Resources/ar.lproj/Localizable.strings")

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable {
                    let state: String
                    let value: String
                }
                let stringUnit: Unit?
            }
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private static func load() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    }

    /// `%@`, `%lld`, `%2$@` … as their bare type letters, sorted: positional reordering in a translation is allowed,
    /// a missing or extra argument is not (it would crash or print garbage at runtime).
    private static func specifiers(_ text: String) -> [String] {
        text.matches(of: #/%(?:\d+\$)?([a-zA-Z@]+)/#).map { String($0.1) }.sorted()
    }

    @Test func catalogParsesWithEnglishAsTheSourceLanguage() throws {
        let catalog = try Self.load()
        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.strings.count > 100)
    }

    @Test func everyKeyHasATranslatedArabicValueWithMatchingSpecifiers() throws {
        let catalog = try Self.load()
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            let arabic = entry.localizations?["ar"]?.stringUnit
            #expect(arabic != nil, "no Arabic localization for \"\(key)\"")
            guard let arabic else { continue }
            #expect(arabic.state == "translated", "\"\(key)\" is \(arabic.state)")
            #expect(!arabic.value.trimmingCharacters(in: .whitespaces).isEmpty, "empty Arabic value for \"\(key)\"")
            #expect(Self.specifiers(arabic.value) == Self.specifiers(key), "format specifiers differ for \"\(key)\": \(arabic.value)")
        }
    }

    @Test func menuBarStatusKeysAreInTheCatalog() throws {
        let strings = try Self.load().strings
        for key in ["Protected", "Paused until %@", "Disabled", "Needs Screen Recording permission", "Degraded"] {
            #expect(strings[key] != nil, "missing \(key)")
        }
        // The test process has no ar.lproj, so the texts come back as their keys; they must be exactly those keys.
        #expect(AppModel.Status.protected.text == "Protected")
        #expect(AppModel.Status.degraded.text == "Degraded")
    }

    /// AppKit takes the layout direction from `AppleTextDirection`, so the in-app language choice must write it too.
    @Test func languageChoiceWritesTheLayoutDirectionNextToAppleLanguages() {
        #expect(AppLanguage.system.appleTextDirection == nil)
        #expect(AppLanguage.english.appleTextDirection == false)
        #expect(AppLanguage.arabic.appleTextDirection == true)
        let suite = "SitrTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.language = .arabic
        #expect(defaults.persistentDomain(forName: suite)?["AppleTextDirection"] as? Bool == true)
        preferences.language = .english
        #expect(defaults.persistentDomain(forName: suite)?["AppleTextDirection"] as? Bool == false)
        preferences.language = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleTextDirection"] == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func compiledArabicStringsCarryTheProtectedStatus() throws {
        guard FileManager.default.fileExists(atPath: Self.compiledArabic.path) else { return }  // scripts/build-app.sh not run
        let table = try #require(NSDictionary(contentsOf: Self.compiledArabic) as? [String: String])
        let protected = try #require(table["Protected"])
        #expect(!protected.isEmpty && protected != "Protected")
        #expect(table["Paused until %@"]?.contains("%@") == true)
    }
}
