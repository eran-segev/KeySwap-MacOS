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

final class PermissionsRouter: NSObject, NSWindowDelegate {

    private weak var appState: AppState?
    private var window: NSWindow?
    private var pollingTask: Task<Void, Never>?

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
        return container
    }

    // MARK: - Button actions

    @objc private func grantAccessibility() {
        if AXIsProcessTrusted() {
            updateStatus(tag: 100, text: "✓ Granted", color: .systemGreen)
            Task { @MainActor in appState?.updateAccessibility(true) }
        } else {
            // Open System Settings → Privacy → Accessibility
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
            updateStatus(tag: 100, text: "Waiting...", color: .secondaryLabelColor)
            startPollingAccessibility()
        }
    }

    @objc private func grantInputMonitoring() {
        // Design Change 7 (VERIFY ON MAC): IOHIDRequestAccess may not be a reliable public API.
        // Attempt it; if it doesn't trigger the system dialog, fall through to manual instructions.
        //
        // TODO (TODOS.md): Verify IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) on actual Mac.
        // If unreliable, change this button to open System Settings → Input Monitoring directly.

        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
        updateStatus(tag: 101, text: "Grant in System Settings", color: .secondaryLabelColor)
    }

    // MARK: - Polling

    private func startPollingAccessibility() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.appState?.updateAccessibility(true)
                    self.updateStatus(tag: 100, text: "✓ Granted", color: .systemGreen)
                    self.checkIfComplete()
                    return
                }
            }
        }
    }

    private func checkIfComplete() {
        guard let appState else { return }
        if appState.current == .active {
            window?.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        pollingTask?.cancel()
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
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.window?.contentView?.viewWithTag(tag) as? NSTextField else { return }
            field.stringValue = text
            field.textColor = color
        }
    }
}
