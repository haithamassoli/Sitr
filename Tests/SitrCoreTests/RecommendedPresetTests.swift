import Testing

@testable import SitrCore

@Suite struct RecommendedPresetTests {
    @Test func applyAddsCurtainOverridesAndLeavesTheDefaultRuleAlone() {
        var rules = Rules()
        RecommendedPreset.apply(to: &rules)
        #expect(rules.defaultMode == .off)
        #expect(rules.overrides.count == RecommendedPreset.bundleIDs.count)
        #expect(rules.overrides.allSatisfy { $0.mode == .curtain })
        #expect(RecommendedPreset.isApplied(rules))
        var blur = Rules(defaultMode: .blur)
        RecommendedPreset.apply(to: &blur)
        #expect(blur.defaultMode == .blur)
        #expect(blur.overrides == rules.overrides)
    }

    @Test func presetCoversTheFR6Apps() {
        let ids = Set(RecommendedPreset.bundleIDs)
        let browsers: Set = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"]
        let messengers: Set = [
            "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram",  // Telegram: three builds
            "net.whatsapp.WhatsApp", "com.hnc.Discord",
        ]
        #expect(ids.isSuperset(of: browsers) && ids.isSuperset(of: messengers))
        #expect(ids.count == RecommendedPreset.bundleIDs.count)  // no duplicates
        #expect(!RecommendedPreset.isApplied(Rules()))
    }

    @Test func reapplyIsIdempotent() {
        var rules = Rules()
        RecommendedPreset.apply(to: &rules)
        let once = rules
        RecommendedPreset.apply(to: &rules)
        #expect(rules == once)
    }

    @Test func userEditToAPresetAppSurvivesUntilReapply() {
        var rules = Rules()
        RecommendedPreset.apply(to: &rules)
        rules.upsert(AppRule(bundleID: "com.apple.Safari", mode: .blur))
        rules.remove(bundleID: "com.hnc.Discord")
        #expect(rules.mode(for: "com.apple.Safari") == .blur)
        #expect(rules.mode(for: "com.hnc.Discord") == .off)
        #expect(rules.mode(for: "com.google.Chrome") == .curtain)  // the rest untouched
        #expect(!RecommendedPreset.isApplied(rules))
        RecommendedPreset.apply(to: &rules)
        #expect(rules.mode(for: "com.apple.Safari") == .curtain)
        #expect(rules.mode(for: "com.hnc.Discord") == .curtain)
        #expect(RecommendedPreset.isApplied(rules))
        #expect(rules.overrides.count == RecommendedPreset.bundleIDs.count)
    }

    @Test func nonPresetOverridesAreUntouched() {
        let notes = AppRule(bundleID: "com.apple.Notes", mode: .off)
        let zoom = AppRule(bundleID: "us.zoom.xos", mode: .blur)
        var rules = Rules(defaultMode: .curtain, overrides: [notes, zoom])
        RecommendedPreset.apply(to: &rules)
        #expect(Array(rules.overrides.prefix(2)) == [notes, zoom])
        #expect(rules.overrides.count == 2 + RecommendedPreset.bundleIDs.count)
        #expect(rules.defaultMode == .curtain)
        #expect(RecommendedPreset.isApplied(rules))
    }
}
