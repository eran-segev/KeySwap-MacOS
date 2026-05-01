import Testing
import CoreGraphics
@testable import KeySwap

@Suite("SwapMode from CGEventFlags")
@MainActor
struct SwapModeTests {

    @Test("No modifiers returns .forward")
    func noModifiers() {
        #expect(GlobalHotkeyListener.swapMode(from: []) == .forward)
    }

    @Test("Shift returns .reverse")
    func shift() {
        #expect(GlobalHotkeyListener.swapMode(from: .maskShift) == .reverse)
    }

    @Test("Option/Alt returns .raw")
    func option() {
        #expect(GlobalHotkeyListener.swapMode(from: .maskAlternate) == .raw)
    }

    @Test("Control returns .revert")
    func control() {
        #expect(GlobalHotkeyListener.swapMode(from: .maskControl) == .revert)
    }

    @Test("Control+Shift returns .revert (ctrl beats shift)")
    func controlShift() {
        #expect(GlobalHotkeyListener.swapMode(from: [.maskControl, .maskShift]) == .revert)
    }

    @Test("Command returns .forward (cmd not mapped)")
    func command() {
        #expect(GlobalHotkeyListener.swapMode(from: [.maskCommand]) == .forward)
    }

    @Test("Option+Shift returns .raw (option beats shift)")
    func optionShift() {
        #expect(GlobalHotkeyListener.swapMode(from: [.maskAlternate, .maskShift]) == .raw)
    }

    @Test("Control+Option returns .revert (ctrl beats option)")
    func controlOption() {
        #expect(GlobalHotkeyListener.swapMode(from: [.maskControl, .maskAlternate]) == .revert)
    }
}
