import Testing
import Carbon
@testable import KeySwap

@Suite("AppSettings")
@MainActor
struct AppSettingsTests {

    // Per-test UserDefaults suite keeps tests from touching the real user's
    // KeySwap prefs. The test host IS KeySwap.app, so `.standard` would
    // otherwise read/write the developer's actual saved settings.
    private func makeSettings() -> (AppSettings, String) {
        let suiteName = "KeySwapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let s = AppSettings(defaults: defaults)
        return (s, suiteName)
    }

    private func makeSuite() -> (UserDefaults, String) {
        let suiteName = "KeySwapTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    private func cleanup(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default values

    @Test("Default primaryHotkey is F9")
    func defaultHotkey() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.primaryHotkey == Int64(kVK_F9))
    }

    @Test("Default soundsEnabled is true")
    func defaultSoundsEnabled() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.soundsEnabled == true)
    }

    @Test("Default soundVolume is 0.8")
    func defaultSoundVolume() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(abs(s.soundVolume - 0.8) < 0.001)
    }

    @Test("Default spellCheckEnabledEnglish is true")
    func defaultSpellCheckEnabledEnglish() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.spellCheckEnabledEnglish == true)
    }

    @Test("Default spellCheckEnabledHebrew is true")
    func defaultSpellCheckEnabledHebrew() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.spellCheckEnabledHebrew == true)
    }

    @Test("Default errorFeedbackMode is .toast")
    func defaultErrorFeedbackMode() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.errorFeedbackMode == .toast)
    }

    // MARK: - Write and read back

    @Test("primaryHotkey persists across reads")
    func hotkeyPersistence() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.primaryHotkey = Int64(kVK_F5)
        #expect(s.primaryHotkey == Int64(kVK_F5))
    }

    @Test("soundsEnabled persists false")
    func soundsEnabledPersistence() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.soundsEnabled = false
        #expect(s.soundsEnabled == false)
    }

    @Test("soundVolume clamps to 0.0-1.0")
    func soundVolumeClamping() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.soundVolume = 1.5
        #expect(s.soundVolume <= 1.0)
        s.soundVolume = -0.5
        #expect(s.soundVolume >= 0.0)
    }

    @Test("spellCheckEnabledEnglish persists false")
    func spellCheckEnabledEnglishPersistence() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.spellCheckEnabledEnglish = false
        #expect(s.spellCheckEnabledEnglish == false)
    }

    @Test("spellCheckEnabledHebrew persists false")
    func spellCheckEnabledHebrewPersistence() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.spellCheckEnabledHebrew = false
        #expect(s.spellCheckEnabledHebrew == false)
    }

    @Test("Toggling Hebrew off does not affect English")
    func togglesAreIndependent() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.spellCheckEnabledHebrew = false
        #expect(s.spellCheckEnabledEnglish == true)
        s.spellCheckEnabledHebrew = true
        s.spellCheckEnabledEnglish = false
        #expect(s.spellCheckEnabledHebrew == true)
    }

    @Test("errorFeedbackMode persists .silent")
    func errorFeedbackModePersistence() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.errorFeedbackMode = .silent
        #expect(s.errorFeedbackMode == .silent)
    }

    // MARK: - v1.2 → v1.3 migration

    @Test("Migration: legacy=true, fresh install — both new keys become true, legacy deleted")
    func migrationLegacyTrue() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        defaults.set(true, forKey: "spellCheckEnabled")
        let s = AppSettings(defaults: defaults)
        #expect(s.spellCheckEnabledEnglish == true)
        #expect(s.spellCheckEnabledHebrew == true)
        #expect(defaults.object(forKey: "spellCheckEnabled") == nil)
        #expect(defaults.bool(forKey: "didMigrateSpellCheck_v1_3") == true)
    }

    @Test("Migration: legacy=false — both new keys become false, legacy deleted")
    func migrationLegacyFalse() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        defaults.set(false, forKey: "spellCheckEnabled")
        let s = AppSettings(defaults: defaults)
        #expect(s.spellCheckEnabledEnglish == false)
        #expect(s.spellCheckEnabledHebrew == false)
        #expect(defaults.object(forKey: "spellCheckEnabled") == nil)
    }

    @Test("Migration: no legacy key — both new keys default true, no migration churn")
    func migrationNoLegacy() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        let s = AppSettings(defaults: defaults)
        #expect(s.spellCheckEnabledEnglish == true)
        #expect(s.spellCheckEnabledHebrew == true)
        #expect(defaults.bool(forKey: "didMigrateSpellCheck_v1_3") == true)
    }

    @Test("Migration: defensive — legacy AND new keys both present, new keys preserved")
    func migrationPreservesExistingNewKeys() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        defaults.set(true, forKey: "spellCheckEnabled")
        defaults.set(false, forKey: "spellCheckEnabledEnglish")
        defaults.set(false, forKey: "spellCheckEnabledHebrew")
        let s = AppSettings(defaults: defaults)
        // Defensive guard: don't clobber existing new keys.
        #expect(s.spellCheckEnabledEnglish == false)
        #expect(s.spellCheckEnabledHebrew == false)
        #expect(defaults.object(forKey: "spellCheckEnabled") == nil)
    }

    @Test("Migration idempotency: second init is a no-op")
    func migrationIdempotent() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        defaults.set(true, forKey: "spellCheckEnabled")
        _ = AppSettings(defaults: defaults)
        // After first init: both new keys=true, legacy gone, flag set.
        // Now flip a new key, then init again — migration should not fire.
        defaults.set(false, forKey: "spellCheckEnabledEnglish")
        let s2 = AppSettings(defaults: defaults)
        // English should remain false (migration did not re-run and re-copy).
        #expect(s2.spellCheckEnabledEnglish == false)
        #expect(s2.spellCheckEnabledHebrew == true)
    }

    @Test("Migration idempotency: re-introducing legacy key after migration is ignored")
    func migrationIgnoresLegacyAfterFlagSet() {
        let (defaults, suite) = makeSuite()
        defer { cleanup(suite) }
        // Pretend a previous migration already ran.
        defaults.set(true, forKey: "didMigrateSpellCheck_v1_3")
        // Drop a legacy key in (e.g., from a v1.2 downgrade).
        defaults.set(false, forKey: "spellCheckEnabled")
        let s = AppSettings(defaults: defaults)
        // Migration must not re-run: new keys should be defaults (true), legacy stays untouched.
        #expect(s.spellCheckEnabledEnglish == true)
        #expect(s.spellCheckEnabledHebrew == true)
        #expect(defaults.object(forKey: "spellCheckEnabled") != nil)
    }

    // MARK: - resetToDefaults

    @Test("resetToDefaults restores all defaults and fires onHotkeyChanged")
    func resetToDefaults() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }

        // Change everything
        s.primaryHotkey = Int64(kVK_F5)
        s.soundsEnabled = false
        s.soundVolume = 0.3
        s.spellCheckEnabledEnglish = false
        s.spellCheckEnabledHebrew = false
        s.errorFeedbackMode = .silent

        // Track callback
        var callbackCode: Int64?
        s.onHotkeyChanged = { code in callbackCode = code }

        s.resetToDefaults()

        #expect(s.primaryHotkey == Int64(kVK_F9))
        #expect(s.soundsEnabled == true)
        #expect(abs(s.soundVolume - 0.8) < 0.001)
        #expect(s.spellCheckEnabledEnglish == true)
        #expect(s.spellCheckEnabledHebrew == true)
        #expect(s.errorFeedbackMode == .toast)
        #expect(callbackCode == Int64(kVK_F9))
    }

    // MARK: - primaryHotkeyDisplayName

    @Test("F1-F19 display names are correct")
    func displayNames() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }

        let expectedPairs: [(Int64, String)] = [
            (Int64(kVK_F1), "F1"), (Int64(kVK_F2), "F2"), (Int64(kVK_F3), "F3"),
            (Int64(kVK_F4), "F4"), (Int64(kVK_F5), "F5"), (Int64(kVK_F6), "F6"),
            (Int64(kVK_F7), "F7"), (Int64(kVK_F8), "F8"), (Int64(kVK_F9), "F9"),
            (Int64(kVK_F10), "F10"), (Int64(kVK_F11), "F11"), (Int64(kVK_F12), "F12"),
            (Int64(kVK_F13), "F13"), (Int64(kVK_F14), "F14"), (Int64(kVK_F15), "F15"),
            (Int64(kVK_F16), "F16"), (Int64(kVK_F17), "F17"), (Int64(kVK_F18), "F18"),
            (Int64(kVK_F19), "F19"),
        ]

        for (code, expected) in expectedPairs {
            s.primaryHotkey = code
            #expect(s.primaryHotkeyDisplayName == expected)
        }
    }

    @Test("Unknown keycode returns F9 as fallback")
    func unknownKeycodeDisplayName() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        // Write an invalid keycode into the isolated suite to verify the fallback.
        UserDefaults(suiteName: suite)!.set(Int64(999), forKey: "primaryHotkey")
        #expect(s.primaryHotkeyDisplayName == "F9")
    }

    // MARK: - Sound guards

    @Test("playBeep does not crash when sounds disabled")
    func playBeepWhenDisabled() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.soundsEnabled = false
        // Should be a no-op, not crash
        s.playBeep()
    }

    @Test("playSuccess does not crash when sounds disabled")
    func playSuccessWhenDisabled() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.soundsEnabled = false
        s.playSuccess()
    }

    @Test("playCorrections does not crash when sounds disabled")
    func playCorrectionsWhenDisabled() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        s.soundsEnabled = false
        s.playCorrections()
    }

    // MARK: - Conflict detection

    @Test("F7, F8, F11, F12 are conflicting")
    func conflictingKeys() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        #expect(s.isConflicting(Int64(kVK_F7)) == true)
        #expect(s.isConflicting(Int64(kVK_F8)) == true)
        #expect(s.isConflicting(Int64(kVK_F11)) == true)
        #expect(s.isConflicting(Int64(kVK_F12)) == true)
    }

    @Test("F1-F6, F9, F10, F13-F19 are not conflicting")
    func nonConflictingKeys() {
        let (s, suite) = makeSettings()
        defer { cleanup(suite) }
        let safe: [Int64] = [
            Int64(kVK_F1), Int64(kVK_F2), Int64(kVK_F3), Int64(kVK_F4),
            Int64(kVK_F5), Int64(kVK_F6), Int64(kVK_F9), Int64(kVK_F10),
            Int64(kVK_F13), Int64(kVK_F14), Int64(kVK_F15), Int64(kVK_F16),
            Int64(kVK_F17), Int64(kVK_F18), Int64(kVK_F19),
        ]
        for code in safe {
            #expect(s.isConflicting(code) == false)
        }
    }
}
