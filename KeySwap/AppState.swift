import Foundation
import ApplicationServices

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
