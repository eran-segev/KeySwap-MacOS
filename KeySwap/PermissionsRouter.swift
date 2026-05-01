import Cocoa
import ApplicationServices

// MARK: - PermissionsRouter
//
// Onboarding window shown on first launch.
// Guides user through granting Accessibility + Input Monitoring permissions.
//
// Flow:
//  1. Show single-window explanation of why permissions are needed
//  2. "Grant Accessibility" → AXIsProcessTrusted(), if not trusted open System Settings
//     → poll every 1s until granted or window closed
//  3. "Grant Input Monitoring" → IOHIDRequestAccess() or instruct user to open System Settings
//     (see TODOS.md: IOHIDRequestAccess needs Mac verification — Design Change 7)
//  4. If window closed without granting both: AppState stays PERMISSIONS_REQUIRED
//  5. If both granted: AppState → ACTIVE, window closes

@MainActor
final class PermissionsRouter: NSObject, NSWindowDelegate {

    private weak var appState: AppState?
    private var window: NSWindow?
    private var axPollingTask: Task<Void, Never>?
    private var imPollingTask: Task<Void, Never>?

    /// Callback invoked when both permissions are granted and the listener should start.
    var onBothGranted: (() -> Void)?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Show / Hide

    func showIfNeeded() {
        guard let appState else { return }
        guard appState.current == .permissionsRequired || appState.current == .partial else { return }
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        buildAndShowWindow()
    }

    private func buildAndShowWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 480, height: 340)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "KeySwap — Permissions Required"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        win.contentView = buildContentView()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    private func buildContentView() -> NSView {
        let container = NSView()

        // Title
        let title = label("KeySwap needs two permissions to work", size: 15, bold: true)
        title.frame = NSRect(x: 24, y: 274, width: 432, height: 24)
        container.addSubview(title)

        // Explanation
        let body = label(
            "KeySwap reads the text you've selected and writes the corrected version back.\n" +
            "This requires Accessibility access. To detect when you press F9, it also needs\n" +
            "Input Monitoring. Neither permission is used for anything else.",
            size: 13
        )
        body.frame = NSRect(x: 24, y: 200, width: 432, height: 70)
        container.addSubview(body)

        // Accessibility row
        let axBtn = button("Grant Accessibility Access", action: #selector(grantAccessibility))
        axBtn.frame = NSRect(x: 24, y: 152, width: 220, height: 32)
        container.addSubview(axBtn)

        let axStatus = label("", size: 12)
        axStatus.tag = 100 // find it later to update
        axStatus.frame = NSRect(x: 252, y: 158, width: 204, height: 20)
        container.addSubview(axStatus)

        // Input Monitoring row
        let imBtn = button("Grant Input Monitoring", action: #selector(grantInputMonitoring))
        imBtn.frame = NSRect(x: 24, y: 108, width: 220, height: 32)
        container.addSubview(imBtn)

        let imStatus = label("", size: 12)
        imStatus.tag = 101
        imStatus.frame = NSRect(x: 252, y: 114, width: 204, height: 20)
        container.addSubview(imStatus)

        // Footer note
        let note = label(
            "After granting both permissions, KeySwap activates automatically.",
            size: 11
        )
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 60, width: 432, height: 40)
        container.addSubview(note)

        container.frame = NSRect(x: 0, y: 0, width: 480, height: 340)

        // Show current state for permissions already granted.
        // Set directly on the labels — self.window isn't assigned yet,
        // so updateStatus(tag:) can't find them via viewWithTag.
        if AXIsProcessTrusted() {
            axStatus.stringValue = "✓ Granted"
            axStatus.textColor = .systemGreen
        }
        if GlobalHotkeyListener.probeInputMonitoring() {
            imStatus.stringValue = "✓ Granted"
            imStatus.textColor = .systemGreen
        }

        return container
    }

    // MARK: - Button actions

    @objc private func grantAccessibility() {
        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt:
        // - Returns true immediately if already trusted
        // - If not trusted, shows the native macOS dialog that opens System Settings
        //   with this app pre-selected, then returns false
        // This is the Apple-recommended approach — it correctly associates the
        // permission with the current binary (important for Xcode debug builds
        // which get a new signature each build).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            updateStatus(tag: 100, text: "✓ Granted", color: .systemGreen)
            appState?.updateAccessibility(true)
            checkIfComplete()
        } else {
            updateStatus(tag: 100, text: "Waiting...", color: .secondaryLabelColor)
            startPollingAccessibility()
        }
    }

    @objc private func grantInputMonitoring() {
        // IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) is the Apple API for Input Monitoring.
        // It triggers the system prompt dialog on first call, and registers the app in
        // System Settings → Input Monitoring. Not bridged to Swift, so we call via dlsym.
        let granted = Self.requestInputMonitoring()
        #if DEBUG
        print("[PermissionsRouter] IOHIDRequestAccess returned: \(granted)")
        #endif

        if granted {
            updateStatus(tag: 101, text: "✓ Granted", color: .systemGreen)
            appState?.updateInputMonitoring(true)
            checkIfComplete()
            return
        }

        // IOHIDRequestAccess should have shown the system prompt or registered the app.
        // Also open System Settings as a fallback in case the prompt didn't appear.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
        updateStatus(tag: 101, text: "Enable in System Settings, then wait...", color: .secondaryLabelColor)
        startPollingInputMonitoring()
    }

    // MARK: - IOHIDRequestAccess bridge

    private typealias IOHIDRequestAccessFunc = @convention(c) (UInt32) -> Bool

    /// Resolved once; the symbol lives in IOKit which is always loaded.
    private static let ioHIDRequestAccess: IOHIDRequestAccessFunc? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "IOHIDRequestAccess") else {
            return nil
        }
        return unsafeBitCast(sym, to: IOHIDRequestAccessFunc.self)
    }()

    /// Calls IOHIDRequestAccess(kIOHIDRequestTypeListenEvent).
    /// Returns true if Input Monitoring is already granted.
    /// On first call, triggers the macOS system prompt to grant access.
    static func requestInputMonitoring() -> Bool {
        guard let fn = ioHIDRequestAccess else { return false }
        let kIOHIDRequestTypeListenEvent: UInt32 = 1
        return fn(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Polling

    private func startPollingAccessibility() {
        axPollingTask?.cancel()
        axPollingTask = Task { @MainActor [weak self] in
            var pollCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                pollCount += 1
                let trusted = AXIsProcessTrusted()
                #if DEBUG
                let bundleID = Bundle.main.bundleIdentifier ?? "nil"
                let execPath = Bundle.main.executablePath ?? "nil"
                print("[PermissionsRouter] AX poll #\(pollCount): trusted=\(trusted), bundleID=\(bundleID), exec=\(execPath)")
                #endif
                if trusted {
                    self.appState?.updateAccessibility(true)
                    self.updateStatus(tag: 100, text: "✓ Granted", color: .systemGreen)
                    self.checkIfComplete()
                    return
                }
            }
        }
    }

    private func startPollingInputMonitoring() {
        imPollingTask?.cancel()
        imPollingTask = Task { @MainActor [weak self] in
            var pollCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                pollCount += 1
                let granted = Self.requestInputMonitoring()
                #if DEBUG
                print("[PermissionsRouter] IM poll #\(pollCount): granted=\(granted)")
                #endif
                if granted {
                    self.appState?.updateInputMonitoring(true)
                    self.updateStatus(tag: 101, text: "✓ Granted", color: .systemGreen)
                    self.checkIfComplete()
                    return
                }
            }
        }
    }

    private func checkIfComplete() {
        guard let appState, appState.current == .active else { return }
        // Fire once, then clear so the listener isn't started twice.
        onBothGranted?()
        onBothGranted = nil
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        axPollingTask?.cancel()
        imPollingTask?.cancel()
        window = nil
    }

    // MARK: - Helpers

    private func label(_ text: String, size: CGFloat, bold: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func updateStatus(tag: Int, text: String, color: NSColor) {
        guard let field = window?.contentView?.viewWithTag(tag) as? NSTextField else { return }
        field.stringValue = text
        field.textColor = color
    }
}
