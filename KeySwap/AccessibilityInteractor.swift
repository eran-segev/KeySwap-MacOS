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
    /// How the text we are about to translate came to be selected. The write
    /// path needs this, not just a yes/no "was a macro used": re-running the
    /// whole-line macro before a Cmd+V is only safe when the text we translated
    /// WAS the whole line. Re-running it after a caret-to-line-start selection
    /// would replace text we never translated.
    enum SelectionOrigin {
        /// The user's own selection. Never re-run a macro over this.
        case userSelection
        /// Macro #1: Cmd+Shift+Left, caret to logical line start. A partial line.
        case caretToLineStart
        /// Macro #2: Cmd+Left then Cmd+Shift+Right. The entire logical line.
        case wholeLine

        /// Whether a destructive selection macro fired — drives the paragraph
        /// writing-direction flip, same meaning the old `fallbackMacroUsed` had.
        var usedFallbackMacro: Bool { self != .userSelection }

        /// Whether the selection covers exactly one whole logical line, so
        /// re-selecting that line replaces precisely what we translated.
        var isWholeLine: Bool { self == .wholeLine }
    }

    enum ReadResult {
        case ax(text: String, element: AXUIElement, origin: SelectionOrigin)
        case clipboardOnly(text: String, origin: SelectionOrigin)
    }

    func readSelectedText() -> ReadResult? {
        // Tracks how the selection we end up acting on was produced, across the
        // whole read operation — not just within one branch. The macros mutate a
        // single piece of UI state, so one shared variable is the accurate model:
        // running line macros in the AX branch and then Cmd+C'ing the result in
        // the clipboard branch must still report the macro that actually made the
        // selection, both for the writing-direction flip and for the write path's
        // re-selection safety check.
        var origin: SelectionOrigin = .userSelection

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
                return .ax(text: text, element: element, origin: origin)
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
                    return .ax(text: text, element: element, origin: origin)
                }
            }

            if rangeOpt != nil {
                #if DEBUG
                print("[AXInteractor] readSelectedText: no selection, trying Cmd+Shift+Left fallback...")
                #endif

                // Fallback macro #1: Cmd+Shift+Left (extend selection from caret to
                // logical line start). Works when caret is mid-line.
                selectCurrentLine()
                origin = .caretToLineStart
                // Poll rather than read once — some apps (e.g. OneNote) update
                // kAXSelectedTextAttribute asynchronously after a key macro lands,
                // so a single read at t+50ms misses the selection even though it is
                // visually present. Polling retries up to 100ms at 20ms intervals.
                if let text = pollForSelectedText(from: element), !text.isEmpty {
                    #if DEBUG
                    print("[AXInteractor] readSelectedText: Cmd+Shift+Left fallback got \(text.count) chars")
                    #endif
                    return .ax(text: text, element: element, origin: origin)
                }

                // Fallback macro #2: Cmd+Left then Cmd+Shift+Right (caret to line
                // start, then extend to line end). Always selects the whole line
                // regardless of starting caret position — fixes the "caret at line
                // start" no-op failure of macro #1.
                #if DEBUG
                print("[AXInteractor] readSelectedText: macro #1 empty, trying whole-line macro...")
                #endif
                selectWholeLine()
                origin = .wholeLine
                if let text = pollForSelectedText(from: element), !text.isEmpty {
                    #if DEBUG
                    print("[AXInteractor] readSelectedText: whole-line fallback got \(text.count) chars")
                    #endif
                    return .ax(text: text, element: element, origin: origin)
                }
            }
        }

        // AX path failed entirely (no focused element, or no text found).
        // Last resort: read selection via Cmd+C → clipboard.
        #if DEBUG
        print("[AXInteractor] readSelectedText: AX failed, trying Cmd+C clipboard path...")
        #endif
        if let text = readSelectionViaClipboard(origin: &origin), !text.isEmpty {
            #if DEBUG
            print("[AXInteractor] readSelectedText: clipboard path got \(text.count) chars (origin=\(origin))")
            #endif
            return .clipboardOnly(text: text, origin: origin)
        }

        #if DEBUG
        print("[AXInteractor] readSelectedText: all paths failed, no text available")
        #endif
        return nil
    }

    // MARK: - Clipboard-based selection reading (for Electron apps etc.)

    /// Sends Cmd+C, reads the clipboard, then restores the previous clipboard contents.
    /// If nothing is selected, tries Cmd+Shift+Left first to select the current line.
    /// Updates `origin` in place as macros fire, so the caller keeps an accurate
    /// picture of what made the selection even when AX-branch macros already ran.
    private func readSelectionViaClipboard(origin: inout SelectionOrigin) -> String? {
        let pasteboard = NSPasteboard.general
        let stashedItems = stashClipboard()

        // First attempt: Cmd+C on whatever is already selected
        var text = copyViaClipboard(pasteboard: pasteboard)

        if text == nil {
            // Macro #1: Cmd+Shift+Left (cursor to line start). Works when
            // caret is mid-line; no-op when caret is at line start.
            #if DEBUG
            print("[AXInteractor] clipboard path: no selection, sending Cmd+Shift+Left then Cmd+C")
            #endif
            selectCurrentLine()
            origin = .caretToLineStart
            text = copyViaClipboard(pasteboard: pasteboard)
            // Retry with extra wait: some apps (e.g. OneNote) commit the selection
            // asynchronously after the macro key lands. The 50ms sleep inside
            // selectCurrentLine() plus the 200ms clipboard poll is not enough —
            // Cmd+C arrives before the selection is committed. Sending Cmd+C again
            // after an additional 150ms gives those apps time to catch up.
            if text == nil {
                #if DEBUG
                print("[AXInteractor] clipboard path: macro #1 retry after extra wait")
                #endif
                Thread.sleep(forTimeInterval: 0.15)
                text = copyViaClipboard(pasteboard: pasteboard)
            }
        }

        if text == nil {
            // Macro #2: Cmd+Left then Cmd+Shift+Right (whole line, start→end).
            // Selects the whole line regardless of caret position.
            #if DEBUG
            print("[AXInteractor] clipboard path: macro #1 empty, sending whole-line macro then Cmd+C")
            #endif
            selectWholeLine()
            origin = .wholeLine
            text = copyViaClipboard(pasteboard: pasteboard)
            if text == nil {
                #if DEBUG
                print("[AXInteractor] clipboard path: macro #2 retry after extra wait")
                #endif
                Thread.sleep(forTimeInterval: 0.15)
                text = copyViaClipboard(pasteboard: pasteboard)
            }
        }

        // Restore clipboard
        restoreClipboard(stashedItems)

        return text
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
        if err == .success, settable.boolValue { return .ok }

        // AXTextArea and AXTextField are inherently editable roles. Some apps
        // (Word's note/comment panel is the known case) incorrectly report both
        // attributes as non-settable even though the field accepts keyboard input
        // and Cmd+V paste. Trust the role over the broken settable flag — the write
        // path will attempt AX first and fall back to Cmd+V if AX is rejected.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
            return .ok
        }

        return .readOnly
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
        var hasSelRange = false
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
           let axVal = selRangeRef {
            hasSelRange = AXValueGetValue(axVal as! AXValue, .cfRange, &selRange)
        }

        // Snapshot of exactly what we are about to replace. Everything below uses
        // it to tell two outcomes apart that kAXValueAttribute alone cannot:
        // "the app ignored our write" vs "the app applied our write but never
        // reflected it back through kAXValueAttribute". Getting that wrong in the
        // second direction is what pastes the translation twice.
        let originalRange: NSRange? = hasSelRange
            ? NSRange(location: selRange.location, length: selRange.length)
            : nil
        let originalSelectedText = selectedText(from: element)
        #if DEBUG
        print("[AXInteractor] write: pre-write range=\(originalRange.map { "{\($0.location),\($0.length)}" } ?? "nil"), selLen=\(originalSelectedText?.utf16.count ?? -1), valueLen=\(currentValue(of: element)?.utf16.count ?? -1)")
        #endif

        // Preferred: write to selected text (replaces selection).
        let selErr = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        #if DEBUG
        print("[AXInteractor] write via kAXSelectedTextAttribute → \(selErr.rawValue)")
        #endif
        if selErr == .success {
            // Poll rather than read once — some apps (Chrome/Chromium text fields,
            // same async-commit pattern as OneNote's selection) update
            // kAXValueAttribute asynchronously after an AX write lands. A single
            // immediate read can see the pre-write value and wrongly conclude the
            // write failed, falling through to the clipboard/Cmd+V path on top of
            // a write that actually landed a moment later — producing two copies
            // of the same translated text with the cursor stuck between them.
            let settled = pollUntilSettled {
                Self.isSelectedTextWriteConfirmed(currentValue: self.currentValue(of: element), written: text)
                    || self.selectionWasConsumed(
                        element: element,
                        originalText: originalSelectedText,
                        originalRange: originalRange
                    )
            }
            if settled {
                // Two cases where we trust the write:
                //   1. kAXValueAttribute is nil — app doesn't expose this attribute
                //      (Word notes/comments, some sandboxed fields). Can't verify, but
                //      AX reported success so trust it. Falling back to Cmd+V would
                //      cause a double-write since the AX write already landed.
                //   2. Value confirmed — text appears in the field value.
                //   3. The selection we were replacing is gone — proof the write
                //      landed even where kAXValueAttribute is a stale mirror that
                //      never reflects the field's real content (Slack's Electron
                //      AXComboBox). Without this, the splice below would run
                //      against a stale value read and clobber the field.
                let newLocation = selRange.location + text.utf16.count
                var newRange = CFRange(location: newLocation, length: 0)
                if let rangeValue = AXValueCreate(.cfRange, &newRange) {
                    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                }
                return .success
            }
            // kAXValueAttribute never showed the written text within the poll budget —
            // app returned success but silently ignored the write (known Electron pattern).
            #if DEBUG
            print("[AXInteractor] kAXSelectedTextAttribute returned success but text didn't change — falling back (post-write range=\(currentSelectionRange(of: element).map { "{\($0.location),\($0.length)}" } ?? "nil"), selLen=\(selectedText(from: element)?.utf16.count ?? -1), valueLen=\(currentValue(of: element)?.utf16.count ?? -1))")
            #endif
        }

        // Fallback: write to full value attribute — must replace only the selected range,
        // not the entire field content (which would wipe surrounding email/document text).
        // Requires a valid selection range and a readable full value to reconstruct safely.
        guard selRange.length > 0,
              let fullText = currentValue(of: element),
              let swiftRange = Range(NSRange(location: selRange.location, length: selRange.length), in: fullText) else {
            // Can't safely reconstruct — selection range missing or full value unreadable.
            return clipboardFallbackDecision(
                element: element,
                originalText: originalSelectedText,
                originalRange: originalRange
            )
        }
        let modified = fullText.replacingCharacters(in: swiftRange, with: text)
        let valErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, modified as CFString)
        #if DEBUG
        print("[AXInteractor] write via kAXValueAttribute (range-splice) → \(valErr.rawValue)")
        #endif
        switch valErr {
        case .success:
            // Verify the splice actually landed — some apps (Word's note/comment panel)
            // accept kAXValueAttribute writes and return success but silently ignore them.
            // Poll (same async-commit reasoning as above) rather than reread once;
            // declaring failure too early here routes into the clipboard/Cmd+V
            // fallback on top of a splice that lands a moment later, doubling the text.
            let settled = pollUntilSettled {
                Self.isSpliceWriteConfirmed(currentValue: self.currentValue(of: element), expected: modified)
            }
            if !settled {
                #if DEBUG
                print("[AXInteractor] kAXValueAttribute splice returned success but value didn't change — clipboard fallback")
                #endif
                return clipboardFallbackDecision(
                    element: element,
                    originalText: originalSelectedText,
                    originalRange: originalRange
                )
            }
            // Reposition cursor to end of inserted text.
            let newLocation = selRange.location + text.utf16.count
            var range = CFRange(location: newLocation, length: 0)
            if let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return .success
        case .apiDisabled, .notImplemented, .cannotComplete, .failure:
            return clipboardFallbackDecision(
                element: element,
                originalText: originalSelectedText,
                originalRange: originalRange
            )
        default:
            return clipboardFallbackDecision(
                element: element,
                originalText: originalSelectedText,
                originalRange: originalRange
            )
        }
    }

    // MARK: - Double-write protection
    //
    // The pipeline's clipboard fallback sends Cmd+V, which REPLACES the current
    // selection. That is only correct while the selection we were asked to
    // translate is still there. If an AX write silently landed but the app never
    // reported it back, the selection is already gone and Cmd+V INSERTS instead —
    // the user sees the translated word twice ("YoavYoav").
    //
    // Slack's search field is the known case: role AXComboBox, and its
    // kAXValueAttribute is a stale mirror that never reflects the field's real
    // content. Both write verifications below read that one attribute, so both
    // false-negative, and the fallback pastes on top of a write that worked.
    // Its selection attributes ARE live, so we verify against those instead.

    /// True when the selection recorded before the AX write is no longer there —
    /// evidence the write consumed it and landed, independent of whatever
    /// `kAXValueAttribute` claims.
    ///
    /// Deliberately conservative: any unreadable signal returns false ("not
    /// consumed"), so apps that genuinely need the Cmd+V fallback still get it.
    private func selectionWasConsumed(
        element: AXUIElement,
        originalText: String?,
        originalRange: NSRange?
    ) -> Bool {
        Self.isSelectionConsumed(
            originalText: originalText,
            originalRange: originalRange,
            currentText: selectedText(from: element),
            currentRange: currentSelectionRange(of: element)
        )
    }

    /// Decides whether the Cmd+V clipboard fallback is safe now that both AX
    /// write attempts have reported failure.
    ///
    /// Re-asserts the pre-write selection and reads back what actually sits under
    /// it. That both diagnoses and repairs:
    ///   - reads back as the original text → nothing was written; Cmd+V is safe,
    ///     and the selection we just restored makes it a replace rather than an
    ///     insert even if a partial write had collapsed the caret
    ///   - reads back as something else → a write landed after all; report
    ///     `.success` instead of pasting a second copy
    ///   - unreadable → unknown; keep the fallback so apps that depend on Cmd+V
    ///     (Word's note/comment panel) keep working exactly as before
    private func clipboardFallbackDecision(
        element: AXUIElement,
        originalText: String?,
        originalRange: NSRange?
    ) -> WriteResult {
        guard let originalText, !originalText.isEmpty,
              let originalRange, originalRange.length > 0 else {
            #if DEBUG
            print("[AXInteractor] fallback gate: no pre-write selection snapshot — cannot judge, pasting")
            #endif
            return .needsClipboardFallback
        }

        setSelectionRange(originalRange, on: element)
        let reselected = pollForNonEmptySelectedText(from: element)

        if Self.fallbackIsSafe(originalText: originalText, reselectedText: reselected) {
            #if DEBUG
            let verdict = (reselected ?? "").isEmpty
                ? "re-selection unreadable — cannot judge"
                : "original text still present — no AX write landed"
            print("[AXInteractor] fallback gate: \(verdict) (reselectedLen=\(reselected?.utf16.count ?? -1)), pasting")
            #endif
            return .needsClipboardFallback
        }

        // A write landed. Collapse the selection we just re-asserted so the user
        // isn't left with their freshly translated word highlighted, and place the
        // caret after it the same way the success paths above do.
        let end = originalRange.location + (reselected?.utf16.count ?? 0)
        setSelectionRange(NSRange(location: end, length: 0), on: element)
        #if DEBUG
        print("[AXInteractor] clipboard fallback suppressed — AX write landed despite failed verification")
        #endif
        return .success
    }

    /// Polls `kAXSelectedTextAttribute` for a non-empty string, giving the app a
    /// beat to commit the selection we just set. Same async-commit tolerance as
    /// `pollForSelectedText`, without the range-agreement requirement — here we
    /// set the range ourselves, so only the content read matters.
    private func pollForNonEmptySelectedText(from element: AXUIElement, timeoutMS: Int = 60) -> String? {
        var last: String?
        _ = pollUntilSettled(timeoutMS: timeoutMS) {
            last = self.selectedText(from: element)
            return !(last ?? "").isEmpty
        }
        return last
    }

    /// True when `current*` shows a different selection than `original*` — the
    /// pure decision behind `selectionWasConsumed`.
    ///
    /// Requires a real pre-write selection to compare against: with no original
    /// text or a collapsed original range there is nothing that could have been
    /// consumed, so the answer is false. A nil `currentRange` means the app
    /// stopped reporting the attribute; that is unknown, not consumed.
    static func isSelectionConsumed(
        originalText: String?,
        originalRange: NSRange?,
        currentText: String?,
        currentRange: NSRange?
    ) -> Bool {
        guard let originalText, !originalText.isEmpty,
              let originalRange, originalRange.length > 0 else { return false }
        guard let currentRange else { return false }
        if currentRange != originalRange { return true }
        guard let currentText else { return false }
        return currentText != originalText
    }

    /// True when it is safe to let the pipeline paste — i.e. re-asserting the
    /// pre-write selection read back the original text, so nothing was written.
    /// Unreadable (nil/empty) read-backs return true to preserve the pre-fix
    /// behavior for apps whose selection attributes we can't trust either.
    static func fallbackIsSafe(originalText: String?, reselectedText: String?) -> Bool {
        guard let originalText, !originalText.isEmpty else { return true }
        guard let reselectedText, !reselectedText.isEmpty else { return true }
        return reselectedText == originalText
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

    /// Generic settle-poll: calls `check` every 20ms (immediately on the first
    /// call, so apps that commit synchronously incur no extra delay) until it
    /// returns true or the budget is exhausted. Shared by the write-verification
    /// polls in `write()` and by `pollForSelectedText` below — both exist to
    /// tolerate apps (OneNote, Chrome/Chromium) that commit AX attribute
    /// changes asynchronously rather than in lockstep with the AX call that
    /// triggered them.
    private func pollUntilSettled(timeoutMS: Int = 100, check: () -> Bool) -> Bool {
        let steps = max(1, timeoutMS / 20)
        for i in 0..<steps {
            if check() {
                return true
            }
            if i < steps - 1 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return false
    }

    /// Polls kAXSelectedTextAttribute every 20ms until it returns a non-empty
    /// string AND kAXSelectedTextRangeAttribute has caught up to match it, or
    /// the budget is exhausted. The initial read happens immediately (at t=0
    /// relative to the call) so fast apps incur no extra delay; the loop only
    /// spins for apps that update AX asynchronously after a key macro.
    ///
    /// Some apps (OneNote and other canvas-based note apps) commit these two
    /// attributes independently: the selected substring can become readable
    /// before the app finishes computing the linear {location, length} range
    /// (likely a separate layout pass). Trusting the text alone let `write()`
    /// later read a stale, collapsed range and INSERT the translation next to
    /// the untouched original word instead of replacing it — visible as two
    /// copies of the word with the cursor landing in between. Waiting for both
    /// signals to agree before returning closes that race.
    ///
    /// 100ms default: combined with selectCurrentLine's 50ms sleep this gives a
    /// 150ms window from macro to AX read — enough for any legitimately slow app
    /// without adding 300ms latency when the macro is a no-op (caret at line start).
    private func pollForSelectedText(from element: AXUIElement, timeoutMS: Int = 100) -> String? {
        let steps = max(1, timeoutMS / 20)
        for i in 0..<steps {
            let text = selectedText(from: element)
            let rangeLength = currentSelectionRange(of: element)?.length
            if Self.isSelectionSettled(text: text, rangeLength: rangeLength) {
                return text
            }
            if i < steps - 1 {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return nil
    }

    /// True once the selected-text content and the selected-text range agree
    /// on the same selection — i.e. it's safe to act on `text` because the
    /// paired range (used later by `write()` to splice/reposition) reflects
    /// the same selection rather than a stale, pre-commit value.
    static func isSelectionSettled(text: String?, rangeLength: Int?) -> Bool {
        guard let text, !text.isEmpty, let rangeLength else { return false }
        return rangeLength == text.utf16.count
    }

    /// True once the field's value confirms (or can't contradict) a
    /// `kAXSelectedTextAttribute` write of `written`. `currentValue == nil`
    /// means the app doesn't expose `kAXValueAttribute` at all (Word
    /// notes/comments) — nothing to contradict the AX-reported success with,
    /// so it's trusted. Otherwise the value must actually contain what was
    /// written; a value that doesn't (yet) contain it means the write either
    /// failed or hasn't been reflected back to AX yet.
    static func isSelectedTextWriteConfirmed(currentValue: String?, written: String) -> Bool {
        currentValue == nil || currentValue!.contains(written)
    }

    /// True once the field's value matches the full post-splice string
    /// `expected` exactly — used to confirm a `kAXValueAttribute` range-splice
    /// write actually landed before trusting it.
    static func isSpliceWriteConfirmed(currentValue: String?, expected: String) -> Bool {
        currentValue == expected
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
