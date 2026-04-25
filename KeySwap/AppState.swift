import Foundation
import ApplicationServices
import TranslationContext

// MARK: - AppState
//
// Permission tracking state machine.
//
// Both Accessibility and Input Monitoring grants are independent; either can be granted first.
//
// States:
//   PERMISSIONS_REQUIRED  — neither permission granted
//   PARTIAL               — exactly one of the two permissions granted
//   ACTIVE                — both permissions granted, CGEventTap running
//   DEGRADED              — CGEventTap failed or disabled by macOS (recovery in progress)
//
// Transitions:
//   Any → ACTIVE          — both permissions granted and CGEventTap created successfully
//   ACTIVE → DEGRADED     — CGEventTapIsEnabled() returns false or tap callback stops firing
//   DEGRADED → ACTIVE     — 30-second retry loop re-enables tap successfully
//
// Also owns transient post-swap "pendingRevert" state that makes spell-check
// corrections visible and reversible. See PendingRevert below.

// MARK: - PendingRevert
//
// Ephemeral, in-memory snapshot describing the last swap's spell-check corrections.
// Exists for a bounded window (HUD display duration) during which the user can
// press F9 while the corrections HUD is visible to undo the corrections without
// undoing the layout swap. Ctrl+F9 still works as an explicit alternative.
//
// Cleared when:
//   - The window expires (timer fires)
//   - A new swap starts (replaces it)
//   - Any non-F9 keydown is observed by GlobalHotkeyListener (user typed more, revert
//     would clobber their input)
//   - Revert is executed (via F9 while HUD open, or Ctrl+F9)
//
// `element == nil` indicates the swap used the clipboard-only path (Electron etc.).
// Revert still works there via synthesized Backspace + paste (see
// ClipboardManager.replaceLastNCharsWithPaste).

struct PendingRevert {
    let preCorrectionText: String
    let correctedText: String
    let corrections: [Correction]
    let element: AXUIElement?
    /// UTF16 offset of the first character of the corrected text within the target
    /// field, captured at the moment of the AX write. Used to re-select the
    /// corrected text for replacement during revert.
    let insertionStartLocation: Int
}

@MainActor
final class AppState: ObservableObject {

    enum State: Equatable {
        case permissionsRequired
        case partial
        case active
        case degraded
    }

    @Published private(set) var current: State = .permissionsRequired

    /// Timestamps for each state transition (used for conversion metrics).
    private(set) var lastTransitionAt: Date = Date()

    private var hasAccessibility: Bool = false
    private var hasInputMonitoring: Bool = false

    // MARK: - Last swap outcome (for About window status line)

    private(set) var lastSwapOutcome: String?

    func setLastSwapOutcome(_ outcome: String) {
        lastSwapOutcome = outcome
    }

    // MARK: - Pending revert state

    /// The currently-active post-swap correction that can be reverted. Never set
    /// directly — use `setPendingRevert(_:onExpire:)` or `clearPendingRevert()`.
    private(set) var pendingRevert: PendingRevert?

    private var revertExpiryTimer: DispatchWorkItem?

    /// Fires when `clearPendingRevert()` is called while a revert was pending.
    /// Set once by the app at launch — used to keep the corrections HUD in
    /// sync with revert availability (if there is no revert, the "Press F9
    /// to revert" hint must come down immediately).
    /// Does NOT fire on timer-driven expiry — `setPendingRevert`'s `onExpire`
    /// closure handles that path.
    var onExplicitClear: (() -> Void)?

    /// Assign a new pendingRevert and schedule its expiry. The previous revert
    /// (if any) and its timer are cancelled. `onExpire` fires on the main queue
    /// when the timer elapses naturally; it does NOT fire when the revert is
    /// cleared explicitly (e.g. by a non-F9 keystroke or executed revert).
    func setPendingRevert(_ revert: PendingRevert, duration: TimeInterval, onExpire: @escaping () -> Void) {
        revertExpiryTimer?.cancel()
        pendingRevert = revert

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only fire if still the active revert — a new swap may have
            // replaced it before the timer fired.
            guard self.pendingRevert != nil else { return }
            self.pendingRevert = nil
            self.revertExpiryTimer = nil
            onExpire()
        }
        revertExpiryTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
    }

    /// Clear pendingRevert without firing `onExpire`. Used when the user types
    /// a non-F9 character, starts a new swap, or executes a revert. Fires
    /// `onExplicitClear` (if set) ONLY when there was an actual revert to
    /// clear, so idempotent clears don't re-trigger HUD dismissal.
    func clearPendingRevert() {
        revertExpiryTimer?.cancel()
        revertExpiryTimer = nil
        let hadPending = pendingRevert != nil
        pendingRevert = nil
        if hadPending {
            onExplicitClear?()
        }
    }

    // MARK: - Permission tracking

    func updateAccessibility(_ granted: Bool) {
        hasAccessibility = granted
        recomputeState()
    }

    func updateInputMonitoring(_ granted: Bool) {
        hasInputMonitoring = granted
        recomputeState()
    }

    func markDegraded() {
        transition(to: .degraded)
    }

    func markActive() {
        transition(to: .active)
    }

    // MARK: - State computation

    private func recomputeState() {
        switch (hasAccessibility, hasInputMonitoring) {
        case (true, true):
            transition(to: .active)
        case (false, false):
            transition(to: .permissionsRequired)
        default:
            transition(to: .partial)
        }
    }

    private func transition(to next: State) {
        guard current != next else { return }
        current = next
        lastTransitionAt = Date()
    }

    // MARK: - Polling helpers

    /// Polls AXIsProcessTrusted() until accessibility is granted or the task is cancelled.
    func pollAccessibilityUntilGranted() async {
        while !Task.isCancelled {
            let trusted = AXIsProcessTrusted()
            updateAccessibility(trusted)
            if trusted { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
}
