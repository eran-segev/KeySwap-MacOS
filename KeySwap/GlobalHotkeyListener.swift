import Cocoa
import CoreGraphics

// MARK: - GlobalHotkeyListener
//
// Installs a system-wide CGEventTap for F9 (keyCode 100) and Shift+F9.
//
// SEC-1 SECURITY GATE: This callback receives ALL keyboard events system-wide.
// Non-F9 events MUST be returned immediately with zero processing, zero logging.
//
// Re-entrancy guard: `isSwapping` boolean prevents double-swaps on rapid F9 taps.
// The swap pipeline owns a 500ms SLA timeout (Design Change 3).

final class GlobalHotkeyListener {

    private static let f9KeyCode: Int64 = 100

    weak var appState: AppState?

    /// Called when F9 or Shift+F9 is pressed and all guards pass.
    var onTrigger: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Re-entrancy guard — set true at swap entry, cleared by defer in the pipeline.
    private(set) var isSwapping: Bool = false

    // MARK: - Tap lifecycle

    func start() {
        guard eventTap == nil else { return }
        createTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func createTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // The tap callback must be a C function; bridge via UnsafeMutableRawPointer refcon.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalHotkeyCallback,
            userInfo: selfPtr
        )

        guard let tap else {
            // Tap creation failed → DEGRADED
            Task { @MainActor in appState?.markDegraded() }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Start health-check monitor (ACTIVE / DEGRADED detection)
        startTapHealthMonitor()
    }

    // MARK: - Health monitor (DEGRADED detection)

    private func startTapHealthMonitor() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // check every 5s
                await checkTapHealth()
            }
        }
    }

    @MainActor
    private func checkTapHealth() {
        guard let tap = eventTap else { return }
        if CGEvent.tapIsEnabled(tap: tap) {
            appState?.markActive()
        } else {
            appState?.markDegraded()
            startDegradedRecovery()
        }
    }

    // MARK: - DEGRADED recovery (30-second retry loop)

    private func startDegradedRecovery() {
        Task {
            var attempts = 0
            while attempts < 30 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                attempts += 1
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    if CGEvent.tapIsEnabled(tap: tap) {
                        await MainActor.run { appState?.markActive() }
                        return
                    }
                } else {
                    // Tap was destroyed — recreate
                    await MainActor.run { createTap() }
                    return
                }
            }
            // Recovery failed after 30 seconds — leave in DEGRADED
        }
    }

    // MARK: - Event handling

    // Called from the C callback. Runs on the main thread (session tap).
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        // SECURITY GATE: return immediately for non-keyDown events
        guard type == .keyDown else { return event }

        // SECURITY GATE: check keyCode FIRST — no logging/processing of non-F9 events
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.f9KeyCode else {
            return event // pass through immediately, zero side effects
        }

        // Only F9 / Shift+F9 reaches here.
        // Consume the event (return nil) to prevent it from reaching other apps.
        handleF9()
        return nil
    }

    private func handleF9() {
        // Re-entrancy guard
        guard !isSwapping else {
            NSSound.beep()
            return
        }

        // Secure input check (password fields, etc.)
        if IsSecureEventInputEnabled() {
            NSSound.beep()
            return
        }

        // AppState guard
        guard let appState, case .active = appState.current else {
            NSSound.beep()
            return
        }

        isSwapping = true
        onTrigger?()
    }

    /// Called by the swap pipeline when the operation completes (success or failure).
    func swapCompleted() {
        isSwapping = false
    }
}

// MARK: - C-compatible callback

private func globalHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let listener = Unmanaged<GlobalHotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
    if let result = listener.handleEvent(proxy: proxy, type: type, event: event) {
        return Unmanaged.passRetained(result)
    }
    return nil // consumed
}
