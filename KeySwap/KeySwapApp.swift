import Cocoa
import ServiceManagement
import TranslationContext

// MARK: - Entry Point

@main
@MainActor
final class KeySwapApp: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let appState = AppState()
    private let hotkeyListener = GlobalHotkeyListener()
    private let axInteractor = AccessibilityInteractor()
    private let clipboardManager = ClipboardManager()
    private let layoutSwitcher = LayoutSwitcher()
    private let translationEngine = TranslationContext()
    private let spellCheckFilter = SpellCheckFilter()
    private let correctionsHUD = CorrectionsHUD()

    private lazy var permissionsRouter = PermissionsRouter(appState: appState)
    private lazy var aboutWindow = AboutWindow()

    // MARK: - Menu bar

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    // MARK: - SLA timeout (Design Change 3)

    private var slaTimeoutItem: DispatchWorkItem?

    // MARK: - Active correction badge state (design layer 2)
    //
    // When a correction HUD is showing, the menubar icon switches to a
    // "badged" glyph and the menu gains a "Last correction" item. This gives
    // the user a persistent secondary anchor if they missed the transient HUD.
    // The badge outlives the HUD by 3s (see `badgeGracePeriodSeconds`) so a
    // user who glances up a second late still sees the menubar state.
    private var hasActiveCorrectionBadge = false
    private var badgeClearTimer: DispatchWorkItem?
    private let badgeGracePeriodSeconds: TimeInterval = 3.0
    private var lastCorrectionSummary: String?

    // Menu items populated dynamically. Tag-based lookup avoids stale pointers
    // if buildMenu() ever rebuilds (it currently doesn't, but defending anyway).
    private static let lastCorrectionItemTag = 2
    private static let revertCorrectionItemTag = 3

    // MARK: - NSApplicationMain entry

    static func main() {
        let app = NSApplication.shared
        let delegate = KeySwapApp()
        app.delegate = delegate
        app.run()
    }

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log the running build identity. Printed unconditionally (not DEBUG-gated)
        // so release builds also surface this — makes it trivial to confirm which
        // version is running via Console.app or Xcode's console.
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundlePath = Bundle.main.bundlePath
        print("[KeySwap] Launching v\(ver) (build \(build)) from \(bundlePath)")

        // Register as a login item immediately (best-effort; failure is non-fatal for MVP)
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }

        setupMenuBar()
        setupHotkeyListener()
        checkInitialPermissions()
        warmUpSpellChecker()

        // Keep the corrections HUD in sync with revert availability. When
        // the user types after a correction, AppState clears pendingRevert;
        // if the HUD is still showing, its "Press F9 to revert" hint would
        // lie (F9 would start a new swap instead). Dismiss the HUD in
        // lockstep so the hint stays honest.
        appState.onExplicitClear = { [weak self] in
            guard let self else { return }
            self.correctionsHUD.dismiss(reason: "pending-revert-cleared")
            // Start the grace-period timer for the menubar badge so users
            // who glance up late still see that a correction happened.
            self.scheduleCorrectionBadgeClear(after: self.badgeGracePeriodSeconds)
        }
    }

    // MARK: - Spell checker warm-up

    private func warmUpSpellChecker() {
        // NSSpellChecker communicates via IPC. First call after login can take
        // 100-300ms to wake the system daemon — potentially busting the 500ms SLA.
        // Warm it up on a background queue at launch so the first real swap is fast.
        DispatchQueue.global(qos: .utility).async {
            _ = NSSpellChecker.shared.checkSpelling(of: "warmup", startingAt: 0)
            // NOTE: Do NOT call learnWord() here. learnWord() writes to the system-wide
            // spell dictionary and pollutes every app on the Mac. Per-session ignored words
            // (to prevent Hebrew name transliterations from being "corrected") belong in the
            // Correction Learning Loop feature (P3 in TODOS.md) using a per-document tag.
        }
    }

    // MARK: - Menu bar setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        // State label (first item, disabled)
        let stateLabel = NSMenuItem(title: menuTitle(), action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        stateLabel.tag = 1 // used to update later
        menu.addItem(stateLabel)

        // Version label (disabled, directly below state — so the running build
        // version is visible at a glance without opening About).
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSMenuItem(title: "v\(ver) (build \(build))", action: nil, keyEquivalent: "")
        versionLabel.isEnabled = false
        menu.addItem(versionLabel)

        menu.addItem(.separator())

        // Last correction section. Populated after every swap that applied
        // spell-check corrections. Disabled until the first correction fires.
        let lastCorrection = NSMenuItem(title: "Last correction: none yet", action: nil, keyEquivalent: "")
        lastCorrection.isEnabled = false
        lastCorrection.tag = Self.lastCorrectionItemTag
        menu.addItem(lastCorrection)

        let revertItem = NSMenuItem(title: "Revert last correction (F9 while open)", action: #selector(revertLastCorrectionFromMenu), keyEquivalent: "")
        revertItem.target = self
        revertItem.isEnabled = false
        revertItem.tag = Self.revertCorrectionItemTag
        menu.addItem(revertItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "About KeySwap", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit KeySwap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusMenu = menu
        statusItem?.menu = menu
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        let state = appState.current
        // Icon priority: degraded > active-correction-badge > default.
        // Degraded wins because a broken tap is a bigger deal than an unseen
        // correction receipt. An active correction tints the accent color so
        // it reads as a positive state ("something to look at"), not a warning.
        if state == .degraded {
            button.image = NSImage(systemSymbolName: "keyboard.badge.exclamationmark", accessibilityDescription: "KeySwap degraded")
            button.contentTintColor = nil
        } else if hasActiveCorrectionBadge {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "KeySwap — correction available")
            button.contentTintColor = .controlAccentColor
        } else {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeySwap")
            button.contentTintColor = nil
        }

        // Update state label in menu
        if let item = statusMenu?.item(withTag: 1) {
            switch state {
            case .active:
                item.title = "KeySwap — Active"
            case .degraded:
                item.title = "KeySwap — Degraded (retrying...)"
            case .permissionsRequired:
                item.title = "KeySwap — Permissions Required"
            case .partial:
                item.title = "KeySwap — Partial Permissions"
            }
        }
    }

    // MARK: - Correction badge lifecycle (design layer 2)

    /// Turn on the menubar correction badge and populate the "Last correction"
    /// menu item. Called at the same moment the HUD is shown.
    @MainActor
    private func activateCorrectionBadge(corrections: [Correction]) {
        // A new correction invalidates any in-flight grace-period clear timer.
        badgeClearTimer?.cancel()
        badgeClearTimer = nil

        hasActiveCorrectionBadge = true

        // Summary text: first correction, plus "+N more" if we trimmed.
        let head = corrections.first.map { "\($0.originalWord) → \($0.replacementWord)" } ?? "—"
        let summary: String
        if corrections.count > 1 {
            summary = "\(head) (+\(corrections.count - 1) more)"
        } else {
            summary = head
        }
        lastCorrectionSummary = summary

        if let item = statusMenu?.item(withTag: Self.lastCorrectionItemTag) {
            item.title = "Last correction: \(summary)"
        }
        if let item = statusMenu?.item(withTag: Self.revertCorrectionItemTag) {
            item.isEnabled = true
        }

        updateMenuBarIcon()
        print("[KeySwap] correction badge activated: \(summary)")
    }

    /// Schedule badge removal after the grace period. Called when the HUD
    /// naturally expires — we keep the badge lit a bit longer so users who
    /// glance up late still see the state.
    @MainActor
    private func scheduleCorrectionBadgeClear(after delay: TimeInterval) {
        badgeClearTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearCorrectionBadge(reason: "grace-period-elapsed")
        }
        badgeClearTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Immediately turn off the badge. Called when the user executed the
    /// revert (they handled it, no need to keep nagging them) or a new swap
    /// without corrections started.
    @MainActor
    private func clearCorrectionBadge(reason: String) {
        badgeClearTimer?.cancel()
        badgeClearTimer = nil
        guard hasActiveCorrectionBadge else { return }
        hasActiveCorrectionBadge = false
        // Leave the "Last correction: ..." label in place so the user can
        // still see what changed if they open the menu later. Only disable
        // the Revert action because the revert window has passed.
        if let item = statusMenu?.item(withTag: Self.revertCorrectionItemTag) {
            item.isEnabled = false
        }
        updateMenuBarIcon()
        print("[KeySwap] correction badge cleared (reason=\(reason))")
    }

    @objc private func revertLastCorrectionFromMenu() {
        // Route through the same path as Ctrl+F9 so behavior stays identical.
        handleHotkey(mode: .revert)
    }

    private func menuTitle() -> String {
        switch appState.current {
        case .active: return "KeySwap — Active"
        case .degraded: return "KeySwap — Degraded (retrying...)"
        case .permissionsRequired: return "KeySwap — Permissions Required"
        case .partial: return "KeySwap — Partial Permissions"
        }
    }

    // MARK: - Visual success flash (Design Doc: green icon for 0.5s)

    private func flashSuccess() {
        // Skip the green flash when a correction badge is active — the badge
        // IS the success signal, and a green flash would stomp it for 500ms
        // right when the user is glancing up. For clean swaps (no corrections)
        // the green tint remains the only feedback that F9 did something.
        guard !hasActiveCorrectionBadge else { return }
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "KeySwap — swapped")
        button.contentTintColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Restore through updateMenuBarIcon so we respect any state change
            // that happened during the flash window (e.g. AppState went
            // degraded, or a correction badge arrived).
            self?.updateMenuBarIcon()
        }
    }

    // MARK: - Hotkey listener setup

    private func setupHotkeyListener() {
        hotkeyListener.appState = appState
        hotkeyListener.onTrigger = { [weak self] mode in
            self?.handleHotkey(mode: mode)
        }
    }

    /// Routes the hotkey to either the swap pipeline or the revert path.
    ///
    /// Special case: when the corrections HUD is open AND a pending revert is
    /// available, plain F9 (forward mode) acts as REVERT instead of starting a
    /// new swap. This is friendlier than the dedicated Ctrl+F9 — the user
    /// doesn't have to learn a modifier or reach for it. Ctrl+F9 still works
    /// as an explicit revert for users who prefer the deterministic path.
    /// Shift+F9 (reverse) and Option+F9 (raw) always run a new swap, so users
    /// can opt out of the F9-reverts behavior by adding any modifier.
    @MainActor
    private func handleHotkey(mode: SwapMode) {
        if mode == .forward, correctionsHUD.isShowing, appState.pendingRevert != nil {
            print("[KeySwap] F9 while HUD open — routing to revert")
            runRevertPipeline()
            return
        }
        switch mode {
        case .forward, .reverse:
            runSwapPipeline(skipSpellCheck: false)
        case .raw:
            runSwapPipeline(skipSpellCheck: true)
        case .revert:
            runRevertPipeline()
        }
    }

    // MARK: - Permissions check

    private func checkInitialPermissions() {
        let hasAX = AXIsProcessTrusted()
        // Use the non-prompting probe (create+destroy a CGEventTap) instead of
        // IOHIDRequestAccess, which would trigger a system dialog on first launch.
        let hasIM = GlobalHotkeyListener.probeInputMonitoring()
        #if DEBUG
        print("[KeySwapApp] Initial permissions: AX=\(hasAX), IM=\(hasIM)")
        #endif

        Task { @MainActor in
            appState.updateAccessibility(hasAX)
            appState.updateInputMonitoring(hasIM)

            // If both permissions are granted, start the listener immediately.
            #if DEBUG
            print("[KeySwapApp] AppState after permission update: \(appState.current)")
            #endif
            if hasAX && hasIM {
                #if DEBUG
                print("[KeySwapApp] Both permissions granted — starting hotkey listener")
                #endif
                hotkeyListener.start()
            }

            // Show onboarding if permissions are still missing
            if appState.current != .active {
                permissionsRouter.onBothGranted = { [weak self] in
                    self?.hotkeyListener.start()
                }
                permissionsRouter.showIfNeeded()
            }

            observeAppState()
        }
    }

    private func observeAppState() {
        // Simple polling loop — replacing full Combine/observation to avoid over-engineering.
        Task { @MainActor in
            var lastState = appState.current
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                let newState = appState.current
                if newState != lastState {
                    lastState = newState
                    onStateChanged(newState)
                }
            }
        }
    }

    @MainActor
    private func onStateChanged(_ state: AppState.State) {
        updateMenuBarIcon()
        switch state {
        case .active:
            hotkeyListener.start()
        case .degraded, .partial, .permissionsRequired:
            break // hotkeyListener manages its own DEGRADED recovery
        }
    }

    // MARK: - Swap pipeline

    private func runSwapPipeline(skipSpellCheck: Bool) {
        // Starting a new swap invalidates any outstanding revert window.
        // Dismiss the HUD and clear pendingRevert before doing anything else.
        correctionsHUD.dismiss(reason: "new-swap-started")
        appState.clearPendingRevert()
        // Cancel any pending badge clear — if this swap also has corrections,
        // activateCorrectionBadge() will set the badge fresh. If it doesn't,
        // the badge stays lit through this swap and its grace period continues.
        badgeClearTimer?.cancel()
        badgeClearTimer = nil

        // SLA timeout: 500ms total (Design Change 3)
        let sla = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSSound.beep()
            self.clipboardManager.cancelPending()
            self.hotkeyListener.swapCompleted()
        }
        slaTimeoutItem = sla
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: sla)

        defer {
            // Note: actual cleanup happens in completePipeline() which cancels the SLA timeout.
            // This defer only runs synchronously — async branches clean up themselves.
        }

        // 1. Read selected text
        #if DEBUG
        print("[SwapPipeline] Step 1: reading selected text...")
        #endif
        guard let readResult = axInteractor.readSelectedText() else {
            #if DEBUG
            print("[SwapPipeline] Step 1 FAILED — no selected text")
            #endif
            completePipeline(success: false)
            return
        }

        let text: String
        let axElement: AXUIElement?
        let fallbackUsed: Bool

        switch readResult {
        case .ax(let t, let el, let fb):
            text = t; axElement = el; fallbackUsed = fb
            #if DEBUG
            print("[SwapPipeline] Step 1 OK (AX path): \"\(text.prefix(50))\" (len=\(text.count), fallback=\(fallbackUsed))")
            #endif
        case .clipboardOnly(let t):
            text = t; axElement = nil; fallbackUsed = false
            #if DEBUG
            print("[SwapPipeline] Step 1 OK (clipboard path): \"\(text.prefix(50))\" (len=\(text.count))")
            #endif
        }

        // 2. Validate
        if let el = axElement {
            let validation = axInteractor.validate(element: el, textLength: text.count)
            #if DEBUG
            print("[SwapPipeline] Step 2: validation = \(validation)")
            #endif
            switch validation {
            case .readOnly, .noFocusedElement, .overLimit:
                completePipeline(success: false)
                return
            case .ok:
                break
            }
        } else {
            // Clipboard-only path: just check length
            guard text.count <= 2000 else {
                #if DEBUG
                print("[SwapPipeline] Step 2: over limit (\(text.count) chars)")
                #endif
                completePipeline(success: false)
                return
            }
            #if DEBUG
            print("[SwapPipeline] Step 2: clipboard path, length OK")
            #endif
        }

        // 3. Detect direction + translate
        let direction = layoutSwitcher.swapDirection()
        let targetLanguage: TargetLanguage = direction == .hebrewToEnglish ? .english : .hebrew

        // 3a. Buffer enrichment: recover Shift+letter characters swallowed on Hebrew layout
        var textToTranslate = text
        var shiftIndices = Set<Int>()
        if direction == .hebrewToEnglish,
           let enrichment = hotkeyListener.keystrokeBuffer.enrichedText(fieldText: text) {
            textToTranslate = enrichment.text
            shiftIndices = enrichment.shiftIndices
            #if DEBUG
            print("[SwapPipeline] Step 3a: buffer enrichment applied (field=\(text.count) chars → enriched=\(enrichment.text.count) chars, shifts=\(shiftIndices))")
            #endif
        }

        var translated = translationEngine.translate(textToTranslate, to: targetLanguage, fallbackMacroUsed: fallbackUsed)

        // 3b. Uppercase characters recovered from Shift+letter keystrokes.
        // The user held Shift intentionally — preserve their capitalization intent.
        if targetLanguage == .english && !shiftIndices.isEmpty {
            var chars = Array(translated)
            for idx in shiftIndices where idx < chars.count {
                if chars[idx].isLetter {
                    chars[idx] = Character(String(chars[idx]).uppercased())
                }
            }
            translated = String(chars)
        }
        // 3c. Post-swap spell check: corrects English typos that survived the
        // layout swap (e.g., "teh" → "the"). Runs AFTER the Shift-index pass so
        // intentional capitalizations are already recovered before spell check
        // sees them. Corrections are now TRACKED and made visible to the user
        // via the CorrectionsHUD, with Ctrl+F9 as an escape hatch.
        // If `skipSpellCheck` is true (Option+F9 raw path), correction is skipped
        // entirely — the user gets the raw swap with no modifications.
        let preCorrectionText = translated
        var appliedCorrections: [Correction] = []
        if targetLanguage == .english && !skipSpellCheck {
            let spellResult = spellCheckFilter.postProcess(translated, language: .english, provider: NSSpellCheckerProvider())
            translated = spellResult.corrected
            appliedCorrections = spellResult.corrections
        }

        // Unconditional log: makes it easy to confirm whether spell check ran
        // and what (if anything) it corrected, without needing a DEBUG build.
        if targetLanguage == .english && !skipSpellCheck {
            if appliedCorrections.isEmpty {
                print("[SpellCheck] No misspellings found in swapped text: \"\(translated.prefix(80))\"")
            } else {
                let pairs = appliedCorrections.map { "\($0.originalWord)→\($0.replacementWord)" }.joined(separator: ", ")
                print("[SpellCheck] Found \(appliedCorrections.count) correction(s): \(pairs)")
            }
        } else if skipSpellCheck {
            print("[SpellCheck] Skipped (Option+F9 raw swap)")
        } else {
            print("[SpellCheck] Skipped (target=\(targetLanguage), spell check runs on English target only)")
        }
        #if DEBUG
        print("[SwapPipeline] Step 3: direction=\(direction), target=\(targetLanguage), translated=\"\(translated.prefix(50))\"")
        #endif

        // 4. Write translated text back
        if let el = axElement {
            // Capture the insertion start location BEFORE the write so the revert
            // path knows which UTF16 range to re-select later. The write path
            // replaces whatever is currently selected; start == current selection
            // location (collapsed or otherwise).
            let insertionStart = axInteractor.currentSelectionRange(of: el)?.location ?? 0

            // AX path: try direct write, fall back to clipboard
            let axResult = axInteractor.write(translated, to: el)
            #if DEBUG
            print("[SwapPipeline] Step 4: AX write result = \(axResult)")
            #endif

            switch axResult {
            case .success:
                layoutSwitcher.switchLayout(to: direction)
                recordPendingRevertAndShowHUD(
                    preCorrectionText: preCorrectionText,
                    correctedText: translated,
                    corrections: appliedCorrections,
                    element: el,
                    insertionStart: insertionStart
                )
                completePipeline(success: true)

            case .needsClipboardFallback:
                let axEl = AXElement(ref: el)
                clipboardManager.pasteViaClipboard(
                    translatedText: translated,
                    axElement: axEl
                ) { [weak self] pasted in
                    guard let self else { return }
                    if pasted {
                        self.layoutSwitcher.switchLayout(to: direction)
                        // Clipboard fallback on AX-available apps: still show HUD
                        // (user deserves to see corrections) but revert will use
                        // the AX element if it still accepts writes.
                        self.recordPendingRevertAndShowHUD(
                            preCorrectionText: preCorrectionText,
                            correctedText: translated,
                            corrections: appliedCorrections,
                            element: el,
                            insertionStart: insertionStart
                        )
                        self.completePipeline(success: true)
                    } else {
                        self.completePipeline(success: false)
                    }
                }
            }
        } else {
            // Clipboard-only path (Electron apps): write via Cmd+V, skip AX verification.
            // Revert is NOT supported on this path — no AX element to rewrite into.
            // We still show the HUD so the user sees what was corrected (awareness),
            // but Ctrl+F9 will beep because pendingRevert.element is nil.
            #if DEBUG
            print("[SwapPipeline] Step 4: clipboard-only write path (revert unavailable)")
            #endif
            clipboardManager.pasteWithoutAXVerification(
                translatedText: translated
            ) { [weak self] in
                guard let self else { return }
                self.layoutSwitcher.switchLayout(to: direction)
                self.recordPendingRevertAndShowHUD(
                    preCorrectionText: preCorrectionText,
                    correctedText: translated,
                    corrections: appliedCorrections,
                    element: nil,
                    insertionStart: 0
                )
                self.completePipeline(success: true)
            }
        }
    }

    /// Stashes pendingRevert state and shows the corrections HUD if any
    /// corrections were applied. No-op when corrections is empty.
    @MainActor
    private func recordPendingRevertAndShowHUD(
        preCorrectionText: String,
        correctedText: String,
        corrections: [Correction],
        element: AXUIElement?,
        insertionStart: Int
    ) {
        guard !corrections.isEmpty else { return }

        let revert = PendingRevert(
            preCorrectionText: preCorrectionText,
            correctedText: correctedText,
            corrections: corrections,
            element: element,
            insertionStartLocation: insertionStart
        )
        let duration = CorrectionsHUD.duration(for: corrections.count)
        appState.setPendingRevert(revert, duration: duration) { [weak self] in
            // Timer-driven expiry: dismiss HUD in lockstep, then keep the
            // menubar badge lit for the grace period so late-glancers still
            // see it. Explicit clears (Ctrl+F9, new swap, non-F9 keystroke)
            // handle the HUD themselves so this closure never double-dismisses.
            guard let self else { return }
            self.correctionsHUD.dismiss(reason: "revert-window-expired")
            self.scheduleCorrectionBadgeClear(after: self.badgeGracePeriodSeconds)
        }
        correctionsHUD.show(corrections: corrections, caretElement: element)
        activateCorrectionBadge(corrections: corrections)
    }

    /// Ctrl+F9 revert path. Rewrites pre-correction text over the corrected
    /// text using the stored AX element and insertion start. If no pending
    /// revert exists or it's a clipboard-only swap, beeps and cleans up.
    @MainActor
    private func runRevertPipeline() {
        guard let pending = appState.pendingRevert else {
            #if DEBUG
            print("[RevertPipeline] No pendingRevert — beep")
            #endif
            NSSound.beep()
            hotkeyListener.swapCompleted()
            return
        }

        defer {
            appState.clearPendingRevert()
            correctionsHUD.dismiss(reason: "revert-executed")
            clearCorrectionBadge(reason: "revert-executed")
        }

        guard let el = pending.element else {
            // Clipboard-only swap: no AX element to rewrite. Fall back to
            // synthesized Shift+Left + paste. This works everywhere the
            // original swap worked (same trust assumptions).
            // Use Character count (grapheme clusters), not NSString.length
            // (UTF16 code units). macOS Backspace deletes one grapheme cluster
            // per press — a single emoji is 2 UTF16 units but 1 Backspace.
            let charCount = pending.correctedText.count
            print("[RevertPipeline] clipboard-only revert: backspacing \(charCount) chars and pasting pre-correction text")
            clipboardManager.replaceLastNCharsWithPaste(
                charCount: charCount,
                replacement: pending.preCorrectionText
            ) { [weak self] success in
                guard let self else { return }
                if success {
                    self.flashSuccess()
                } else {
                    NSSound.beep()
                }
                self.hotkeyListener.swapCompleted()
            }
            return
        }

        // Re-select the freshly-written corrected text so the subsequent
        // write() replaces exactly that range and nothing else.
        let selectRange = NSRange(
            location: pending.insertionStartLocation,
            length: (pending.correctedText as NSString).length
        )
        let selected = axInteractor.setSelectionRange(selectRange, on: el)
        #if DEBUG
        print("[RevertPipeline] setSelectionRange(\(selectRange)) → \(selected)")
        #endif

        let axResult = axInteractor.write(pending.preCorrectionText, to: el)
        switch axResult {
        case .success:
            #if DEBUG
            print("[RevertPipeline] AX write succeeded — revert complete")
            #endif
            flashSuccess()
            hotkeyListener.swapCompleted()

        case .needsClipboardFallback:
            // The AX element rejected the revert write. We do NOT try clipboard
            // fallback for revert — it would require another Cmd+V and further
            // mutate the user's state. Beep, leave corrected text in place.
            #if DEBUG
            print("[RevertPipeline] AX write needs clipboard fallback — beep, leaving corrected text")
            #endif
            NSSound.beep()
            hotkeyListener.swapCompleted()
        }
    }

    private func completePipeline(success: Bool) {
        // Cancel the SLA timeout
        slaTimeoutItem?.cancel()
        slaTimeoutItem = nil

        // Clear keystroke buffer after every swap attempt (success or failure)
        hotkeyListener.keystrokeBuffer.clear()

        if success {
            flashSuccess()
        } else {
            NSSound.beep()
        }

        hotkeyListener.swapCompleted()
    }

    // MARK: - Menu actions

    @objc private func showAbout() {
        aboutWindow.show()
    }
}

// MARK: - NSSpellCheckerProvider

private struct NSSpellCheckerProvider: CorrectionProvider {
    func misspelledRange(in text: String, startingAt offset: Int) -> NSRange {
        return NSSpellChecker.shared.checkSpelling(of: text, startingAt: offset)
    }

    func correction(forWord word: String, in text: String) -> String? {
        let checker = NSSpellChecker.shared
        let range = NSRange(word.startIndex..., in: word)
        // Always hardcode "en" — never use checker.language() which reflects system
        // language and would apply Hebrew spell check on a bilingual user's Mac.
        return checker.correction(
            forWordRange: range,
            in: word,
            language: "en",
            inSpellDocumentWithTag: 0
        )
    }
}

// MARK: - ClipboardManager cancel extension
// Allows the SLA timeout to cancel any in-flight polling.
extension ClipboardManager {
    func cancelPending() {
        // In-flight DispatchQueue.main.asyncAfter items can't be individually cancelled.
        // The SLA timeout fires beep and resets isSwapping; subsequent poll callbacks
        // will call completePipeline again (idempotent via isSwapping guard).
        // No additional cancellation needed for MVP.
    }
}
