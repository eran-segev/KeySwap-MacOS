import Cocoa

// MARK: - AboutWindow
//
// Native NSWindow showing:
//  - App name + version (from Bundle.main.infoDictionary)
//  - One-sentence description
//  - Hotkey reminder: dynamic from AppSettings
//  - Status line: live from AppState.lastSwapOutcome
//  - Link to report issues (opens in default browser)
//
// Accessible from menu bar -> "About KeySwap"
// Window size: 380x350 (grown from 380x320 to accommodate status line)

@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    weak var appState: AppState?
    weak var appSettings: AppSettings?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        buildAndShow()
    }

    private func buildAndShow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About KeySwap"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = buildContent()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    private func buildContent() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 350))

        let hotkeyName = appSettings?.primaryHotkeyDisplayName ?? "F9"

        // App name (shifted up 30px from original y=270)
        let name = field("KeySwap", size: 20, bold: true, alignment: .center)
        name.frame = NSRect(x: 20, y: 300, width: 340, height: 28)
        container.addSubview(name)

        // Version (shifted up 30px from original y=246)
        let version = versionString()
        let versionField = field(version, size: 12, alignment: .center)
        versionField.textColor = .secondaryLabelColor
        versionField.frame = NSRect(x: 20, y: 276, width: 340, height: 20)
        container.addSubview(versionField)

        // Description (shifted up 30px from original y=214)
        let desc = field(
            "Corrects bilingual Hebrew/English typing errors.",
            size: 13,
            alignment: .center
        )
        desc.frame = NSRect(x: 20, y: 244, width: 340, height: 20)
        container.addSubview(desc)

        // Hotkey reminder - primary (shifted up 30px from original y=184)
        let hotkeyPrimary = field(
            "\(hotkeyName) \u{2014} Swap     Shift+\(hotkeyName) \u{2014} Swap back",
            size: 12,
            alignment: .center
        )
        hotkeyPrimary.textColor = .secondaryLabelColor
        hotkeyPrimary.frame = NSRect(x: 20, y: 214, width: 340, height: 18)
        container.addSubview(hotkeyPrimary)

        // Hotkey reminder - modifiers (shifted up 30px from original y=162)
        let hotkeyModifiers = field(
            "Option+\(hotkeyName) \u{2014} Swap without autocorrect",
            size: 12,
            alignment: .center
        )
        hotkeyModifiers.textColor = .secondaryLabelColor
        hotkeyModifiers.frame = NSRect(x: 20, y: 192, width: 340, height: 18)
        container.addSubview(hotkeyModifiers)

        let hotkeyRevert = field(
            "Press \(hotkeyName) while the corrections popup is open to revert",
            size: 12,
            alignment: .center
        )
        hotkeyRevert.textColor = .secondaryLabelColor
        hotkeyRevert.frame = NSRect(x: 20, y: 170, width: 340, height: 18)
        container.addSubview(hotkeyRevert)

        // Issue link button (shifted up 30px from original y=80)
        let linkBtn = NSButton(title: "Report an Issue", target: self, action: #selector(openIssueLink))
        linkBtn.bezelStyle = .recessed
        linkBtn.frame = NSRect(x: 120, y: 110, width: 140, height: 24)
        container.addSubview(linkBtn)

        // Copyright (shifted up 30px from original y=30)
        let copyright = field("\u{00A9} \(currentYear()) \u{2014} All rights reserved", size: 11, alignment: .center)
        copyright.textColor = .tertiaryLabelColor
        copyright.frame = NSRect(x: 20, y: 60, width: 340, height: 20)
        container.addSubview(copyright)

        // Status line at bottom (new in v1.2)
        let statusText = appState?.lastSwapOutcome ?? "No swaps yet"
        let status = field(statusText, size: 12, alignment: .center) // .caption1 = 12pt
        status.textColor = .tertiaryLabelColor
        status.frame = NSRect(x: 20, y: 10, width: 340, height: 18)
        container.addSubview(status)

        return container
    }

    @objc private func openIssueLink() {
        // URL opened in default browser -- safe operation, not a network call from the app itself.
        // SEC-7: This is user-initiated navigation, not telemetry.
        if let url = URL(string: "https://github.com/ersegev/KeySwap-MacOS/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Helpers

    private func field(_ text: String, size: CGFloat, bold: Bool = false, alignment: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        f.alignment = alignment
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private func currentYear() -> Int {
        Calendar.current.component(.year, from: Date())
    }
}
