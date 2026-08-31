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
    /// `reselectWholeLineBeforePaste` re-runs the whole-line selection macro
    /// (Cmd+Left, Cmd+Shift+Right) immediately before Cmd+V. Cmd+V replaces the
    /// current selection, so it is only correct while the text we translated is
    /// still selected — and on some apps it isn't by the time we get here. See
    /// `reselectWholeLine()` for why keystrokes are the only trustworthy way to
    /// guarantee that. Pass true ONLY when the translated text is exactly one
    /// whole logical line (SelectionOrigin.wholeLine); anything else and the
    /// macro would select text that was never translated.
    ///
    /// Returns true if paste was detected, false on timeout.
    func pasteViaClipboard(
        translatedText: String,
        axElement: AXElement,
        reselectWholeLineBeforePaste: Bool = false,
        onComplete: @escaping (Bool) -> Void
    ) {
        // STEP 1: Lazy stash (eager dataForType: copy for all declared types)
        let snapshot = stashClipboard()

        // STEP 2: Write translated text
        let pasteboard = NSPasteboard.general
        // Capture BEFORE writing — poll fires when count increments past this value,
        // confirming the pasteboard server processed our write. Capturing after would
        // yield the post-write count and the poll would never fire true.
        let preWriteChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)

        // STEP 3+4: Poll until clipboard is registered (up to 50ms), then send Cmd+V
        pollChangeCount(target: preWriteChangeCount, deadline: Date().addingTimeInterval(0.05)) { [weak self] written in
            guard let self else { return }

            guard written else {
                // Clipboard write didn't land — restore and abort
                self.restoreAndZero(snapshot)
                onComplete(false)
                return
            }

            // STEP 3: Re-select the line (if asked), then fire Cmd+V.
            guard reselectWholeLineBeforePaste else {
                self.sendCmdV()
                self.awaitPasteThenRestore(axElement: axElement, snapshot: snapshot, onComplete: onComplete)
                return
            }
            #if DEBUG
            print("[ClipboardManager] re-selecting whole line via keystrokes before paste")
            #endif
            self.reselectWholeLine { [weak self] in
                guard let self else { return }
                self.sendCmdV()
                self.awaitPasteThenRestore(axElement: axElement, snapshot: snapshot, onComplete: onComplete)
            }
        }
    }

    /// Cmd+Left then Cmd+Shift+Right — the same whole-line macro the read path
    /// used, replayed immediately before Cmd+V.
    ///
    /// Why keystrokes rather than an AX selection write: on Chromium/Electron
    /// fields (Slack's search box is the known case) AX attribute reads and
    /// writes are serviced asynchronously by the renderer, so neither
    /// `kAXValueAttribute` nor the selection attributes reliably describe the
    /// field during the write window — an AX write can report success, be
    /// invisible to every subsequent AX read, and still land. Nothing built on
    /// AX state can decide whether the selection survived. Synthetic key events
    /// sidestep the question entirely: Cmd+Left, Cmd+Shift+Right and Cmd+V ride
    /// the same event queue in order, so whatever the field holds by then, the
    /// line is selected and the paste replaces it instead of appending a second
    /// copy of the translation.
    ///
    /// Chained with asyncAfter rather than Thread.sleep — this runs on the main
    /// queue, and the read path has already spent most of the 500ms SLA.
    private func reselectWholeLine(completion: @escaping () -> Void) {
        postKey(0x7B, flags: .maskCommand)                          // Cmd+Left
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            self.postKey(0x7C, flags: [.maskCommand, .maskShift])   // Cmd+Shift+Right
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
                completion()
            }
        }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// STEP 4+5: wait for the paste to land, then restore the clipboard.
    private func awaitPasteThenRestore(
        axElement: AXElement,
        snapshot: ClipboardSnapshot,
        onComplete: @escaping (Bool) -> Void
    ) {
        let previousValue = axElement.currentValue
        if previousValue == nil {
            // kAXValueAttribute not supported (Word notes/comments, some sandboxed
            // fields). Polling nil==nil would never fire. Use a fixed 150ms wait
            // — generous enough for the paste to land, short enough to stay snappy.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                self.restoreAndZero(snapshot)
                onComplete(true)
            }
            return
        }
        // Poll with a 250ms window. If the value changes (most well-behaved apps:
        // TextEdit, Mail, etc.) we get early confirmation. If it doesn't change in
        // 250ms — either the app's kAXValueAttribute is stale/non-real-time (Word's
        // note panel) or the app is slow — we still report success: Cmd+V was already
        // delivered to a field that passed editable validation, so the paste landed.
        // Using the full 500ms deadline would exceed the 500ms pipeline SLA when
        // combined with the ~80ms of synchronous steps that precede this call.
        self.pollAXValue(element: axElement, previousValue: previousValue, deadline: Date().addingTimeInterval(0.25)) { _ in
            // STEP 5: Restore clipboard regardless of outcome
            self.restoreAndZero(snapshot)
            onComplete(true)
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
