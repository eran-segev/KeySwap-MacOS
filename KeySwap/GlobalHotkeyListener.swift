import Cocoa
import CoreGraphics
import Carbon

// MARK: - GlobalHotkeyListener
//
// Installs a system-wide CGEventTap for F9 (keyCode 100) and Shift+F9.
//
// SEC-1 SECURITY GATE: This callback receives ALL keyboard events system-wide.
// Non-F9 events MUST be returned immediately with zero processing, zero logging.
//
// Re-entrancy guard: `isSwapping` boolean prevents double-swaps on rapid F9 taps.
// The swap pipeline owns a 500ms SLA timeout (Design Change 3).
//
// Threading: The event tap is added to the main run loop, so the callback
// runs on the main thread. All methods are @MainActor. The C callback bridge
// uses MainActor.assumeIsolated to enter the actor synchronously.

@MainActor
final class GlobalHotkeyListener {

    private static let f9KeyCode: Int64 = Int64(kVK_F9) // 0x65 = 101

    weak var appState: AppState?

    /// Called when F9 or Shift+F9 is pressed and all guards pass.
    var onTrigger: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Re-entrancy guard — set true at swap entry, cleared by the pipeline.
    private(set) var isSwapping: Bool = false

    // Passive keystroke buffer for recovering Shift+letter characters
    // swallowed by macOS on the Hebrew layout. See KeystrokeBuffer.swift.
    let keystrokeBuffer = KeystrokeBuffer()

    // MARK: - Tap lifecycle

    func start() {
        guard eventTap == nil else {
            #if DEBUG
            print("[HotkeyListener] start() called but tap already exists — no-op")
            #endif
            return
        }
        #if DEBUG
        print("[HotkeyListener] start() — creating event tap...")
        #endif
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
            // Tap creation failed — Input Monitoring is not granted.
            // Only mark DEGRADED if we were previously running (tap died).
            // Otherwise this is a permissions issue handled by AppState.
            #if DEBUG
            print("[HotkeyListener] ✗ CGEventTap creation FAILED — Input Monitoring not granted?")
            #endif
            let wasRunning = appState?.current == .active || appState?.current == .degraded
            appState?.updateInputMonitoring(false)
            if wasRunning {
                appState?.markDegraded()
            }
            return
        }

        // Tap created successfully — Input Monitoring is granted.
        #if DEBUG
        print("[HotkeyListener] ✓ CGEventTap created successfully, tap enabled on main run loop")
        #endif
        appState?.updateInputMonitoring(true)
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startTapHealthMonitor()
    }

    /// Attempts to create and immediately destroy a CGEventTap.
    /// Returns true if Input Monitoring is granted. Requires Accessibility first.
    static func probeInputMonitoring() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        return true
    }

    // MARK: - Health monitor (DEGRADED detection)

    private func startTapHealthMonitor() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // every 5s
                guard let tap = eventTap else { return }
                if CGEvent.tapIsEnabled(tap: tap) {
                    appState?.markActive()
                } else {
                    appState?.markDegraded()
                    startDegradedRecovery()
                }
            }
        }
    }

    // MARK: - DEGRADED recovery (30-second retry loop)

    private func startDegradedRecovery() {
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    if CGEvent.tapIsEnabled(tap: tap) {
                        appState?.markActive()
                        return
                    }
                } else {
                    createTap()
                    return
                }
            }
            // Recovery failed after 30 seconds — leave in DEGRADED
        }
    }

    // MARK: - Event handling

    // Called from the C callback via MainActor.assumeIsolated.
    // The tap is registered on the main run loop, so the callback is always on the main thread.
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
        // SECURITY GATE: return immediately for non-keyDown events
        guard type == .keyDown else { return event }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Record into keystroke buffer (SEC-1 exception: keycode + shift flag only).
        // F9 (0x65) is not in characterKeyCodes so record() is a no-op for it.
        // See KeystrokeBuffer.swift for security invariants.
        keystrokeBuffer.record(keyCode: keyCode, flags: event.flags)

        // SECURITY GATE: only F9 proceeds past this point
        guard keyCode == Self.f9KeyCode else {
            return event // pass through immediately
        }

        // Only F9 / Shift+F9 reaches here. Consume the event.
        #if DEBUG
        let flags = event.flags
        let hasShift = flags.contains(.maskShift)
        print("[HotkeyListener] F9 detected (shift=\(hasShift)) — invoking handleF9()")
        #endif
        handleF9()
        return nil
    }

    private func handleF9() {
        // Re-entrancy guard
        guard !isSwapping else {
            #if DEBUG
            print("[HotkeyListener] handleF9 BLOCKED — already swapping (re-entrancy guard)")
            #endif
            NSSound.beep()
            return
        }

        // Secure input check (password fields, etc.)
        if IsSecureEventInputEnabled() {
            #if DEBUG
            print("[HotkeyListener] handleF9 BLOCKED — secure input enabled (password field?)")
            #endif
            NSSound.beep()
            return
        }

        // AppState guard
        guard let appState, case .active = appState.current else {
            #if DEBUG
            print("[HotkeyListener] handleF9 BLOCKED — appState is \(appState?.current as Any), expected .active")
            #endif
            NSSound.beep()
            return
        }

        #if DEBUG
        print("[HotkeyListener] handleF9 — all guards passed, firing onTrigger (onTrigger set: \(onTrigger != nil))")
        #endif
        isSwapping = true
        onTrigger?()
    }

    /// Called by the swap pipeline when the operation completes (success or failure).
    func swapCompleted() {
        isSwapping = false
    }
}

// MARK: - C-compatible callback
//
// This function has no actor annotation (required by C callback type).
// MainActor.assumeIsolated is safe because the tap is installed on the main run loop,
// guaranteeing the callback is always invoked on the main thread.

private func globalHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Earliest possible log — runs in the C callback, before any Swift actor dispatch.
    #if DEBUG
    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 100 { // F9
            print("[C-CALLBACK] >>> F9 keyDown received in raw event tap callback")
        }
        // SEC-1: Do NOT log non-F9 keycodes. Buffer recording handles observation.
    } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("[C-CALLBACK] Event tap was DISABLED by system (type=\(type.rawValue))")
    }
    #endif

    guard let refcon else { return Unmanaged.passRetained(event) }

    return MainActor.assumeIsolated {
        let listener = Unmanaged<GlobalHotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
        if let result = listener.handleEvent(proxy: proxy, type: type, event: event) {
            return Unmanaged.passRetained(result)
        }
        return nil // consumed
    }
}
