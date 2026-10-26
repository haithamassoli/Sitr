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

/// Settings › Hide People (M2-T14 hidden set + Strict, M3-T08 rules): status, who, then the app list with "All other
/// apps" (the Default Rule) as its last row. Every change goes through `AppModel.updateRules`, which reaches the pipelines
/// live and saves `rules.json`.
struct ProtectionTab: View {
    let model: AppModel
    @State private var addProblem: String?
    @State private var confirmReset = false
    @State private var appInfoRevision = 0

    private var rules: Rules { model.policy.rules }
    private var presetApplied: Bool { RecommendedPreset.isApplied(rules) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: model.iconState == .warning ? "exclamationmark.triangle.fill" : model.iconState == .normal ? "checkmark.shield.fill" : "shield")
                        .font(.title2)
                        .foregroundStyle(model.status.tone)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.statusText).font(.headline)
                        Text(model.scopeText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProtectionRecovery(model: model)
                }
                .accessibilityElement(children: .contain)
            } footer: {
                if let text = model.recoveryText { Text(text) }
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
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Hidden set")
                .accessibilityHint("Who gets covered. Everyone includes people Sitr cannot classify.")
                // PRD: Everyone forces Strict Mode on and disables the toggle.
                Toggle(isOn: Binding(get: { model.policy.effectiveStrict }, set: { model.setStrict($0) })) {
                    Text("Blur Unknown (Strict Mode)")
                    Text("Unknown: facing away, face hidden or too small, or the classifier is unsure.")
                }
                .disabled(model.policy.hiddenSet == .everyone)
                .accessibilityLabel("Blur Unknown, Strict Mode")
                .accessibilityHint(
                    model.policy.hiddenSet == .everyone
                        ? String(localized: "Always on while Everyone is selected", comment: "Accessibility hint for the Strict Mode toggle")
                        : String(localized: "Also covers people whose category is unknown", comment: "Accessibility hint for the Strict Mode toggle"))
            } header: {
                Text("Who to hide")
            }
            Section {
                // ponytail: rules for apps that are not installed (the preset lists every Telegram build) stay saved but
                // unlisted; they apply once the app is installed.
                let _ = appInfoRevision
                let installed = rules.overrides.filter { AppInfo.lookup($0.bundleID).installed }
                ForEach(installed) { rule in
                    let name = AppInfo.lookup(rule.bundleID).name
                    HStack {
                        AppCell(bundleID: rule.bundleID, revision: appInfoRevision)
                        Spacer()
                        modePicker(Binding(get: { rule.mode }, set: { mode in model.updateRules { $0.upsert(AppRule(bundleID: rule.bundleID, mode: mode)) } }))
                            .accessibilityLabel("Mode for \(name)")
                        Button { remove(rule.bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(Text("Remove \(name)"))
                            .accessibilityLabel("Remove \(name)")
                    }
                }
                HStack {
                    Image(systemName: "square.grid.2x2").frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("All other apps")
                    Spacer()
                    modePicker(Binding(get: { rules.defaultMode }, set: { mode in model.updateRules { $0.defaultMode = mode } }))
                        .accessibilityLabel("All other apps")
                        .accessibilityHint("Mode for every app not in the list. Off means never captured.")
                    Image(systemName: "minus.circle").hidden()  // keeps the picker aligned with the rows above
                }
                HStack {
                    Menu {
                        ForEach(Self.runningApps, id: \.id) { app in
                            Button(app.name) { add(app.id) }
                        }
                        Divider()
                        Button("Other…") { addFromOpenPanel() }
                    } label: {
                        Label("Add App", systemImage: "plus")
                    }
                    .fixedSize()
                    .accessibilityHint("Pick a running app, or Other to choose an app file")
                    if !presetApplied {
                        Button("Add browsers and chat apps") { model.updateRules { RecommendedPreset.apply(to: &$0) } }
                            .accessibilityHint("Sets Safari, Chrome, Arc, Telegram, WhatsApp and Discord to Curtain")
                    }
                    Spacer()
                }
                let notInstalled = rules.overrides.count - installed.count
                if notInstalled > 0 {
                    Text("\(notInstalled) more saved for apps that are not installed. They apply once installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let addProblem {
                    Text(addProblem).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Where to hide")
            } footer: {
                Text("Curtain: covers new content instantly, then uncovers what is safe. Best for browsers and chats. Blur: covers people as soon as they are detected. Off: Sitr never looks at the app.")
            }
            .disabled(model.rulesNeedRecovery)
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

    private func modePicker(_ selection: Binding<RuleMode>) -> some View {
        Picker("Mode", selection: selection) {
            ForEach(RuleMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
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
    }

    private func remove(_ bundleID: String) {
        model.updateRules { $0.remove(bundleID: bundleID) }
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
            Image(nsImage: info.icon).resizable().frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(info.name)
        }
        .accessibilityElement(children: .combine)
    }
}
