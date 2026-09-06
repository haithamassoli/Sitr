import AppKit
import SwiftUI

/// Settings › About (M4-T04, M5-T05, PRD FR11): version, license + source, the privacy verification command, the screen
/// sharing / screenshot caveats, model notices, Check for Updates.
struct AboutTab: View {
    static let repositoryURL = URL(string: "https://github.com/haithamassoli/Sitr")!
    static let noticesURL = URL(string: "https://github.com/haithamassoli/Sitr/blob/main/THIRD_PARTY_NOTICES.md")!
    /// What the README tells users to run; the Copy button puts exactly this on the clipboard.
    static let verifyCommand = "codesign -d --entitlements :- --xml /Applications/Sitr.app"
    static let verifyHint = "Look for com.apple.security.app-sandbox set to true and no com.apple.security.network keys: Sitr cannot open a network connection."
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sitr").font(.title2.bold())
                        Text("Version \(AppModel.version) (\(Self.build))").foregroundStyle(.secondary)
                        Text("Hides people on screen, entirely on this Mac.")
                    }
                    Spacer()
                    Button("Check for Updates…") { AppModel.checkForUpdates() }
                        .accessibilityLabel("Check for Updates")
                }
                LabeledContent("License") {
                    Text("GPL-3.0")
                    Link("Source on GitHub", destination: Self.repositoryURL)
                        .accessibilityLabel("Open the Sitr source code on GitHub")
                }
            }
            Section("Verify privacy") {
                HStack {
                    Text(Self.verifyCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.verifyCommand, forType: .string)
                        copied = true
                    }
                    .accessibilityLabel("Copy the verification command")
                }
                Text(Self.verifyHint).font(.callout).foregroundStyle(.secondary)
            }
            Section("Screen sharing and screenshots") {
                Text("Sharing your entire screen usually shows the covers to the viewers. Sharing a single window does not include the overlay, so covers are not guaranteed there. Screenshots include the covers.")
                    .font(.callout)
            }
            Section("Models") {
                Text("Person detector: YOLOX-S by Megvii, Inc. — Apache-2.0.")
                Text("Gender classifier: dima806/fairface_gender_image_detection (ViT-B/16) — Apache-2.0; trained on FairFace, CC BY 4.0.")
                Link("Full notices: THIRD_PARTY_NOTICES.md", destination: Self.noticesURL)
                    .accessibilityLabel("Open THIRD_PARTY_NOTICES.md on GitHub")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
