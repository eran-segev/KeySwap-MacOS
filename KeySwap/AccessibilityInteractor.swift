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
    /// Result of reading selected text. `.ax` means we have an AX element and can write back
    /// via AX. `.clipboardOnly` means AX failed (Electron apps etc.) and the pipeline must
    /// use Cmd+V to paste.
    enum ReadResult {
        case ax(text: String, element: AXUIElement, fallbackMacroUsed: Bool)
        case clipboardOnly(text: String, fallbackMacroUsed: Bool)
    }

    func readSelectedText() -> ReadResult? {
        // Tracks whether any destructive selection macro (Cmd+Shift+Left /
        // whole-line) has fired across the whole read operation — not just
        // within the clipboard path. If we eventually return via
        // .clipboardOnly, we need this flag to stay accurate so the pipeline
        // knows whether to flip paragraph writing direction: running line
        // macros in the AX branch then Cmd+C'ing the result in the clipboard
        // branch must still report fallback=true.
        var axMacrosFired = false

        if let element = focusedElement() {
            #if DEBUG
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? "unknown"
            print("[AXInteractor] readSelectedText: focused element role=\(role)")
            #endif

            // First attempt: read existing selection via AX
            if let text = selectedText(from: element), !text.isEmpty {
                #if DEBUG
                print("[AXInteractor] readSelectedText: got selection directly (\(text.count) chars)")
                #endif
                return .ax(text: text, element: element, fallbackMacroUsed: false)
            }

            // Gate macro decisions on what AX says the element supports.
            // nil range = attribute absent (container like AXSplitGroup; Word's
            //            focused element is typically a split group, not the
            //            text area itself). Running line macros on AX here
            //            would still fire globally and destroy any visual
            //            selection the user made. Skip AX macros and let the
            //            clipboard path handle it — it already tries Cmd+C on
            //            the existing visual selection before running macros.
            // length > 0 = user has a selection that AX can't expose as a
            //              string (Microsoft Word's AXTextArea pattern on
            //              some versions). Cmd+C the existing selection.
            // length == 0 = text-capable element with caret but no selection.
            //               Line macros are appropriate here — the element
            //               will expose the resulting selection.
            let rangeOpt = currentSelectionRange(of: element)

            if let range = rangeOpt, range.length > 0 {
                if let text = copyExistingSelectionToClipboard(), !text.isEmpty {
                    return .ax(text: text, element: element, fallbackMacroUsed: false)
                }
            }

            if rangeOpt != nil {
                #if DEBUG
                print("[AXInteractor] readSelectedText: no selection, trying Cmd+Shift+Left fallback...")
                #endif

                // Fallback macro #1: Cmd+Shift+Left (extend selection from caret to
                // logical line start). Works when caret is mid-line.
                selectCurrentLine()
                axMacrosFired = true
                if let text = selectedText(from: element), !text.isEmpty {
                    #if DEBUG
                    print("[AXInteractor] readSelectedText: Cmd+Shift+Left fallback got \(text.count) chars")
                    #endif
                    return .ax(text: text, element: element, fallbackMacroUsed: true)
                }

                // Fallback macro #2: Cmd+Left then Cmd+Shift+Right (caret to line
                // start, then extend to line end). Always selects the whole line
                // regardless of starting caret position — fixes the "caret at line
                // start" no-op failure of macro #1.
                #if DEBUG
                print("[AXInteractor] readSelectedText: macro #1 empty, trying whole-line macro...")
                #endif
                selectWholeLine()
                if let text = selectedText(from: element), !text.isEmpty {
                    #if DEBUG
                    print("[AXInteractor] readSelectedText: whole-line fallback got \(text.count) chars")
                    #endif
                    return .ax(text: text, element: element, fallbackMacroUsed: true)
                }
            }
        }

        // AX path failed entirely (no focused element, or no text found).
        // Last resort: read selection via Cmd+C → clipboard.
        #if DEBUG
        print("[AXInteractor] readSelectedText: AX failed, trying Cmd+C clipboard path...")
        #endif
        if let result = readSelectionViaClipboard(), !result.text.isEmpty {
            let effectiveFallback = result.fallbackMacroUsed || axMacrosFired
            #if DEBUG
            print("[AXInteractor] readSelectedText: clipboard path got \(result.text.count) chars (fallback=\(effectiveFallback))")
            #endif
            return .clipboardOnly(text: result.text, fallbackMacroUsed: effectiveFallback)
        }

        #if DEBUG
        print("[AXInteractor] readSelectedText: all paths failed, no text available")
        #endif
        return nil
    }

    // MARK: - Clipboard-based selection reading (for Electron apps etc.)

    /// Sends Cmd+C, reads the clipboard, then restores the previous clipboard contents.
    /// If nothing is selected, tries Cmd+Shift+Left first to select the current line.
    /// Returns the text and whether the line-selection fallback was used (so the
    /// caller can decide whether to flip paragraph writing direction post-swap).
    private func readSelectionViaClipboard() -> (text: String, fallbackMacroUsed: Bool)? {
        let pasteboard = NSPasteboard.general
        let stashedItems = stashClipboard()

        // First attempt: Cmd+C on whatever is already selected
        var text = copyViaClipboard(pasteboard: pasteboard)
        var fallbackUsed = false

        if text == nil {
            // Macro #1: Cmd+Shift+Left (cursor to line start). Works when
            // caret is mid-line; no-op when caret is at line start.
            #if DEBUG
            print("[AXInteractor] clipboard path: no selection, sending Cmd+Shift+Left then Cmd+C")
            #endif
            selectCurrentLine()
            fallbackUsed = true
            text = copyViaClipboard(pasteboard: pasteboard)
        }

        if text == nil {
            // Macro #2: Cmd+Left then Cmd+Shift+Right (whole line, start→end).
            // Selects the whole line regardless of caret position.
            #if DEBUG
            print("[AXInteractor] clipboard path: macro #1 empty, sending whole-line macro then Cmd+C")
            #endif
            selectWholeLine()
            text = copyViaClipboard(pasteboard: pasteboard)
        }

        // Restore clipboard
        restoreClipboard(stashedItems)

        guard let t = text else { return nil }
        return (t, fallbackUsed)
    }

    /// Cmd+C the user's existing visual selection (no fallback macros).
    /// Stashes and restores the clipboard so user data isn't clobbered.
    /// Used when AX reports a non-zero selection range but `kAXSelectedTextAttribute`
    /// returns nil/empty (the Microsoft Word pattern) — we need the user's actual
    /// selected text without running macros that would overwrite their selection.
    private func copyExistingSelectionToClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let stashedItems = stashClipboard()
        let text = copyViaClipboard(pasteboard: pasteboard)
        restoreClipboard(stashedItems)
        return text
    }

    /// Sends Cmd+C and waits up to 200ms for the clipboard to change.
    /// Returns the clipboard string if it changed, nil otherwise.
    private func copyViaClipboard(pasteboard: NSPasteboard) -> String? {
        let previousChangeCount = pasteboard.changeCount

        sendCmdC()

        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            if pasteboard.changeCount != previousChangeCount {
                return pasteboard.string(forType: .string)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    private func stashClipboard() -> [[(type: NSPasteboard.PasteboardType, data: Data)]] {
        let pasteboard = NSPasteboard.general
        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var pairs: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for t in item.types {
                if let data = item.data(forType: t) {
                    pairs.append((type: t, data: data))
                }
            }
            items.append(pairs)
        }
        return items
    }

    private func restoreClipboard(_ items: [[(type: NSPasteboard.PasteboardType, data: Data)]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var newItems: [NSPasteboardItem] = []
        for itemData in items {
            let item = NSPasteboardItem()
            for pair in itemData {
                item.setData(pair.data, forType: pair.type)
            }
            newItems.append(item)
        }
        if !newItems.isEmpty {
            pasteboard.writeObjects(newItems)
        }
    }

    private func sendCmdC() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let cKeyCode: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
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

        // Check if selected text is settable (preferred write path).
        // Fall back to checking kAXValueAttribute for apps that don't report
        // kAXSelectedTextAttribute as settable but still accept it.
        var settable: DarwinBoolean = false
        var err = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if err == .success, settable.boolValue { return .ok }

        err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard err == .success, settable.boolValue else { return .readOnly }

        return .ok
    }

    // MARK: - Selection range helpers

    /// Reads the current kAXSelectedTextRangeAttribute on `element`.
    /// Returns nil if the attribute is missing or malformed. Used by the
    /// revert path to know where a freshly-written correction lives so it
    /// can be replaced with the pre-correction text.
    func currentSelectionRange(of element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let axVal = ref else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Sets kAXSelectedTextRangeAttribute on `element` to the given range.
    /// Used by the revert path to select a freshly-written correction so
    /// the subsequent write() replaces only that text.
    @discardableResult
    func setSelectionRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        return err == .success
    }

    // MARK: - Writing translated text

    enum WriteResult {
        case success
        case needsClipboardFallback
    }

    /// Attempts to write `text` directly via AX attributes.
    /// Tries kAXSelectedTextAttribute first (replaces selection, cursor at end).
    /// Falls back to kAXValueAttribute + cursor repositioning.
    /// Returns `.needsClipboardFallback` if both are rejected by the target app.
    func write(_ text: String, to element: AXUIElement) -> WriteResult {
        // Read selection range before writing so we can reposition cursor afterward.
        // Cmd+Shift+Left (line-selection fallback) creates a backward selection; some apps
        // leave the cursor at the start of the replaced range rather than the end.
        var selRangeRef: CFTypeRef?
        var selRange = CFRange(location: 0, length: 0)
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
           let axVal = selRangeRef {
            AXValueGetValue(axVal as! AXValue, .cfRange, &selRange)
        }

        // Preferred: write to selected text (replaces selection).
        let selErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        #if DEBUG
        print("[AXInteractor] write via kAXSelectedTextAttribute → \(selErr.rawValue)")
        #endif
        if selErr == .success {
            // Verify it actually changed — some apps return success but silently ignore.
            if let val = currentValue(of: element), val.contains(text) {
                // Explicitly reposition cursor to end of inserted text.
                // kAXSelectedTextAttribute with a backward selection (e.g. from Cmd+Shift+Left)
                // may leave the cursor at the start of the replaced range.
                let newLocation = selRange.location + text.utf16.count
                var newRange = CFRange(location: newLocation, length: 0)
                if let rangeValue = AXValueCreate(.cfRange, &newRange) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                }
                return .success
            }
            #if DEBUG
            print("[AXInteractor] kAXSelectedTextAttribute returned success but text didn't change — falling back")
            #endif
        }

        // Fallback: write to full value attribute — must replace only the selected range,
        // not the entire field content (which would wipe surrounding email/document text).
        // Requires a valid selection range and a readable full value to reconstruct safely.
        guard selRange.length > 0,
              let fullText = currentValue(of: element),
              let swiftRange = Range(NSRange(location: selRange.location, length: selRange.length), in: fullText) else {
            // Can't safely reconstruct — selection range missing or full value unreadable.
            return .needsClipboardFallback
        }
        let modified = fullText.replacingCharacters(in: swiftRange, with: text)
        let valErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, modified as CFString)
        #if DEBUG
        print("[AXInteractor] write via kAXValueAttribute (range-splice) → \(valErr.rawValue)")
        #endif
        switch valErr {
        case .success:
            // Reposition cursor to end of inserted text.
            let newLocation = selRange.location + text.utf16.count
            var range = CFRange(location: newLocation, length: 0)
            if let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return .success
        case .apiDisabled, .notImplemented, .cannotComplete, .failure:
            return .needsClipboardFallback
        default:
            return .needsClipboardFallback
        }
    }

    private func selectedTextValue(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard err == .success, let str = value as? String else { return nil }
        return str
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
        #if DEBUG
        if err != .success {
            // Try to identify the frontmost app for diagnostics
            if let app = NSWorkspace.shared.frontmostApplication {
                print("[AXInteractor] focusedElement FAILED: AXError=\(err.rawValue), frontApp=\(app.localizedName ?? "?") (pid=\(app.processIdentifier))")
                // Try via app element instead of system-wide
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var appFocused: CFTypeRef?
                let appErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocused)
                print("[AXInteractor] App-level focusedElement: AXError=\(appErr.rawValue)")
            } else {
                print("[AXInteractor] focusedElement FAILED: AXError=\(err.rawValue), no frontmost app")
            }
        }
        #endif
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

    /// Sends Cmd+Shift+Left to extend the selection from the caret to the
    /// logical line start. No-op when the caret is already at line start
    /// (user just pressed Enter, cursor at top of paragraph, etc.) — see
    /// `selectWholeLine()` for the fallback that handles that case.
    private func selectCurrentLine() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let flags: CGEventFlags = [.maskCommand, .maskShift]

        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: true) // Left arrow
        down?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x7B, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgAnnotatedSessionEventTap)

        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Sends Cmd+Left then Cmd+Shift+Right to select the whole current line
    /// from logical start to logical end, regardless of starting caret
    /// position. Called as fallback when `selectCurrentLine()` yielded an
    /// empty selection (caret was already at line start).
    ///
    /// BIDI-safe: macOS Cmd+Left/Cmd+Right use LOGICAL direction, not visual.
    /// In a right-to-left paragraph (Hebrew, Arabic), Cmd+Left still moves
    /// the caret to the logical line start (visually the right edge) and
    /// Cmd+Shift+Right extends selection to the logical line end (visually
    /// the left edge). Same whole-line selection in both directions.
    private func selectWholeLine() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let leftKey: CGKeyCode = 0x7B
        let rightKey: CGKeyCode = 0x7C

        // Step 1: Cmd+Left — caret to line start (logical).
        let leftDown = CGEvent(keyboardEventSource: src, virtualKey: leftKey, keyDown: true)
        leftDown?.flags = .maskCommand
        leftDown?.post(tap: .cgAnnotatedSessionEventTap)

        let leftUp = CGEvent(keyboardEventSource: src, virtualKey: leftKey, keyDown: false)
        leftUp?.flags = .maskCommand
        leftUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Let the caret move land before extending.
        Thread.sleep(forTimeInterval: 0.03)

        // Step 2: Cmd+Shift+Right — extend selection to line end (logical).
        let extendFlags: CGEventFlags = [.maskCommand, .maskShift]
        let rightDown = CGEvent(keyboardEventSource: src, virtualKey: rightKey, keyDown: true)
        rightDown?.flags = extendFlags
        rightDown?.post(tap: .cgAnnotatedSessionEventTap)

        let rightUp = CGEvent(keyboardEventSource: src, virtualKey: rightKey, keyDown: false)
        rightUp?.flags = extendFlags
        rightUp?.post(tap: .cgAnnotatedSessionEventTap)

        Thread.sleep(forTimeInterval: 0.05)
    }
}
