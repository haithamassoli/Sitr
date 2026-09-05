import AppKit
import Foundation
import Testing

@testable import Sitr

// Carbon modifier bits, spelled out so the test does not depend on the Carbon import.
private let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096

@Suite struct HotkeyTests {
    @Test func defaultIsControlOptionSpace() {
        #expect(KeyCombo.default == KeyCombo(keyCode: 49, carbonModifiers: control | option))
        #expect(KeyCombo.default.displayString == "⌃⌥Space")
    }

    @Test func glyphOrderIsControlOptionShiftCommand() {
        #expect(KeyCombo(keyCode: 49, carbonModifiers: cmd | shift | option | control).displayString == "⌃⌥⇧⌘Space")
        #expect(KeyCombo(keyCode: 36, carbonModifiers: cmd).displayString == "⌘↩")
        #expect(KeyCombo(keyCode: 0, carbonModifiers: shift | control).displayString == "⌃⇧Key 0")
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
