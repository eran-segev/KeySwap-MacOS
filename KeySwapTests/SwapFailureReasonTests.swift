import Testing
@testable import KeySwap

@Suite("SwapFailureReason")
struct SwapFailureReasonTests {

    @Test("All 6 cases produce non-empty userMessage")
    func allCasesHaveMessages() {
        let cases: [SwapFailureReason] = [
            .noTextSelected, .readOnly, .overLimit,
            .noFocusedElement, .timeout, .clipboardFailed,
        ]
        for reason in cases {
            #expect(!reason.userMessage.isEmpty, "userMessage for \(reason) should not be empty")
        }
    }

    @Test("noTextSelected message")
    func noTextSelected() {
        #expect(SwapFailureReason.noTextSelected.userMessage == "No text selected")
    }

    @Test("readOnly message")
    func readOnly() {
        #expect(SwapFailureReason.readOnly.userMessage == "Field is read-only")
    }

    @Test("overLimit message")
    func overLimit() {
        #expect(SwapFailureReason.overLimit.userMessage == "Selection too large")
    }

    @Test("noFocusedElement message")
    func noFocusedElement() {
        #expect(SwapFailureReason.noFocusedElement.userMessage == "No focused field")
    }

    @Test("timeout message")
    func timeout() {
        #expect(SwapFailureReason.timeout.userMessage == "Swap timed out")
    }

    @Test("clipboardFailed message")
    func clipboardFailed() {
        #expect(SwapFailureReason.clipboardFailed.userMessage == "Clipboard write failed")
    }
}
