import Cocoa
import ApplicationServices

// MARK: - AccessibilityInteractor
//
// Reads selected text from the focused UI element via kAXSelectedTextAttribute.
// Writes translated text back via kAXValueAttribute.
// Also owns execution validation (writable check, 2000-char cap) — merged per Design Change 1.
//
// If AXUIElementSetAttributeValue returns kAXErrorNotImplemented or kAXErrorCannotComplete
// (e.g. Electron apps, sandboxed Mac App Store apps), fall back to ClipboardManager + Cmd+V.

final class AccessibilityInteractor {

    // MARK: - Reading selected text

    /// Returns the currently selected text from the focused AX element, or nil if unavailable.
    /// Falls back to Cmd+Shift+Left (line selection) if no text is selected.
    func readSelectedText() -> (text: String, element: AXUIElement, fallbackMacroUsed: Bool)? {
        guard let element = focusedElement() else { return nil }

        // First attempt: read existing selection
        if let text = selectedText(from: element), !text.isEmpty {
            return (text, element, false)
        }

        // Fallback: select the whole line via Cmd+Shift+Left, then retry
        selectCurrentLine()
        guard let text = selectedText(from: element), !text.isEmpty else {
            return nil
        }
        return (text, element, true)
    }

    // MARK: - Validation (ExecutionProfile merged here per Design Change 1)

    enum ValidationResult {
        case ok
        case readOnly
        case overLimit
        case noFocusedElement
    }

    func validate(element: AXUIElement, textLength: Int) -> ValidationResult {
        guard textLength <= 2000 else { return .overLimit }

        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard err == .success, settable.boolValue else { return .readOnly }

        return .ok
    }

    // MARK: - Writing translated text

    enum WriteResult {
        case success
        case needsClipboardFallback
    }

    /// Attempts to write `text` directly to the AX element's value attribute.
    /// Returns `.needsClipboardFallback` if the write is rejected by the target app.
    func write(_ text: String, to element: AXUIElement) -> WriteResult {
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        switch err {
        case .success:
            return .success
        case .apiDisabled, .notImplemented, .cannotComplete, .failure:
            return .needsClipboardFallback
        default:
            return .needsClipboardFallback
        }
    }

    // MARK: - Polling for paste completion

    /// Polls `kAXValueAttribute` of `element` every 10ms until the value changes
    /// from `previousValue`, indicating the Cmd+V paste has landed.
    /// Times out after 500ms and returns false.
    func pollForValueChange(
        element: AXUIElement,
        previousValue: String,
        timeoutMS: Int = 500
    ) async -> Bool {
        let interval: UInt64 = 10_000_000  // 10ms in nanoseconds
        let maxAttempts = timeoutMS / 10

        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: interval)
            if let current = currentValue(of: element), current != previousValue {
                return true
            }
        }
        return false
    }

    // MARK: - Private helpers

    private func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var element: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &element)
        guard err == .success, let el = element else { return nil }
        return (el as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        // SECURITY: selectedText contains user content from the focused app.
        // It may contain sensitive data if IsSecureEventInputEnabled() has gaps.
        // This variable MUST NOT be logged, persisted, or stored beyond this scope.
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }

    private func currentValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
    }

    /// Sends Cmd+Shift+Left to select the current line.
    private func selectCurrentLine() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let flags: CGEventFlags = [.maskCommand, .maskShift]

        // Key down
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: true) // Left arrow = 0x7B
        down?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)

        // Key up
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgAnnotatedSessionEventTap)

        // Small delay to let the selection land before we read it
        Thread.sleep(forTimeInterval: 0.05)
    }
}
