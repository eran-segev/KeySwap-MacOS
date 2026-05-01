import AppKit

// MARK: - SpellCheckAvailability
//
// Runtime-only singleton tracking which spell-check dictionaries are present
// on this Mac, plus session-only UX state for the missing-Hebrew-dict toast.
//
// @MainActor: matches AppSettings. NSSpellChecker.shared is AppKit and reads
// here come from both launch (applicationDidFinishLaunching) and the swap
// pipeline (which runs on main after AX events). The annotation gives
// compile-time enforcement.
//
// Why a separate file (not on AppSettings or AppState):
//   - AppSettings is a pure UserDefaults wrapper. Runtime state belongs elsewhere.
//   - AppState already holds permissions + pendingRevert; adding dict availability
//     would bloat its responsibility scope.
//
// `hasUserAcknowledgedMissing` is intentionally NOT UserDefaults-backed.
// Returning users see the install prompt again on next launch until they
// install the dictionary.

@MainActor
final class SpellCheckAvailability {

    static let shared = SpellCheckAvailability()

    private(set) var hasHebrew: Bool = false

    /// Session-only flag. Set to `true` when the user clicks the missing-dict
    /// toast or dismisses it via the X button. Resets to `false` on next launch
    /// (singleton recreated only on process start).
    var hasUserAcknowledgedMissing: Bool = false

    private init() {}

    /// Probes `NSSpellChecker.shared.availableLanguages` and caches the result.
    /// Idempotent — safe to call multiple times. Matches both bare `"he"` and
    /// locale variants like `"he_IL"`.
    func detect() {
        let langs = NSSpellChecker.shared.availableLanguages
        hasHebrew = langs.contains(where: { $0 == "he" || $0.hasPrefix("he_") })
        #if DEBUG
        print("[HebrewSpellCheck] dict available: \(hasHebrew ? "Y" : "N") (langs=\(langs))")
        #endif
    }

    // MARK: - Toast contract decision helper (test-locked per Eng Review 3B)
    //
    // Returns true when the missing-Hebrew-dict toast should fire on the
    // current Hebrew swap. Pure function over (hasHebrew, acknowledged) so
    // it can be unit-tested without mocking NSSpellChecker or the HUD.

    nonisolated static func shouldShowMissingDictToast(hasHebrew: Bool, acknowledged: Bool) -> Bool {
        return !hasHebrew && !acknowledged
    }
}
