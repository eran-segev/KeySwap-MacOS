import Cocoa
import Carbon
import ServiceManagement

// MARK: - ErrorFeedbackMode

enum ErrorFeedbackMode: String {
    case toast
    case silent
}

// MARK: - AppSettings
//
// UserDefaults-backed settings model for v1.2 + v1.3 Preferences.
// All properties are stored as native types (Int64/Bool/Float/String)
// in UserDefaults. Marked @MainActor because sound helpers touch NSSound
// and the onHotkeyChanged callback drives a @MainActor-constrained
// GlobalHotkeyListener.
//
// CRITICAL: Sound helpers use `let s = NSSound(named: ...); s?.volume = ...`
// — never `NSSound.volume = ...` which is a CLASS PROPERTY that mutates the
// system master volume.

@MainActor
final class AppSettings {

    // MARK: - UserDefaults keys

    private enum Key {
        static let primaryHotkey = "primaryHotkey"
        static let soundsEnabled = "soundsEnabled"
        static let soundVolume = "soundVolume"
        // Legacy v1.2 key — replaced by per-language toggles in v1.3.
        // Read once during migration, then deleted.
        static let spellCheckEnabledLegacy = "spellCheckEnabled"
        static let spellCheckEnabledEnglish = "spellCheckEnabledEnglish"
        static let spellCheckEnabledHebrew = "spellCheckEnabledHebrew"
        static let didMigrateSpellCheck_v1_3 = "didMigrateSpellCheck_v1_3"
        static let errorFeedbackMode = "errorFeedbackMode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        runSpellCheckMigrationIfNeeded()
    }

    // MARK: - Callback

    /// Fired when the hotkey changes (from Preferences or resetToDefaults).
    /// Wired by KeySwapApp at launch.
    var onHotkeyChanged: ((Int64) -> Void)?

    // MARK: - Properties

    var primaryHotkey: Int64 {
        get {
            // Use integer(forKey:) — the documented, bridge-stable API.
            // Returns 0 when the key is absent; kVK_F* keycodes are all non-zero
            // so 0 is a safe sentinel for "never set, use default".
            let val = defaults.integer(forKey: Key.primaryHotkey)
            return val == 0 ? Int64(kVK_F9) : Int64(val)
        }
        set {
            defaults.set(Int(newValue), forKey: Key.primaryHotkey)
            onHotkeyChanged?(newValue)
        }
    }

    var soundsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.soundsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.soundsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    var soundVolume: Float {
        get {
            if defaults.object(forKey: Key.soundVolume) == nil { return 0.8 }
            let val = defaults.float(forKey: Key.soundVolume)
            return min(max(val, 0.0), 1.0)
        }
        set { defaults.set(min(max(newValue, 0.0), 1.0), forKey: Key.soundVolume) }
    }

    var spellCheckEnabledEnglish: Bool {
        get {
            if defaults.object(forKey: Key.spellCheckEnabledEnglish) == nil { return true }
            return defaults.bool(forKey: Key.spellCheckEnabledEnglish)
        }
        set { defaults.set(newValue, forKey: Key.spellCheckEnabledEnglish) }
    }

    var spellCheckEnabledHebrew: Bool {
        get {
            if defaults.object(forKey: Key.spellCheckEnabledHebrew) == nil { return true }
            return defaults.bool(forKey: Key.spellCheckEnabledHebrew)
        }
        set { defaults.set(newValue, forKey: Key.spellCheckEnabledHebrew) }
    }

    var launchAtLogin: Bool {
        get {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[AppSettings] launchAtLogin set(\(newValue)) failed: \(error)")
            }
        }
    }

    var errorFeedbackMode: ErrorFeedbackMode {
        get {
            guard let raw = defaults.string(forKey: Key.errorFeedbackMode),
                  let mode = ErrorFeedbackMode(rawValue: raw) else { return .toast }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.errorFeedbackMode) }
    }

    // MARK: - v1.2 → v1.3 migration
    //
    // One-shot migration from the legacy single `spellCheckEnabled` toggle to
    // per-language toggles. Guarded by `didMigrateSpellCheck_v1_3` so repeated
    // inits are free and the migration runs exactly once even if a user
    // downgrades and re-upgrades.
    //
    // Defensive: only copy the legacy value into a new key if that new key is
    // absent from defaults — never clobber an existing value.

    private func runSpellCheckMigrationIfNeeded() {
        guard !defaults.bool(forKey: Key.didMigrateSpellCheck_v1_3) else { return }
        if defaults.object(forKey: Key.spellCheckEnabledLegacy) != nil {
            let legacy = defaults.bool(forKey: Key.spellCheckEnabledLegacy)
            if defaults.object(forKey: Key.spellCheckEnabledEnglish) == nil {
                defaults.set(legacy, forKey: Key.spellCheckEnabledEnglish)
            }
            if defaults.object(forKey: Key.spellCheckEnabledHebrew) == nil {
                defaults.set(legacy, forKey: Key.spellCheckEnabledHebrew)
            }
            defaults.removeObject(forKey: Key.spellCheckEnabledLegacy)
        }
        defaults.set(true, forKey: Key.didMigrateSpellCheck_v1_3)
    }

    // MARK: - Display name

    var primaryHotkeyDisplayName: String {
        switch primaryHotkey {
        case Int64(kVK_F1):  return "F1"
        case Int64(kVK_F2):  return "F2"
        case Int64(kVK_F3):  return "F3"
        case Int64(kVK_F4):  return "F4"
        case Int64(kVK_F5):  return "F5"
        case Int64(kVK_F6):  return "F6"
        case Int64(kVK_F7):  return "F7"
        case Int64(kVK_F8):  return "F8"
        case Int64(kVK_F9):  return "F9"
        case Int64(kVK_F10): return "F10"
        case Int64(kVK_F11): return "F11"
        case Int64(kVK_F12): return "F12"
        case Int64(kVK_F13): return "F13"
        case Int64(kVK_F14): return "F14"
        case Int64(kVK_F15): return "F15"
        case Int64(kVK_F16): return "F16"
        case Int64(kVK_F17): return "F17"
        case Int64(kVK_F18): return "F18"
        case Int64(kVK_F19): return "F19"
        default: return "F9"
        }
    }

    // MARK: - Hotkey conflict detection

    /// Known system-level F-key keycodes that conflict with media controls
    /// on most MacBooks and cannot be remapped without disabling media keys globally.
    static let conflictingKeyCodes: Set<Int64> = [
        Int64(kVK_F7),  // rewind
        Int64(kVK_F8),  // play/pause
        Int64(kVK_F11), // volume down
        Int64(kVK_F12), // volume up
    ]

    func isConflicting(_ keyCode: Int64) -> Bool {
        Self.conflictingKeyCodes.contains(keyCode)
    }

    // MARK: - Sound helpers

    func playBeep() {
        guard soundsEnabled else { return }
        NSSound.beep()
    }

    func playSuccess() {
        guard soundsEnabled else { return }
        if let s = NSSound(named: NSSound.Name("Tink")) {
            s.volume = soundVolume
            s.play()
        } else {
            NSSound.beep()
        }
    }

    func playCorrections() {
        guard soundsEnabled else { return }
        if let s = NSSound(named: NSSound.Name("Pop")) {
            s.volume = soundVolume
            s.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        defaults.removeObject(forKey: Key.primaryHotkey)
        defaults.removeObject(forKey: Key.soundsEnabled)
        defaults.removeObject(forKey: Key.soundVolume)
        defaults.removeObject(forKey: Key.spellCheckEnabledEnglish)
        defaults.removeObject(forKey: Key.spellCheckEnabledHebrew)
        defaults.removeObject(forKey: Key.errorFeedbackMode)
        // Keep the migration flag so we don't re-run migration on next init.
        // Explicitly fire the callback so GlobalHotkeyListener rebinds to F9
        // immediately without requiring an app restart.
        onHotkeyChanged?(Int64(kVK_F9))
    }
}
