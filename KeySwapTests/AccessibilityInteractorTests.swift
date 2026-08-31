import Testing
@testable import KeySwap

@Suite("AccessibilityInteractor.isSelectionSettled")
struct AccessibilityInteractorTests {

    @Test("Empty text is never settled")
    func emptyText() {
        #expect(AccessibilityInteractor.isSelectionSettled(text: "", rangeLength: 0) == false)
        #expect(AccessibilityInteractor.isSelectionSettled(text: nil, rangeLength: 5) == false)
    }

    @Test("Text with no range info is not settled (attribute race)")
    func missingRange() {
        #expect(AccessibilityInteractor.isSelectionSettled(text: "hello", rangeLength: nil) == false)
    }

    @Test("Text present but range still collapsed is not settled — the reported bug")
    func collapsedRange() {
        #expect(AccessibilityInteractor.isSelectionSettled(text: "hello", rangeLength: 0) == false)
    }

    @Test("Text present with a stale range pointing elsewhere is not settled")
    func mismatchedRange() {
        #expect(AccessibilityInteractor.isSelectionSettled(text: "hello", rangeLength: 3) == false)
    }

    @Test("Text and matching range length is settled")
    func matchedRange() {
        #expect(AccessibilityInteractor.isSelectionSettled(text: "hello", rangeLength: 5) == true)
    }

    @Test("Matching range length counts UTF-16 units, not Character count")
    func utf16Length() {
        // "🇮🇱" (Israel flag) is 1 Character but 4 UTF-16 code units.
        #expect(AccessibilityInteractor.isSelectionSettled(text: "🇮🇱", rangeLength: 4) == true)
        #expect(AccessibilityInteractor.isSelectionSettled(text: "🇮🇱", rangeLength: 1) == false)
    }
}

@Suite("AccessibilityInteractor.isSelectedTextWriteConfirmed")
struct SelectedTextWriteConfirmedTests {

    @Test("nil value (attribute unsupported, e.g. Word notes) is trusted")
    func nilValueTrusted() {
        #expect(AccessibilityInteractor.isSelectedTextWriteConfirmed(currentValue: nil, written: "hello") == true)
    }

    @Test("Value containing the written text is confirmed")
    func containingConfirmed() {
        #expect(AccessibilityInteractor.isSelectedTextWriteConfirmed(currentValue: "say hello there", written: "hello") == true)
    }

    @Test("Value not (yet) containing the written text is not confirmed — the Chrome async-commit race")
    func notContainingUnconfirmed() {
        #expect(AccessibilityInteractor.isSelectedTextWriteConfirmed(currentValue: "say שלום there", written: "hello") == false)
    }
}

@Suite("AccessibilityInteractor.isSpliceWriteConfirmed")
struct SpliceWriteConfirmedTests {

    @Test("Exact match is confirmed")
    func exactMatchConfirmed() {
        #expect(AccessibilityInteractor.isSpliceWriteConfirmed(currentValue: "hello world", expected: "hello world") == true)
    }

    @Test("Mismatch is not confirmed — the async-commit race before it settles")
    func mismatchUnconfirmed() {
        #expect(AccessibilityInteractor.isSpliceWriteConfirmed(currentValue: "שלום world", expected: "hello world") == false)
    }

    @Test("nil value is not confirmed — unlike the selected-text check, splice has no unsupported-attribute trust case")
    func nilValueUnconfirmed() {
        #expect(AccessibilityInteractor.isSpliceWriteConfirmed(currentValue: nil, expected: "hello world") == false)
    }
}

@Suite("AccessibilityInteractor.isSelectionConsumed")
struct SelectionConsumedTests {

    private let original = NSRange(location: 0, length: 4)

    @Test("Selection unchanged means the write was ignored")
    func unchangedNotConsumed() {
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: original,
            currentText: "טםשה",
            currentRange: original
        ) == false)
    }

    @Test("Collapsed caret after the replaced range means the write landed — the Slack bug")
    func collapsedRangeConsumed() {
        // Slack's AXComboBox applied the kAXSelectedTextAttribute write and moved
        // the caret, but kAXValueAttribute never reflected it. Selection state is
        // the only honest signal.
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: original,
            currentText: "",
            currentRange: NSRange(location: 4, length: 0)
        ) == true)
    }

    @Test("Same range but different content means the write landed")
    func contentReplacedConsumed() {
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: original,
            currentText: "Yoav",
            currentRange: original
        ) == true)
    }

    @Test("Unreadable current range is unknown, not consumed — keeps the Cmd+V fallback")
    func nilCurrentRangeNotConsumed() {
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: original,
            currentText: nil,
            currentRange: nil
        ) == false)
    }

    @Test("Unreadable current text with an unchanged range is unknown, not consumed")
    func nilCurrentTextNotConsumed() {
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: original,
            currentText: nil,
            currentRange: original
        ) == false)
    }

    @Test("No pre-write selection means there was nothing to consume")
    func noOriginalSelection() {
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: nil,
            originalRange: original,
            currentText: "Yoav",
            currentRange: NSRange(location: 4, length: 0)
        ) == false)
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: nil,
            currentText: "Yoav",
            currentRange: NSRange(location: 4, length: 0)
        ) == false)
        #expect(AccessibilityInteractor.isSelectionConsumed(
            originalText: "טםשה",
            originalRange: NSRange(location: 0, length: 0),
            currentText: "Yoav",
            currentRange: NSRange(location: 4, length: 0)
        ) == false)
    }
}

@Suite("AccessibilityInteractor.fallbackIsSafe")
struct FallbackIsSafeTests {

    @Test("Re-selecting the original text proves nothing was written — paste away")
    func originalStillThere() {
        #expect(AccessibilityInteractor.fallbackIsSafe(
            originalText: "טםשה",
            reselectedText: "טםשה"
        ) == true)
    }

    @Test("Re-selecting different text means a write landed — suppress the paste (the Slack bug)")
    func writeAlreadyLanded() {
        // Without this, Cmd+V appends a second copy and the user sees "YoavYoav".
        #expect(AccessibilityInteractor.fallbackIsSafe(
            originalText: "טםשה",
            reselectedText: "Yoav"
        ) == false)
    }

    @Test("Shorter replacement text is still detected as a landed write")
    func shorterReplacementDetected() {
        #expect(AccessibilityInteractor.fallbackIsSafe(
            originalText: "טםשה",
            reselectedText: "Yo"
        ) == false)
    }

    @Test("Unreadable read-back keeps the legacy fallback (Word notes/comments)")
    func unreadableKeepsFallback() {
        #expect(AccessibilityInteractor.fallbackIsSafe(originalText: "טםשה", reselectedText: nil) == true)
        #expect(AccessibilityInteractor.fallbackIsSafe(originalText: "טםשה", reselectedText: "") == true)
    }

    @Test("No original text to compare against keeps the legacy fallback")
    func noOriginalKeepsFallback() {
        #expect(AccessibilityInteractor.fallbackIsSafe(originalText: nil, reselectedText: "Yoav") == true)
        #expect(AccessibilityInteractor.fallbackIsSafe(originalText: "", reselectedText: "Yoav") == true)
    }
}

@Suite("AccessibilityInteractor.SelectionOrigin")
struct SelectionOriginTests {

    typealias Origin = AccessibilityInteractor.SelectionOrigin

    @Test("Only the whole-line macro may be replayed before a Cmd+V")
    func onlyWholeLineIsReplayable() {
        // Replaying the whole-line macro over a user selection or a
        // caret-to-line-start selection would select text that was never
        // translated, and the paste would destroy it.
        #expect(Origin.wholeLine.isWholeLine == true)
        #expect(Origin.caretToLineStart.isWholeLine == false)
        #expect(Origin.userSelection.isWholeLine == false)
    }

    @Test("Both macros count as a fallback macro; a user selection does not")
    func fallbackMacroFlag() {
        // Drives the paragraph writing-direction flip — same meaning the old
        // fallbackMacroUsed Bool carried.
        #expect(Origin.userSelection.usedFallbackMacro == false)
        #expect(Origin.caretToLineStart.usedFallbackMacro == true)
        #expect(Origin.wholeLine.usedFallbackMacro == true)
    }
}
