import AppKit
import Carbon.HIToolbox
import os

/// A global hot key: virtual key code plus Carbon modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌃⌥Space. PRD FR5: ⌥Space alone collides with Siri and ChatGPT, and Option-only hot keys regressed in 15.0.
    static let `default` = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))

    private static let glyphs: [(bit: Int, glyph: String, flag: NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", .control), (optionKey, "⌥", .option), (shiftKey, "⇧", .shift), (cmdKey, "⌘", .command),
    ]
    // ponytail: names only the keys a Reveal combo plausibly uses; M4-T03's recorder adds layout-aware names via
    // UCKeyTranslate for letters and digits.
    private static let keyNames: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Modifier glyphs in the standard menu order ⌃⌥⇧⌘, then the key name.
    var displayString: String {
        Self.glyphs.filter { carbonModifiers & UInt32($0.bit) != 0 }.map(\.glyph).joined()
            + Self.keyNames[keyCode, default: "Key \(keyCode)"]
    }

    /// True while every modifier of the combo is down; `flags` comes from `NSEvent.modifierFlags` (no permission
    /// needed). Extra modifiers do not count as a lost release: Carbon keeps the hot key held through them.
    func modifiersHeld(in flags: NSEvent.ModifierFlags) -> Bool {
        Self.glyphs.allSatisfy { carbonModifiers & UInt32($0.bit) == 0 || flags.contains($0.flag) }
    }
}

/// Carbon global hot key (M2-T13, PRD FR5): `RegisterEventHotKey` needs neither Accessibility nor Input Monitoring.
/// Press and release callbacks run on the main actor. `AppModel` owns one for the process lifetime.
final class HotkeyManager {
    private(set) var combo: KeyCombo
    /// Result of the last `RegisterEventHotKey`; `noErr` means the combo is ours. M4-T03 shows conflicts from this.
    private(set) var registrationStatus: OSStatus = noErr
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private let log = Logger(subsystem: "com.goldentik.Sitr", category: "hotkey")
    private static let signature: OSType = 0x5369_7472  // 'Sitr'

    init(combo: KeyCombo) {
        self.combo = combo
        var kinds = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        // The handler stays installed for the life of the process; AppModel owns `self` for as long.
        InstallEventHandler(
            GetApplicationEventTarget(), hotkeyEventHandler, kinds.count, &kinds,
            Unmanaged.passUnretained(self).toOpaque(), nil)
        register()
    }

    func rebind(_ newCombo: KeyCombo) {
        unregister()
        combo = newCombo
        register()
    }

    /// Gives the combo back to the system. Called on quit; the process exiting releases it as well.
    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        log.notice("hotkey unregistered")
    }

    private func register() {
        var ref: EventHotKeyRef?
        registrationStatus = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        log.notice("hotkey register \(self.combo.displayString, privacy: .public) status=\(self.registrationStatus)")
    }

    // ponytail: one hot key per process, so the event's EventHotKeyID is not checked; M4-T03 stays at one.
    fileprivate func handle(kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed: onPress?()
        case kEventHotKeyReleased: onRelease?()
        default: break
        }
    }
}

/// C callback for `InstallEventHandler`. Carbon dispatches it on the main thread, hence `assumeIsolated`.
private nonisolated func hotkeyEventHandler(
    _: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    MainActor.assumeIsolated { manager.handle(kind: kind) }
    return noErr
}
