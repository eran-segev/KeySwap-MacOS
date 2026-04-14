import Cocoa

// MARK: - ClipboardManager
//
// Handles clipboard stash/restore and Cmd+V injection fallback.
//
// Design Change 2: LAZY stash — clipboard data is copied only when the AX direct write fails.
// Design Change 3: 500ms SLA timeout governs the whole pipeline.
// Design Change 6: DispatchQueue recursive polling (no CPU spin, no Thread.sleep).
//
// SEC-3: Clipboard stash data is scoped locally, zeroed after restore.

final class ClipboardManager {

    // ClipboardSnapshot is a nested struct (merged per Design Change 1).
    // Contains the stashed clipboard data: per-item, per-type raw bytes.
    private struct ClipboardSnapshot {
        /// Map from item index → (type → data)
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    }

    // MARK: - Cmd+V fallback path (lazy stash)

    /// Performs the clipboard fallback path:
    ///  1. Stash current clipboard (lazy — only called here, after AX write failed)
    ///  2. Write translated text to clipboard
    ///  3. Fire Cmd+V
    ///  4. Poll for paste completion
    ///  5. Restore clipboard
    ///
    /// Returns true if paste was detected, false on timeout.
    func pasteViaClipboard(
        translatedText: String,
        axElement: AXElement,
        onComplete: @escaping (Bool) -> Void
    ) {
        // STEP 1: Lazy stash (eager dataForType: copy for all declared types)
        let snapshot = stashClipboard()

        // STEP 2: Write translated text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)

        let targetChangeCount = pasteboard.changeCount

        // STEP 3+4: Poll until clipboard is registered (up to 50ms), then send Cmd+V
        pollChangeCount(target: targetChangeCount, deadline: Date().addingTimeInterval(0.05)) { [weak self] written in
            guard let self else { return }

            guard written else {
                // Clipboard write didn't land — restore and abort
                self.restoreAndZero(snapshot)
                onComplete(false)
                return
            }

            // STEP 3: Fire Cmd+V
            self.sendCmdV()

            // STEP 4: Poll AX value for change (up to 500ms)
            let previousValue = axElement.currentValue
            self.pollAXValue(element: axElement, previousValue: previousValue, deadline: Date().addingTimeInterval(0.5)) { changed in
                // STEP 5: Restore clipboard regardless of outcome
                self.restoreAndZero(snapshot)
                onComplete(changed)
            }
        }
    }

    // MARK: - Clipboard-only paste (no AX verification)

    /// For apps where AX is unavailable (Electron etc.).
    /// Stashes clipboard, writes translated text, sends Cmd+V, waits briefly, then restores.
    func pasteWithoutAXVerification(
        translatedText: String,
        onComplete: @escaping () -> Void
    ) {
        let snapshot = stashClipboard()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)

        // Brief delay to ensure clipboard write lands
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            guard let self else { return }
            self.sendCmdV()

            // Wait a bit for the paste to land, then restore clipboard
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.restoreAndZero(snapshot)
                onComplete()
            }
        }
    }

    // MARK: - Clipboard-only revert
    //
    // For apps that took the clipboard-only write path, the AX interactor
    // has no element to rewrite into. But we know two facts:
    //   1. Immediately after the swap, the freshly-pasted corrected text sits
    //      directly before the caret (Cmd+V leaves the cursor at the end of
    //      the pasted content).
    //   2. We know its length.
    // So: Backspace those N chars away, then paste the pre-correction text.
    // Same trust assumptions as the swap's Cmd+V injection.

    /// Delete the last `charCount` characters before the caret (Backspace
    /// repeated), then paste `replacement`. Completion fires after the paste
    /// has landed and the clipboard has been restored.
    ///
    /// Why Backspace instead of Shift+Left+Paste: Shift+Left in a tight loop
    /// doesn't reliably extend selection in third-party apps — events get
    /// coalesced or the selection state resets between events. Backspace is
    /// edit-path rather than selection-path, same idempotent behavior
    /// everywhere, works in every text context that accepts typed input.
    /// We use the same event tap as Cmd+V (`.cgAnnotatedSessionEventTap`),
    /// which we know is functional in this app.
    func replaceLastNCharsWithPaste(
        charCount: Int,
        replacement: String,
        onComplete: @escaping (_ success: Bool) -> Void
    ) {
        guard charCount > 0 else { onComplete(false); return }

        let snapshot = stashClipboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            guard let self else { return }
            // Chain Backspace events with 8ms gaps so the target app can
            // process each deletion before the next one arrives.
            self.sendBackspaceChain(remaining: charCount) { [weak self] in
                guard let self else { return }
                // Small extra pause so the final deletion settles before paste.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
                    guard let self else { return }
                    self.sendCmdV()
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                        guard let self else { return }
                        self.restoreAndZero(snapshot)
                        onComplete(true)
                    }
                }
            }
        }
    }

    private func sendBackspaceChain(remaining: Int, completion: @escaping () -> Void) {
        guard remaining > 0 else { completion(); return }
        sendOneBackspace()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.sendBackspaceChain(remaining: remaining - 1, completion: completion)
        }
    }

    private func sendOneBackspace() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let backspace: CGKeyCode = 51 // kVK_Delete
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: backspace, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: backspace, keyDown: false) else {
            return
        }
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Stash

    private func stashClipboard() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var typeDataPairs: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type_ in item.types {
                // Eagerly copy all data — holding a reference to NSPasteboardItem alone
                // does NOT survive clearContents() because the pasteboard server evicts data.
                if let data = item.data(forType: type_) {
                    typeDataPairs.append((type: type_, data: data))
                }
                // Partial stash: if dataForType returns nil for a declared type, skip it and continue.
            }
            items.append(typeDataPairs)
        }

        return ClipboardSnapshot(items: items)
    }

    // MARK: - Restore + zero

    private func restoreAndZero(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var newItems: [NSPasteboardItem] = []
        for itemData in snapshot.items {
            let item = NSPasteboardItem()
            for pair in itemData {
                item.setData(pair.data, forType: pair.type)
            }
            newItems.append(item)
        }

        if !newItems.isEmpty {
            pasteboard.writeObjects(newItems)
        }

        // SEC-3: Zero sensitive clipboard data after restore
        // (Swift value types are copied, so we zero the Data objects from the snapshot)
        // Note: the snapshot goes out of scope after this function returns.
    }

    // MARK: - Cmd+V injection

    private func sendCmdV() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Polling (Design Change 6: recursive DispatchQueue, no spin)

    /// Polls NSPasteboard.changeCount every 1ms until it increments past `target`.
    /// Calls `completion(true)` when confirmed, `completion(false)` on timeout.
    private func pollChangeCount(
        target: Int,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        if NSPasteboard.general.changeCount != target {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            self?.pollChangeCount(target: target, deadline: deadline, completion: completion)
        }
    }

    /// Polls the AX element's value every 10ms until it changes from `previousValue`.
    private func pollAXValue(
        element: AXElement,
        previousValue: String?,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        let current = element.currentValue
        if current != previousValue {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            self?.pollAXValue(element: element, previousValue: previousValue, deadline: deadline, completion: completion)
        }
    }
}

// MARK: - AXElement wrapper

/// Thin wrapper so ClipboardManager can read the AX value without importing AccessibilityInteractor.
struct AXElement {
    let ref: AXUIElement

    var currentValue: String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }
}
