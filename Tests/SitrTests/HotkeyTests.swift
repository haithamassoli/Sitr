import AppKit
import Foundation
import Testing

@testable import Sitr

// Carbon modifier bits, spelled out so the test does not depend on the Carbon import.
private let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

// Main actor: `displayString` asks the current keyboard layout for key names (Text Input Sources, main thread).
@MainActor @Suite struct HotkeyTests {
    @Test func defaultIsControlOptionSpace() {
        #expect(KeyCombo.default == KeyCombo(keyCode: 49, carbonModifiers: control | option))
        #expect(KeyCombo.default.displayString == "⌃⌥Space")
    }

    @Test func glyphOrderIsControlOptionShiftCommand() {
        #expect(KeyCombo(keyCode: 49, carbonModifiers: cmd | shift | option | control).displayString == "⌃⌥⇧⌘Space")
        #expect(KeyCombo(keyCode: 36, carbonModifiers: cmd).displayString == "⌘↩")
        // Key 0 (kVK_ANSI_A) is named by the layout since M4-T03: "A" on US, "Q" on AZERTY, never "Key 0".
        let named = KeyCombo(keyCode: 0, carbonModifiers: shift | control).displayString
        #expect(named.hasPrefix("⌃⇧") && named.count == 3 && !named.hasSuffix("Key 0"))
    }

    @Test func modifiersHeldIsASupersetCheck() {
        let combo = KeyCombo.default
        #expect(combo.modifiersHeld(in: [.control, .option]))
        #expect(combo.modifiersHeld(in: [.control, .option, .shift]))  // an extra modifier is not a lost release
        #expect(!combo.modifiersHeld(in: [.control]))
        #expect(!combo.modifiersHeld(in: [.option, .command]))
        #expect(!combo.modifiersHeld(in: []))
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(KeyCombo.default)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == .default)
    }
}

/// M4-T03: recorder input mapping, validation, conflict notes, layout-aware key names.
@MainActor @Suite struct HotkeyValidationTests {
    @Test func layoutNamesLettersFunctionAndKeypadKeys() {
        let letter = KeyCombo.keyName(0)  // kVK_ANSI_A: whatever the current layout types there, uppercased
        #expect(letter.count == 1 && letter == letter.uppercased() && letter != "Key 0")
        #expect(KeyCombo.keyName(122) == "F1")
        #expect(KeyCombo.keyName(49) == "Space")
        #expect(KeyCombo.keyName(126) == "↑")
        #expect(KeyCombo.keyName(83).hasPrefix("Keypad "))  // kVK_ANSI_Keypad1
        #expect(KeyCombo(keyCode: 122, carbonModifiers: cmd | option).displayString == "⌥⌘F1")
    }

    @Test func eventFlagsMapToCarbonModifiers() {
        #expect(KeyCombo(keyCode: 49, flags: [.control, .option]) == .default)
        #expect(KeyCombo(keyCode: 49, flags: [.control, .option, .function, .numericPad, .capsLock]) == .default)  // extras dropped
        #expect(KeyCombo(keyCode: 12, flags: [.command, .shift]).carbonModifiers == cmd | shift)
        #expect(KeyCombo(keyCode: 12, flags: []).carbonModifiers == 0)
    }

    @Test func validationRejectsUnusableCombos() {
        #expect(KeyCombo.default.validationProblem == nil)
        #expect(KeyCombo(keyCode: 122, carbonModifiers: 0).validationProblem?.contains("modifier") == true)  // F1 alone
        #expect(KeyCombo(keyCode: 49, carbonModifiers: option).validationProblem?.contains("Option alone") == true)
        #expect(KeyCombo(keyCode: 0, carbonModifiers: shift).validationProblem?.contains("Shift alone") == true)
        #expect(KeyCombo(keyCode: 12, carbonModifiers: cmd).validationProblem?.contains("Quit") == true)  // ⌘Q
        #expect(KeyCombo(keyCode: 13, carbonModifiers: cmd).validationProblem?.contains("Close Window") == true)  // ⌘W
        #expect(KeyCombo(keyCode: 12, carbonModifiers: cmd | shift).validationProblem?.contains("Log Out") == true)
        #expect(KeyCombo(keyCode: 48, carbonModifiers: cmd).validationProblem?.contains("app switcher") == true)  // ⌘⇥
        #expect(KeyCombo(keyCode: 12, carbonModifiers: cmd | control | option).validationProblem == nil)  // ⌃⌥⌘Q is free
        #expect(KeyCombo(keyCode: 49, carbonModifiers: cmd).validationProblem == nil)  // ⌘Space: a conflict, not invalid
        #expect(KeyCombo(keyCode: 0, carbonModifiers: option | shift).validationProblem == nil)  // ⌥⇧A: allowed, warned
    }

    @Test func conflictNotesNameTheOtherOwner() {
        #expect(KeyCombo(keyCode: 49, carbonModifiers: option).conflictNote?.contains("Siri") == true)
        #expect(KeyCombo(keyCode: 49, carbonModifiers: cmd).conflictNote?.contains("Spotlight") == true)
        #expect(KeyCombo(keyCode: 49, carbonModifiers: control).conflictNote?.contains("Input source") == true)
        #expect(KeyCombo(keyCode: 0, carbonModifiers: option | shift).conflictNote?.contains("Option") == true)
        #expect(KeyCombo.default.conflictNote == nil)
        #expect(KeyCombo(keyCode: 0, carbonModifiers: cmd | option).conflictNote == nil)
        #expect(KeyCombo.knownConflicts.count == 3)
    }
}
