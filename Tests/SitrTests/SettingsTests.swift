// M3-T08 / M4-T02 / M4-T04 unit tests: rules editing through AppModel (policy hook + rules.json), the language mapping,
// the Low Power key, the About texts, and the Appearance preview's synthetic frame through the real renderer.
import AppKit
import CoreVideo
import Foundation
import SitrCore
import Testing

@testable import Sitr

@MainActor @Suite struct RulesSettingsTests {
    private let suite = "SitrTests.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SitrTests-\(UUID().uuidString)")
    private var store: RulesStore { RulesStore(directory: directory) }

    private func makeModel() -> AppModel {
        AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!), rulesStore: store)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    @Test func missingFileSeedsOffInMemoryOnly() {
        // M4-T01: the PRD's initial Default Rule; Blur only with SITR_DEV_BLUR=1 before onboarding (OnboardingTests).
        let model = makeModel()
        #expect(model.policy.rules == Rules(defaultMode: .off))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        cleanUp()
    }

    @Test func editsReachThePolicyHookAndTheFile() {
        let model = makeModel()
        var seen: [Rules] = []
        model.onPolicyChanged = { seen.append($0.rules) }
        model.updateRules { $0.upsert(AppRule(bundleID: "com.example.Chat", mode: .curtain)) }
        model.updateRules { $0.defaultMode = .blur }
        model.updateRules { $0.defaultMode = .blur }  // no change: no hook call, no write
        #expect(seen.count == 2)
        #expect(model.policy.rules.mode(for: "com.example.Chat") == .curtain)
        #expect(model.policy.rules.mode(for: "com.example.Other") == .blur)
        #expect(store.load() == model.policy.rules)
        model.updateRules { $0.remove(bundleID: "com.example.Chat") }
        #expect(model.policy.rules.overrides.isEmpty)
        #expect(store.load().overrides.isEmpty)
        #expect(makeModel().policy.rules.defaultMode == .blur)  // a fresh model reads the file, not the Off seed
        cleanUp()
    }

    @Test func recommendedPresetStateFollowsTheRules() {
        let model = makeModel()
        #expect(!RecommendedPreset.isApplied(model.policy.rules))
        model.updateRules { RecommendedPreset.apply(to: &$0) }
        #expect(RecommendedPreset.isApplied(model.policy.rules))
        #expect(model.policy.rules.defaultMode == .off)  // the preset leaves the Default Rule alone
        #expect(store.load().mode(for: "com.apple.Safari") == .curtain)
        model.updateRules { $0.upsert(AppRule(bundleID: "com.apple.Safari", mode: .blur)) }  // a user edit un-applies it
        #expect(!RecommendedPreset.isApplied(model.policy.rules))
        #expect(store.load().mode(for: "com.apple.Safari") == .blur)
        cleanUp()
    }

    @Test func appInfoFallsBackToTheBundleIDAndAGenericIcon() {
        let missing = AppInfo.lookup("com.example.NotInstalled.\(UUID().uuidString)")
        #expect(!missing.installed && missing.name.hasPrefix("com.example.NotInstalled"))
        #expect(missing.icon.size.width > 0)
        let finder = AppInfo.lookup("com.apple.finder")
        #expect(finder.installed && finder.name == "Finder")
    }
}

@MainActor @Suite struct GeneralAndAboutTests {
    @Test func languageMapsToAppleLanguages() {
        #expect(AppLanguage.system.appleLanguages == nil)
        #expect(AppLanguage.english.appleLanguages == ["en"])
        #expect(AppLanguage.arabic.appleLanguages == ["ar"])
        #expect(AppLanguage.allCases.map(\.title) == ["System", "English", "العربية"])
    }

    @Test func languagePreferenceWritesTheOverrideIntoTheAppDomain() {
        let suite = "SitrTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.language == .system)
        preferences.language = .arabic
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["ar"])
        #expect(Preferences(defaults: defaults).language == .arabic)
        preferences.language = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(Preferences(defaults: defaults).language == .system)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func lowPowerToggleDefaultsOnAndPersists() {
        let suite = "SitrTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.lowPowerReducesFrameRate)
        preferences.lowPowerReducesFrameRate = false
        #expect(!Preferences(defaults: defaults).lowPowerReducesFrameRate)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func aboutTexts() {
        #expect(AboutTab.verifyCommand == "codesign -d --entitlements :- --xml /Applications/Sitr.app")
        #expect(AboutTab.verifyHint.contains("app-sandbox") && AboutTab.verifyHint.contains("network"))
        #expect(AboutTab.repositoryURL.absoluteString == "https://github.com/haithamassoli/Sitr")
        #expect(AppModel.releasesURL.absoluteString.hasPrefix(AboutTab.repositoryURL.absoluteString))
        #expect(AboutTab.noticesURL.lastPathComponent == "THIRD_PARTY_NOTICES.md")
    }

    @Test func settingsTabsMatchFR9() {
        #expect(SettingsView.Tab.allCases.map(\.rawValue) == ["general", "protection", "appearance", "shortcuts", "about"])
        #expect(SettingsView.Tab(rawValue: "appearance") == .appearance)
    }
}

@MainActor @Suite struct AppearancePreviewTests {
    /// BGRA byte quadruple at a point of the scene, in display points.
    private func pixel(_ frame: Frame, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let pb = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let i = y * 2 * CVPixelBufferGetBytesPerRow(pb) + x * 2 * 4
        return (base[i], base[i + 1], base[i + 2], base[i + 3])
    }

    @Test func sampleSceneIsARetinaFrameWithTheFigureWhereTheBoxSays() {
        let scene = SampleScene()
        #expect(scene.frame.width == 960 && scene.frame.height == 600)
        #expect(scene.frame.pixelsPerPoint == 2)
        #expect(CGRect(origin: .zero, size: SampleScene.size).contains(SampleScene.personRect))
        // Row 0 is the top (like a captured frame): the shirt (blue) sits at the box centre, the wall (warm) outside it.
        let shirt = pixel(scene.frame, x: 304, y: 170)
        #expect(shirt.b > shirt.r && shirt.a == 255)
        let wall = pixel(scene.frame, x: 30, y: 180)
        #expect(wall.r > wall.b)
        // The renderer's face estimate for this body box is FR3's ~60 px.
        let face = CoverGeometry.faceEstimate(cover: scene.frame.displayPointsToPixels(SampleScene.personRect).size)
        #expect(face >= 50 && face <= 70)
    }

    @Test func previewRunsTheRealRendererForEveryStyle() {
        let scene = SampleScene()
        let renderer = CoverRenderer()
        for style in CoverStyle.allCases {
            let spec = renderer.render(id: 1, style: style, strength: 0.7, padding: 0.15, rect: SampleScene.personRect, frame: scene.frame)
            #expect(spec.frame.contains(SampleScene.personRect))
            #expect(spec.frame.width > SampleScene.personRect.width)  // padding applied
            #expect((style == .solid) == (spec.contents == nil))
            #expect((style == .solid) == (spec.color != nil))
        }
        let view = PreviewView()
        view.render(style: .pixelate, strength: 1, padding: 0)
        #expect(view.layer?.sublayers?.count == 1)
        #expect(view.layer?.sublayers?.first?.frame.width == SampleScene.personRect.width)
    }
}
