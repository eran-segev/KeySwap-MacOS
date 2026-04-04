import Cocoa

// MARK: - AboutWindow
//
// Native NSWindow showing:
//  - App name + version (from Bundle.main.infoDictionary)
//  - One-sentence description
//  - Hotkey reminder: F9 / Shift+F9
//  - Link to report issues (opens in default browser)
//
// Accessible from menu bar → "About KeySwap"

final class AboutWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        buildAndShow()
    }

    private func buildAndShow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))

        // App name
        let name = field("KeySwap", size: 20, bold: true, alignment: .center)
        name.frame = NSRect(x: 20, y: 210, width: 320, height: 28)
        container.addSubview(name)

        // Version
        let version = versionString()
        let versionField = field(version, size: 12, alignment: .center)
        versionField.textColor = .secondaryLabelColor
        versionField.frame = NSRect(x: 20, y: 186, width: 320, height: 20)
        container.addSubview(versionField)

        // Description
        let desc = field(
            "Corrects bilingual Hebrew/English typing errors.",
            size: 13,
            alignment: .center
        )
        desc.frame = NSRect(x: 20, y: 150, width: 320, height: 30)
        container.addSubview(desc)

        // Hotkey reminder
        let hotkey = field(
            "Press F9 to swap.  Press Shift+F9 to swap back.",
            size: 12,
            alignment: .center
        )
        hotkey.textColor = .secondaryLabelColor
        hotkey.frame = NSRect(x: 20, y: 110, width: 320, height: 30)
        container.addSubview(hotkey)

        // Issue link button
        let linkBtn = NSButton(title: "Report an Issue", target: self, action: #selector(openIssueLink))
        linkBtn.bezelStyle = .recessed
        linkBtn.frame = NSRect(x: 110, y: 60, width: 140, height: 24)
        container.addSubview(linkBtn)

        // Copyright
        let copyright = field("© \(currentYear()) — All rights reserved", size: 11, alignment: .center)
        copyright.textColor = .tertiaryLabelColor
        copyright.frame = NSRect(x: 20, y: 24, width: 320, height: 20)
        container.addSubview(copyright)

        return container
    }

    @objc private func openIssueLink() {
        // URL opened in default browser — safe operation, not a network call from the app itself.
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
