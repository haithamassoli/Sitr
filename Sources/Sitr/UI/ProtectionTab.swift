import AppKit
import SitrCore
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension AppRule: Identifiable {
    public var id: String { bundleID }
}

extension RuleMode {
    var title: String {
        switch self {
        case .off: String(localized: "Off", comment: "Per-app rule mode: the app is never captured")
        case .blur: String(localized: "Blur", comment: "Per-app rule mode: detect, then cover")
        case .curtain: String(localized: "Curtain", comment: "Per-app rule mode: cover changes at once, uncover what is verified safe")
        }
    }
}

/// Settings › Protection (M2-T14 hidden set + Strict, M3-T08 rules): Default Rule, overrides table, Add, Recommended preset.
/// Every change goes through `AppModel.updateRules`, which reaches the pipelines live and saves `rules.json`.
struct ProtectionTab: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var addProblem: String?
    @State private var confirmReset = false
    @State private var appInfoRevision = 0

    private var rules: Rules { model.policy.rules }
    private var presetApplied: Bool { RecommendedPreset.isApplied(rules) }

    var body: some View {
        Form {
            if model.showSetupSummary {
                Section("Setup complete") {
                    Text(model.statusText)
                    Text(model.scopeText)
                    Text("Review the apps below. Saved rules for apps that are not installed will apply when you install them.")
                    Button("Dismiss setup summary") { model.showSetupSummary = false }
                }
            }
            if let problem = model.rulesProblem {
                Section {
                    Text(problem).foregroundStyle(.red)
                    if model.rulesNeedRecovery {
                        Button("Retry Reading Rules") { model.reloadRules() }
                        Button("Reset Rules…", role: .destructive) { confirmReset = true }
                    } else {
                        Button("Retry Saving") { model.saveRules() }
                    }
                }
            }
            Section {
                Picker("Hide", selection: Binding(get: { model.policy.hiddenSet }, set: { model.setHiddenSet($0) })) {
                    Text("Women").tag(HiddenSet.women)
                    Text("Men").tag(HiddenSet.men)
                    Text("Everyone").tag(HiddenSet.everyone)
                }
                .accessibilityLabel("Hidden set")
                .accessibilityHint("Who gets covered. Everyone includes people Sitr cannot classify.")
                // PRD: Everyone forces Strict Mode on and disables the toggle.
                Toggle("Blur Unknown (Strict Mode)", isOn: Binding(get: { model.policy.effectiveStrict }, set: { model.setStrict($0) }))
                    .disabled(model.policy.hiddenSet == .everyone)
                    .accessibilityLabel("Blur Unknown, Strict Mode")
                    .accessibilityHint(
                        model.policy.hiddenSet == .everyone
                            ? String(localized: "Always on while Everyone is selected", comment: "Accessibility hint for the Strict Mode toggle")
                            : String(localized: "Also covers people whose category is unknown", comment: "Accessibility hint for the Strict Mode toggle"))
            } footer: {
                Text("Unknown: facing away, face hidden or too small, or the classifier is unsure.")
            }
            Section {
                Picker("Default Rule", selection: Binding(get: { rules.defaultMode }, set: { mode in model.updateRules { $0.defaultMode = mode } })) {
                    ForEach(RuleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityLabel("Default Rule")
                .accessibilityHint("Mode for every app without an override. Off means never captured.")
            } footer: {
                Text("For apps without an override. Off: never captured. Blur: detect, then cover. Curtain: cover changes at once, uncover what is verified safe.")
            }
            Section {
                if rules.overrides.isEmpty {
                    Text("No app overrides. Add an app or apply the recommended settings below.")
                        .foregroundStyle(.secondary)
                }
                Table(rules.overrides, selection: $selection) {
                    TableColumn("App") { rule in AppCell(bundleID: rule.bundleID, revision: appInfoRevision) }
                    TableColumn("Mode") { rule in
                        let name = AppInfo.lookup(rule.bundleID).name
                        Picker("Mode", selection: Binding(get: { rule.mode }, set: { mode in model.updateRules { $0.upsert(AppRule(bundleID: rule.bundleID, mode: mode)) } })) {
                            ForEach(RuleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Mode for \(name)")
                    }
                    .width(110)
                    TableColumn("") { rule in
                        let name = AppInfo.lookup(rule.bundleID).name
                        Button { remove([rule.bundleID]) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(name)")
                    }
                    .width(24)
                }
                .frame(height: 190)  // fixed: the table scrolls, the buttons below stay in view
                .onDeleteCommand { remove(selection) }
                .accessibilityLabel("App overrides")
                HStack {
                    Menu {
                        ForEach(Self.runningApps, id: \.id) { app in
                            Button(app.name) { add(app.id) }
                        }
                        Divider()
                        Button("Other…") { addFromOpenPanel() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                    .accessibilityLabel("Add app override")
                    .accessibilityHint("Pick a running app, or Other to choose an app file")
                    Button("Use recommended settings") { model.updateRules { RecommendedPreset.apply(to: &$0) } }
                        .disabled(presetApplied)
                        .accessibilityLabel("Use recommended settings")
                        .accessibilityHint("Sets Safari, Chrome, Arc, Telegram, WhatsApp and Discord to Curtain")
                    Spacer()
                }
                if presetApplied {
                    Label("Recommended settings applied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if let addProblem {
                    Text(addProblem).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("App overrides")
            } footer: {
                Text("Recommended: Safari, Chrome, Arc, Telegram, WhatsApp and Discord as Curtain; the Default Rule stays. Removing an override restores the Default Rule, which may still protect that app.")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            AppInfo.refresh()
            appInfoRevision += 1
        }
        .onAppear { AppInfo.refresh(); appInfoRevision += 1 }
        .confirmationDialog(String(localized: "Reset all protection rules?"), isPresented: $confirmReset) {
            Button("Reset Rules", role: .destructive) { model.resetRules() }
        } message: {
            Text("Sitr will keep a recovery copy of the existing file and set all apps to Off.")
        }
    }

    /// Running apps with a Dock presence (`.regular`), sorted by name, ourselves excluded.
    private static var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// New overrides start as Blur (the mode most overrides want once the Default Rule is Off); the row's picker changes it.
    private func add(_ bundleID: String) {
        addProblem = nil
        if !rules.overrides.contains(where: { $0.bundleID == bundleID }) {
            model.updateRules { $0.upsert(AppRule(bundleID: bundleID, mode: .blur)) }
        }
        selection = [bundleID]
    }

    private func remove(_ bundleIDs: Set<String>) {
        model.updateRules { rules in bundleIDs.forEach { rules.remove(bundleID: $0) } }
        selection.subtract(bundleIDs)
    }

    /// "Other…": any `.app` (installed anywhere; the sandbox's user-selected read-only entitlement covers the lookup).
    private func addFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications")
        panel.message = String(localized: "Choose an app to add an override for.", comment: "Open panel prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bundleID = Bundle(url: url)?.bundleIdentifier {
            add(bundleID)
        } else {
            let file = url.lastPathComponent
            addProblem = String(localized: "\(file) has no bundle identifier, so no rule can be stored for it.", comment: "Error under the overrides table; %@ is the chosen file name")
        }
    }
}

/// Name and icon for a bundle ID; apps that are not installed show the generic app icon and their bundle ID (PRD FR6).
struct AppInfo {
    let name: String
    let icon: NSImage
    let installed: Bool

    // ponytail: refreshed when Settings activates; observe installation events if live updates become necessary.
    private static var cache: [String: AppInfo] = [:]

    static func refresh() { cache = [:] }

    static func lookup(_ bundleID: String) -> AppInfo {
        if let hit = cache[bundleID] { return hit }
        let info: AppInfo
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle?.infoDictionary?["CFBundleDisplayName"]
                ?? bundle?.infoDictionary?["CFBundleName"]) as? String
            info = AppInfo(name: name ?? url.deletingPathExtension().lastPathComponent, icon: NSWorkspace.shared.icon(forFile: url.path), installed: true)
        } else {
            info = AppInfo(name: bundleID, icon: NSWorkspace.shared.icon(for: .applicationBundle), installed: false)
        }
        cache[bundleID] = info
        return info
    }
}

private struct AppCell: View {
    let bundleID: String
    let revision: Int

    var body: some View {
        let info = AppInfo.lookup(bundleID)
        HStack(spacing: 6) {
            Image(nsImage: info.icon).resizable().frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name)
                if info.installed {
                    Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Not installed").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
