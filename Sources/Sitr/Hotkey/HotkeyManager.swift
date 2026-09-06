import AppKit
import Carbon
import os

/// A global hot key: virtual key code plus Carbon modifier bits (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌃⌥Space. PRD FR5: ⌥Space alone collides with Siri and ChatGPT, and Option-only hot keys regressed in 15.0.
    static let `default` = KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// From a recorder's `keyDown` event: the four Carbon modifiers present in `flags`. fn, caps lock and the numeric-pad
    /// flag are dropped; Carbon hot keys do not distinguish them.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        carbonModifiers = Self.glyphs.reduce(0) { flags.contains($1.flag) ? $0 | UInt32($1.bit) : $0 }
    }

    private static let glyphs: [(bit: Int, glyph: String, flag: NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", .control), (optionKey, "⌥", .option), (shiftKey, "⇧", .shift), (cmdKey, "⌘", .command),
    ]

    /// Keys the keyboard layout does not name (or names with a control character).
    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟", UInt32(kVK_ANSI_KeypadEnter): "⌤", UInt32(kVK_Help): "Help",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12", UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]
    private static let keypadKeys: Set<UInt32> = [
        UInt32(kVK_ANSI_Keypad0), UInt32(kVK_ANSI_Keypad1), UInt32(kVK_ANSI_Keypad2), UInt32(kVK_ANSI_Keypad3),
        UInt32(kVK_ANSI_Keypad4), UInt32(kVK_ANSI_Keypad5), UInt32(kVK_ANSI_Keypad6), UInt32(kVK_ANSI_Keypad7),
        UInt32(kVK_ANSI_Keypad8), UInt32(kVK_ANSI_Keypad9), UInt32(kVK_ANSI_KeypadDecimal), UInt32(kVK_ANSI_KeypadMultiply),
        UInt32(kVK_ANSI_KeypadPlus), UInt32(kVK_ANSI_KeypadClear), UInt32(kVK_ANSI_KeypadDivide), UInt32(kVK_ANSI_KeypadMinus),
        UInt32(kVK_ANSI_KeypadEquals),
    ]

    /// Modifier glyphs in the standard menu order ⌃⌥⇧⌘, then the key name. Main actor: the key name comes from the
    /// current keyboard layout through Text Input Sources, which is a main-thread API.
    @MainActor var displayString: String {
        Self.glyphs.filter { carbonModifiers & UInt32($0.bit) != 0 }.map(\.glyph).joined() + Self.keyName(keyCode)
    }

    /// What the current layout types for `keyCode` without modifiers (`UCKeyTranslate`, uppercased), a glyph for the
    /// special keys, "Keypad N" for the numeric pad, "Key N" when the layout has nothing for it.
    @MainActor static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            bytes.baseAddress!.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
            }
        }
        let name = String(utf16CodeUnits: chars, count: length).uppercased()
        guard status == noErr, let scalar = name.unicodeScalars.first, scalar.value >= 0x20 else { return "Key \(keyCode)" }
        return keypadKeys.contains(keyCode) ? "Keypad \(name)" : name
    }

    /// True while every modifier of the combo is down; `flags` comes from `NSEvent.modifierFlags` (no permission
    /// needed). Extra modifiers do not count as a lost release: Carbon keeps the hot key held through them.
    func modifiersHeld(in flags: NSEvent.ModifierFlags) -> Bool {
        Self.glyphs.allSatisfy { carbonModifiers & UInt32($0.bit) == 0 || flags.contains($0.flag) }
    }

    // MARK: Validation and conflicts (M4-T03)

    private static let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), option = UInt32(optionKey), control = UInt32(controlKey)

    /// System shortcuts that a global hot key would steal from every app. Key codes are ANSI positions.
    // ponytail: a short fixed list; the OS has no API for "is this combo reserved". Upgrade = read the symbolic hot keys plist.
    private static let reserved: [(modifiers: UInt32, keyCode: Int, use: String)] = [
        (cmd, kVK_ANSI_Q, "Quit"), (cmd, kVK_ANSI_W, "Close Window"), (cmd, kVK_ANSI_H, "Hide"), (cmd, kVK_ANSI_M, "Minimize"),
        (cmd, kVK_ANSI_Comma, "Settings"), (cmd, kVK_Tab, "the app switcher"), (cmd | shift, kVK_ANSI_Q, "Log Out"),
        (cmd | option, kVK_Escape, "Force Quit"), (cmd | control, kVK_ANSI_Q, "Lock Screen"),
        (cmd | shift, kVK_ANSI_3, "Screenshot"), (cmd | shift, kVK_ANSI_4, "Screenshot"), (cmd | shift, kVK_ANSI_5, "Screenshot"),
    ]

    /// Combos other software listens for (PRD FR5). Shown as a static list and as a warning when one is chosen.
    static let knownConflicts: [(combo: KeyCombo, owner: String)] = [
        (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: option), "Siri (hold) and the ChatGPT app"),
        (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: cmd), "Spotlight"),
        (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: control), "Input source switching"),
    ]

    /// Why this combo cannot be the Reveal hot key, or nil when it can: at least one modifier, not Option alone, not Shift
    /// alone (both swallow typing), and none of the `reserved` system shortcuts.
    @MainActor var validationProblem: String? {
        let mods = carbonModifiers & (Self.cmd | Self.shift | Self.option | Self.control)
        if mods == 0 { return "Add at least one modifier key (⌃, ⌥, ⇧ or ⌘)." }
        if mods == Self.option { return "Option alone types special characters and is unreliable since macOS 15; add ⌃ or ⌘." }
        if mods == Self.shift { return "Shift alone would swallow capital letters; add ⌃, ⌥ or ⌘." }
        if let hit = Self.reserved.first(where: { $0.modifiers == mods && UInt32($0.keyCode) == keyCode }) {
            return "\(displayString) is \(hit.use), a system shortcut."
        }
        return nil
    }

    /// A valid combo that is still a poor choice: a known conflict, or Option without ⌃ / ⌘ (FR5's macOS 15.0 regression).
    @MainActor var conflictNote: String? {
        if let hit = Self.knownConflicts.first(where: { $0.combo == self }) { return "\(displayString) is also used by \(hit.owner)." }
        if carbonModifiers & Self.option != 0, carbonModifiers & (Self.control | Self.cmd) == 0 {
            return "Shortcuts with Option but neither ⌃ nor ⌘ can collide with typing special characters."
        }
        return nil
    }
}

/// Carbon global hot key (M2-T13, PRD FR5): `RegisterEventHotKey` needs neither Accessibility nor Input Monitoring.
/// Press and release callbacks run on the main actor. `AppModel` owns one for the process lifetime.
final class HotkeyManager {
    private(set) var combo: KeyCombo
    /// Result of the last `RegisterEventHotKey`; `noErr` means the combo is ours. Settings › Shortcuts shows anything else.
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
