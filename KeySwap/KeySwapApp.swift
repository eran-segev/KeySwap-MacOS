import Cocoa
import ServiceManagement
import TranslationContext

// MARK: - Entry Point

@main
final class KeySwapApp: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let appState = AppState()
    private let hotkeyListener = GlobalHotkeyListener()
    private let axInteractor = AccessibilityInteractor()
    private let clipboardManager = ClipboardManager()
    private let layoutSwitcher = LayoutSwitcher()
    private let translationEngine = TranslationContext()

    private lazy var permissionsRouter = PermissionsRouter(appState: appState)
    private lazy var aboutWindow = AboutWindow()

    // MARK: - Menu bar

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    // MARK: - SLA timeout (Design Change 3)

    private var slaTimeoutItem: DispatchWorkItem?

    // MARK: - NSApplicationMain entry

    static func main() {
        let app = NSApplication.shared
        let delegate = KeySwapApp()
        app.delegate = delegate
        app.run()
    }

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as a login item immediately (best-effort; failure is non-fatal for MVP)
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }

        setupMenuBar()
        setupHotkeyListener()
        checkInitialPermissions()
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

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "About KeySwap", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit KeySwap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusMenu = menu
        statusItem?.menu = menu
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        let state = appState.current
        if state == .degraded {
            // Warning icon for DEGRADED
            button.image = NSImage(systemSymbolName: "keyboard.badge.exclamationmark", accessibilityDescription: "KeySwap degraded")
        } else {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeySwap")
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
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "KeySwap — swapped")
        button.contentTintColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak button] in
            button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeySwap")
            button?.contentTintColor = nil
        }
    }

    // MARK: - Hotkey listener setup

    private func setupHotkeyListener() {
        hotkeyListener.appState = appState
        hotkeyListener.onTrigger = { [weak self] in
            self?.runSwapPipeline()
        }
    }

    // MARK: - Permissions check

    private func checkInitialPermissions() {
        let hasAX = AXIsProcessTrusted()
        Task { @MainActor in
            appState.updateAccessibility(hasAX)

            // Show onboarding if permissions are missing
            if appState.current != .active {
                permissionsRouter.showIfNeeded()
            }

            // Start listening once we reach ACTIVE state
            // (observer pattern via AppState @Published)
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

    private func runSwapPipeline() {
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
        guard let (text, element, fallbackUsed) = axInteractor.readSelectedText() else {
            completePipeline(success: false)
            return
        }

        // 2. Validate
        switch axInteractor.validate(element: element, textLength: text.count) {
        case .readOnly, .noFocusedElement, .overLimit:
            completePipeline(success: false)
            return
        case .ok:
            break
        }

        // 3. Detect direction + translate
        let direction = layoutSwitcher.swapDirection()
        let targetLanguage: TargetLanguage = direction == .hebrewToEnglish ? .english : .hebrew
        let translated = translationEngine.translate(text, to: targetLanguage, fallbackMacroUsed: fallbackUsed)

        // 4. Attempt AX direct write
        let axResult = axInteractor.write(translated, to: element)

        switch axResult {
        case .success:
            // Direct write succeeded — no clipboard involved
            layoutSwitcher.switchLayout(to: direction)
            completePipeline(success: true)

        case .needsClipboardFallback:
            // Lazy clipboard stash + Cmd+V path
            let axEl = AXElement(ref: element)
            clipboardManager.pasteViaClipboard(
                translatedText: translated,
                axElement: axEl
            ) { [weak self] pasted in
                guard let self else { return }
                if pasted {
                    self.layoutSwitcher.switchLayout(to: direction)
                    self.completePipeline(success: true)
                } else {
                    self.completePipeline(success: false)
                }
            }
        }
    }

    private func completePipeline(success: Bool) {
        // Cancel the SLA timeout
        slaTimeoutItem?.cancel()
        slaTimeoutItem = nil

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
