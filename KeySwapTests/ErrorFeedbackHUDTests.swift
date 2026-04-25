import Testing
@testable import KeySwap

// Tests cover the four behavioral contracts of ErrorFeedbackHUD.dismiss(reason:):
//
//   1. Timer expiry does NOT fire onDismiss (passive — user may be away).
//   2. Body click fires onDismiss AND onClick.
//   3. X button fires onDismiss but NOT onClick.
//   4. Superseding a visible toast fires the previous onDismiss before replacing it.
//
// `dismissDelay` is set to 30s for synchronous tests so the auto-timer never
// interferes, and to 0.05s for the async timer test so we don't wait 2.5s.

@Suite("ErrorFeedbackHUD — onDismiss contract")
@MainActor
struct ErrorFeedbackHUDTests {

    // MARK: - Contract 1: Timer does NOT fire onDismiss

    @Test("Timer expiry does not fire onDismiss")
    func timerExpiry_doesNotFireOnDismiss() async throws {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 0.05

        var dismissed = false
        hud.showClickable(message: "test", onClick: {}, onDismiss: { dismissed = true })

        // Wait past the timer, then verify onDismiss was never called.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        #expect(!dismissed, "Timer expiry must not call onDismiss")
    }

    // MARK: - Contract 2: Body click fires both callbacks

    @Test("Body click fires onDismiss and onClick")
    func bodyClick_firesBothCallbacks() {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 30

        var clicked = false
        var dismissed = false
        hud.showClickable(message: "test", onClick: { clicked = true }, onDismiss: { dismissed = true })

        hud.contentClicked()

        #expect(clicked, "Body click must fire onClick")
        #expect(dismissed, "Body click must fire onDismiss")
    }

    // MARK: - Contract 3: X button fires onDismiss but NOT onClick

    @Test("X button fires onDismiss but not onClick")
    func xButton_firesOnDismissOnly() {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 30

        var clicked = false
        var dismissed = false
        hud.showClickable(message: "test", onClick: { clicked = true }, onDismiss: { dismissed = true })

        hud.closeButtonClicked()

        #expect(!clicked, "X button must not fire onClick")
        #expect(dismissed, "X button must fire onDismiss")
    }

    // MARK: - Contract 4: Supersede fires previous onDismiss

    @Test("Superseding a toast fires the previous onDismiss")
    func supersede_firesPreviousOnDismiss() {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 30

        var firstDismissed = false
        hud.showClickable(message: "first", onClick: {}, onDismiss: { firstDismissed = true })

        hud.showClickable(message: "second", onClick: {}, onDismiss: nil)

        #expect(firstDismissed, "Supersede must fire previous onDismiss before replacing it")
        hud.dismiss()
    }

    // MARK: - Bonus: explicit dismiss

    @Test("Explicit dismiss fires onDismiss")
    func explicitDismiss_firesOnDismiss() {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 30

        var dismissed = false
        hud.showClickable(message: "test", onClick: {}, onDismiss: { dismissed = true })

        hud.dismiss()

        #expect(dismissed, "Explicit dismiss must fire onDismiss")
    }

    // MARK: - Smoke: plain toast

    @Test("Plain error toast dismisses cleanly without callbacks")
    func plainToast_dismissesCleanly() {
        let hud = ErrorFeedbackHUD()
        hud.dismissDelay = 30
        hud.show(message: "Clipboard write failed")
        hud.dismiss() // must not crash or call any callback
    }
}
