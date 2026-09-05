// Recommended Protection preset (M3-T07, PRD FR6): browsers and messengers as Curtain; the Default Rule is untouched.

public enum RecommendedPreset {
    /// Bundle IDs verified on a real install where possible: Safari, Chrome, Arc, WhatsApp, Discord and the Mac App
    /// Store build of Telegram Desktop (`com.tdesktop.Telegram`) checked on this machine; `ru.keepcoder.Telegram`
    /// (Telegram for macOS, Swift) and `org.telegram.desktop` (Telegram Desktop from telegram.org) from their sources.
    public static let bundleIDs = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram",
        "net.whatsapp.WhatsApp", "com.hnc.Discord",
    ]

    public static let rules = bundleIDs.map { AppRule(bundleID: $0, mode: .curtain) }

    /// Upserts every preset override; existing overrides for other apps and `defaultMode` stay as they are.
    public static func apply(to rules: inout Rules) {
        for rule in Self.rules { rules.upsert(rule) }
    }

    /// True while every preset app carries its preset override (a user edit to one of them makes this false).
    public static func isApplied(_ rules: Rules) -> Bool {
        Self.rules.allSatisfy { rules.overrides.contains($0) }
    }
}
