import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings › Shortcuts (M4-T03, PRD FR5): the Reveal Hold recorder, its validation message, the static conflict list,
/// Reset to Default. Rebinding goes through `AppModel.setHotkey`, so `HotkeyManager` re-registers without a relaunch.
struct ShortcutsTab: View {
    let model: AppModel
    @State private var problem: String?

    private var combo: KeyCombo { model.preferences.hotkey }

    var body: some View {
        Form {
            Section("Reveal Hold") {
                LabeledContent("Shortcut") {
                    HStack {
                        HotkeyRecorder(combo: combo) { recorded in
                            model.setHotkey(recorded)
                            problem = nil
                        } onReject: { problem = $0 }
                        Button("Reset to Default") {
                            model.setHotkey(.default)
                            problem = nil
                        }
                        .disabled(combo == .default)
                        .accessibilityLabel("Reset shortcut to default, Control Option Space")
                    }
                }
                Text("Hold it to see what is under the covers; release to cover again. Click the field, then press the new keys. ⎋ cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let problem {
                    Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
                }
                if let note = combo.conflictNote {
                    Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                if model.hotkey.registrationStatus != noErr {
                    Label("macOS did not register \(combo.displayString) (error \(model.hotkey.registrationStatus)); choose another shortcut.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            Section("Known conflicts") {
                ForEach(KeyCombo.knownConflicts, id: \.combo) { conflict in
                    LabeledContent(conflict.combo.displayString) { Text(conflict.owner) }
                }
                LabeledContent("⌥ + key") { Text("Typing special characters; regressed in macOS 15.0") }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a key with modifiers. `onRecord` gets valid combos only; `onReject` gets the reason for the others.
struct HotkeyRecorder: NSViewRepresentable {
    let combo: KeyCombo
    let onRecord: (KeyCombo) -> Void
    let onReject: (String) -> Void

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.combo = combo
        view.onRecord = onRecord
        view.onReject = onReject
    }
}

/// A field that records on click (or Space / ↩ while focused, for keyboard users) and turns the next `keyDown` into a
/// `KeyCombo`. Focus alone does not record: the window hands the first focusable view initial focus, and a stray key must
/// not rebind. `performKeyEquivalent` is overridden so ⌘-combos reach it before the main menu (⌘Q is then rejected with a
/// message instead of quitting).
final class RecorderView: NSView {
    var combo: KeyCombo = .default { didSet { needsDisplay = true } }
    var onRecord: ((KeyCombo) -> Void)?
    var onReject: ((String) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 24))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reveal Hold shortcut")
        setAccessibilityHelp("Press to record, then press the new key combination.")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override func accessibilityValue() -> Any? { combo.displayString }
    override func accessibilityPerformPress() -> Bool { startRecording() }

    override func mouseDown(with event: NSEvent) { _ = startRecording() }

    private func startRecording() -> Bool {
        guard window?.makeFirstResponder(self) ?? false else { return false }
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording { return handle(event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
            _ = startRecording()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {  // cancel
            window?.makeFirstResponder(nil)
            return
        }
        let candidate = KeyCombo(keyCode: event.keyCode, flags: flags)
        if let problem = candidate.validationProblem {
            onReject?(problem)
        } else {
            onRecord?(candidate)
            window?.makeFirstResponder(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "Press shortcut…" : combo.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
