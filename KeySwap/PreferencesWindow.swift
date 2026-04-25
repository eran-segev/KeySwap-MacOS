import Cocoa
import Carbon

// MARK: - PreferencesWindow
//
// 500x460 NSWindow for v1.2 + v1.3 Preferences.
// Sections: Hotkey | Autocorrect (per-language) | Sounds | Feedback | Reset to Defaults.
//
// Window grew from 500x400 to 500x460 in v1.3 to fit the per-language autocorrect
// section without compressing other sections. The +60pt headroom also lets the
// dict-missing state (Hebrew checkbox disabled + Install button sub-row) render
// without overlap when the user's Mac lacks the Hebrew spell-check dictionary.
//
// Unlike AboutWindow, this does NOT nil `window` on close — reuses the
// NSWindow instance across open/close cycles. On show(): if window != nil,
// call makeKeyAndOrderFront and return.
//
// Accessibility:
//   - Tab order follows view insertion order (top-to-bottom matches visual).
//   - Slider has accessibility label "Volume".
//   - When Hebrew dict is missing, the Hebrew checkbox is grayed (isEnabled=false)
//     and an inline "Install…" NSButton enters the tab chain so keyboard-only
//     and VoiceOver users have the same install path the toast offers to mouse users.

@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {

    var appSettings: AppSettings?

    private var window: NSWindow?
    private var resignActiveObserver: NSObjectProtocol?
    private var volumePreviewSound: NSSound?

    deinit {
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // Controls that need updating after reset
    private var hotkeyPopup: NSPopUpButton?
    private var conflictLabel: NSTextField?
    private var autocorrectSubLabel: NSTextField?
    private var englishCheckbox: NSButton?
    private var hebrewCheckbox: NSButton?
    private var hebrewMissingLabel: NSTextField?
    private var hebrewInstallButton: NSButton?
    private var soundsCheckbox: NSButton?
    private var volumeSlider: NSSlider?
    private var volumeLabel: NSTextField?
    private var toastRadio: NSButton?
    private var silentRadio: NSButton?

    // MARK: - F-key mapping (ordered for popup menu)

    private struct FKeyEntry {
        let name: String
        let keyCode: Int64
    }

    // Only expose F-keys that are physically present on typical MacBook
    // keyboards AND not occupied by very common default system actions.
    // Excluded: F7/F8 (media prev/play), F11/F12 (volume down/up),
    // F13-F19 (not present on built-in Apple keyboards).
    private let fKeys: [FKeyEntry] = [
        FKeyEntry(name: "F1",  keyCode: Int64(kVK_F1)),
        FKeyEntry(name: "F2",  keyCode: Int64(kVK_F2)),
        FKeyEntry(name: "F3",  keyCode: Int64(kVK_F3)),
        FKeyEntry(name: "F4",  keyCode: Int64(kVK_F4)),
        FKeyEntry(name: "F5",  keyCode: Int64(kVK_F5)),
        FKeyEntry(name: "F6",  keyCode: Int64(kVK_F6)),
        FKeyEntry(name: "F9",  keyCode: Int64(kVK_F9)),
        FKeyEntry(name: "F10", keyCode: Int64(kVK_F10)),
    ]

    // MARK: - Public API

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildAndShow()
    }

    // MARK: - Window construction

    private func buildAndShow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preferences"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = buildContent()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        // Close the Preferences window when the user switches to another app.
        if resignActiveObserver == nil {
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let w = self.window, w.isVisible else { return }
                    w.performClose(nil)
                }
            }
        }
    }

    private static let warningColor = NSColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1)

    private func buildContent() -> NSView {
        guard let settings = appSettings else {
            return NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 460))
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 460))
        let leftPad: CGFloat = 24
        let contentWidth: CGFloat = 452 // 500 - 24*2
        let hebrewAvailable = SpellCheckAvailability.shared.hasHebrew

        // Insert views top-to-bottom (tab order follows insertion order).
        // Y-origin shifted +60pt vs v1.2 to accommodate the per-language
        // autocorrect section.
        var y: CGFloat = 420

        // === HOTKEY SECTION ===
        let hotkeyHeader = sectionHeader("HOTKEY")
        hotkeyHeader.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(hotkeyHeader)
        y -= 28

        let hotkeyLabel = makeLabel("Primary key:", size: 13)
        hotkeyLabel.frame = NSRect(x: leftPad, y: y + 2, width: 90, height: 20)
        container.addSubview(hotkeyLabel)

        let popup = NSPopUpButton(frame: NSRect(x: leftPad + 95, y: y, width: 100, height: 26), pullsDown: false)
        for entry in fKeys {
            popup.addItem(withTitle: entry.name)
        }
        if let idx = fKeys.firstIndex(where: { $0.keyCode == settings.primaryHotkey }) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(hotkeyChanged(_:))
        container.addSubview(popup)
        hotkeyPopup = popup
        y -= 22

        // Conflict warning (pre-allocated, hidden by default)
        let conflict = makeLabel("", size: 11)
        conflict.textColor = Self.warningColor
        conflict.frame = NSRect(x: leftPad + 95, y: y, width: contentWidth - 95, height: 32)
        conflict.maximumNumberOfLines = 2
        conflict.isHidden = !settings.isConflicting(settings.primaryHotkey)
        if !conflict.isHidden {
            conflict.stringValue = "This key may conflict with a\nsystem shortcut."
        }
        container.addSubview(conflict)
        conflictLabel = conflict
        y -= 36

        // === AUTOCORRECT SECTION ===
        // Per-language toggles (v1.3). Shared sub-label sits ABOVE the two
        // checkboxes — signals "one feature, two languages" and avoids the
        // reading trap where an indented sub-label looks like it only applies
        // to the nearest-above checkbox.
        let acHeader = sectionHeader("AUTOCORRECT")
        acHeader.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(acHeader)
        y -= 22

        let hotkeyName = settings.primaryHotkeyDisplayName
        let acSubLabel = makeLabel("Corrections shown in popup. \(hotkeyName) reverts.", size: 11)
        acSubLabel.textColor = .secondaryLabelColor
        acSubLabel.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 16)
        container.addSubview(acSubLabel)
        autocorrectSubLabel = acSubLabel
        y -= 22

        let enCheckbox = NSButton(checkboxWithTitle: "Apply autocorrect in English", target: self, action: #selector(englishToggled(_:)))
        enCheckbox.state = settings.spellCheckEnabledEnglish ? .on : .off
        enCheckbox.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(enCheckbox)
        englishCheckbox = enCheckbox
        y -= 22

        let heCheckbox = NSButton(checkboxWithTitle: "Apply autocorrect in Hebrew", target: self, action: #selector(hebrewToggled(_:)))
        heCheckbox.state = settings.spellCheckEnabledHebrew ? .on : .off
        heCheckbox.isEnabled = hebrewAvailable
        if !hebrewAvailable {
            heCheckbox.setAccessibilityLabel("Apply autocorrect in Hebrew, unavailable because Hebrew dictionary is not installed")
        }
        heCheckbox.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(heCheckbox)
        hebrewCheckbox = heCheckbox
        y -= 20

        // Pre-allocate the missing-dict sub-row (label + Install button).
        // Hidden when the dict is present so the layout doesn't jump if state
        // ever changes between show() calls.
        let missingLabel = makeLabel("Hebrew dictionary not installed.", size: 11)
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.frame = NSRect(x: leftPad + 22, y: y, width: 230, height: 16)
        missingLabel.isHidden = hebrewAvailable
        container.addSubview(missingLabel)
        hebrewMissingLabel = missingLabel

        let installBtn = NSButton(title: "Install\u{2026}", target: self, action: #selector(installHebrewDictionary(_:)))
        installBtn.bezelStyle = .inline
        installBtn.controlSize = .small
        installBtn.setAccessibilityLabel("Install Hebrew dictionary in System Settings")
        installBtn.frame = NSRect(x: leftPad + 256, y: y - 2, width: 80, height: 20)
        installBtn.isHidden = hebrewAvailable
        container.addSubview(installBtn)
        hebrewInstallButton = installBtn

        // Whether or not the dict is missing we shift y by the same amount —
        // the missing-state row is always reserved for layout stability.
        y -= 28

        // === SOUNDS SECTION ===
        let soundsHeader = sectionHeader("SOUNDS")
        soundsHeader.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(soundsHeader)
        y -= 26

        let soundsCheck = NSButton(checkboxWithTitle: "Play sounds", target: self, action: #selector(soundsToggled(_:)))
        soundsCheck.state = settings.soundsEnabled ? .on : .off
        soundsCheck.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(soundsCheck)
        soundsCheckbox = soundsCheck
        y -= 20

        let soundsSubLabel = makeLabel("Note: respects your system sound settings.", size: 11)
        soundsSubLabel.textColor = .secondaryLabelColor
        soundsSubLabel.frame = NSRect(x: leftPad + 20, y: y, width: contentWidth - 20, height: 16)
        container.addSubview(soundsSubLabel)
        y -= 26

        let volLabel = makeLabel("Volume", size: 12)
        volLabel.frame = NSRect(x: leftPad, y: y + 2, width: 55, height: 18)
        container.addSubview(volLabel)
        volumeLabel = volLabel

        let slider = NSSlider(value: Double(settings.soundVolume), minValue: 0.0, maxValue: 1.0, target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: leftPad + 60, y: y, width: contentWidth - 60, height: 22)
        slider.isEnabled = settings.soundsEnabled
        slider.isContinuous = false
        slider.setAccessibilityLabel("Volume")
        container.addSubview(slider)
        volumeSlider = slider
        y -= 34

        // === FEEDBACK SECTION ===
        let fbHeader = sectionHeader("FEEDBACK")
        fbHeader.frame = NSRect(x: leftPad, y: y, width: contentWidth, height: 20)
        container.addSubview(fbHeader)
        y -= 26

        let fbLabel = makeLabel("Show error messages:", size: 13)
        fbLabel.frame = NSRect(x: leftPad, y: y + 2, width: 160, height: 18)
        container.addSubview(fbLabel)

        let toast = NSButton(radioButtonWithTitle: "Toast", target: self, action: #selector(feedbackModeChanged(_:)))
        toast.frame = NSRect(x: leftPad + 165, y: y, width: 70, height: 20)
        toast.state = settings.errorFeedbackMode == .toast ? .on : .off
        toast.tag = 0
        container.addSubview(toast)
        toastRadio = toast

        let silent = NSButton(radioButtonWithTitle: "Silent", target: self, action: #selector(feedbackModeChanged(_:)))
        silent.frame = NSRect(x: leftPad + 240, y: y, width: 80, height: 20)
        silent.state = settings.errorFeedbackMode == .silent ? .on : .off
        silent.tag = 1
        container.addSubview(silent)
        silentRadio = silent
        y -= 40

        // === RESET BUTTON ===
        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults(_:)))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: leftPad + contentWidth - 150, y: 16, width: 150, height: 28)
        container.addSubview(resetBtn)

        return container
    }

    // MARK: - Actions

    @objc private func hotkeyChanged(_ sender: NSPopUpButton) {
        guard let settings = appSettings else { return }
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < fKeys.count else { return }
        let entry = fKeys[idx]
        settings.primaryHotkey = entry.keyCode

        if settings.isConflicting(entry.keyCode) {
            conflictLabel?.stringValue = "This key may conflict with a\nsystem shortcut."
            conflictLabel?.isHidden = false
        } else {
            conflictLabel?.isHidden = true
        }

        autocorrectSubLabel?.stringValue = "Corrections shown in popup. \(settings.primaryHotkeyDisplayName) reverts."
    }

    @objc private func englishToggled(_ sender: NSButton) {
        appSettings?.spellCheckEnabledEnglish = sender.state == .on
    }

    @objc private func hebrewToggled(_ sender: NSButton) {
        appSettings?.spellCheckEnabledHebrew = sender.state == .on
    }

    @objc private func installHebrewDictionary(_ sender: NSButton) {
        let primary = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Text"
        let fallback = "x-apple.systempreferences:com.apple.preference.keyboard"
        if let url = URL(string: primary), NSWorkspace.shared.open(url) {
            return
        }
        if let url = URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func soundsToggled(_ sender: NSButton) {
        guard let settings = appSettings else { return }
        settings.soundsEnabled = sender.state == .on
        volumeSlider?.isEnabled = settings.soundsEnabled
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        guard let settings = appSettings else { return }
        settings.soundVolume = Float(sender.doubleValue)
        guard settings.soundsEnabled else { return }

        // Use a fresh copy of the system sound per preview so rapid slider
        // changes don't hit the shared "already playing" cache. Stop the
        // previous preview so consecutive drags re-trigger instantly.
        volumePreviewSound?.stop()
        let preview = (NSSound(named: NSSound.Name("Pop"))?.copy() as? NSSound)
        if let preview = preview {
            preview.volume = settings.soundVolume
            preview.play()
            volumePreviewSound = preview
        } else {
            NSSound.beep()
        }
    }

    @objc private func feedbackModeChanged(_ sender: NSButton) {
        guard let settings = appSettings else { return }
        if sender.tag == 0 {
            settings.errorFeedbackMode = .toast
            toastRadio?.state = .on
            silentRadio?.state = .off
        } else {
            settings.errorFeedbackMode = .silent
            toastRadio?.state = .off
            silentRadio?.state = .on
        }
    }

    @objc private func resetToDefaults(_ sender: NSButton) {
        guard let settings = appSettings else { return }
        settings.resetToDefaults()

        if let idx = fKeys.firstIndex(where: { $0.keyCode == settings.primaryHotkey }) {
            hotkeyPopup?.selectItem(at: idx)
        }
        conflictLabel?.isHidden = true
        englishCheckbox?.state = settings.spellCheckEnabledEnglish ? .on : .off
        hebrewCheckbox?.state = settings.spellCheckEnabledHebrew ? .on : .off
        autocorrectSubLabel?.stringValue = "Corrections shown in popup. \(settings.primaryHotkeyDisplayName) reverts."
        soundsCheckbox?.state = settings.soundsEnabled ? .on : .off
        volumeSlider?.doubleValue = Double(settings.soundVolume)
        volumeSlider?.isEnabled = settings.soundsEnabled
        toastRadio?.state = settings.errorFeedbackMode == .toast ? .on : .off
        silentRadio?.state = settings.errorFeedbackMode == .silent ? .on : .off
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> NSTextField {
        let f = NSTextField(labelWithString: title)
        f.font = NSFont.systemFont(ofSize: 15, weight: .semibold) // .subheadline per DESIGN.md
        f.textColor = .labelColor
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    private func makeLabel(_ text: String, size: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }
}
