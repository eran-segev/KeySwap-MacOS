import AppKit
import TranslationContext

// MARK: - NSSpellCheckerProtocol
//
// Internal protocol that lets tests spy on the calls made to NSSpellChecker
// without standing up a real one. We ONLY expose the 7-argument overloads
// with explicit `language:` — the 2-argument short forms silently use
// `NSSpellChecker.shared.language` (mutable global state) and would route
// Hebrew text to whatever dictionary was last selected globally.
//
// IRON RULE: never bypass this protocol from production code paths.
// `correction(forWordRange:in:language:)` and `checkSpelling(of:startingAt:language:)`
// must always carry an explicit language. Adding new methods to this protocol
// requires the same discipline.

protocol NSSpellCheckerProtocol {
    func checkSpelling(of text: String, startingAt offset: Int, language: String) -> NSRange
    func correction(forWordRange range: NSRange, in text: String, language: String) -> String?
}

// MARK: - SystemSpellChecker
//
// Production implementation that talks to NSSpellChecker.shared via the
// 7-argument overloads. Always passes `language:` explicitly.

struct SystemSpellChecker: NSSpellCheckerProtocol {

    func checkSpelling(of text: String, startingAt offset: Int, language: String) -> NSRange {
        return NSSpellChecker.shared.checkSpelling(
            of: text,
            startingAt: offset,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
    }

    func correction(forWordRange range: NSRange, in text: String, language: String) -> String? {
        return NSSpellChecker.shared.correction(
            forWordRange: range,
            in: text,
            language: language,
            inSpellDocumentWithTag: 0
        )
    }
}

// MARK: - SingleLanguageSpellCheckerProvider
//
// CorrectionProvider implementation pinned to one language. Every call to
// the underlying NSSpellChecker carries the configured `languageCode`.
//
// The provider is parameterized by language, NOT by NSSpellChecker instance —
// `NSSpellChecker.shared` is a global singleton in AppKit. "Two providers,
// one shared checker" is discipline, not isolation. The discipline is enforced
// by the protocol above which has no short-form overload.

struct SingleLanguageSpellCheckerProvider: CorrectionProvider {

    let languageCode: String
    let checker: NSSpellCheckerProtocol

    init(languageCode: String, checker: NSSpellCheckerProtocol = SystemSpellChecker()) {
        self.languageCode = languageCode
        self.checker = checker
    }

    func misspelledRange(in text: String, startingAt offset: Int) -> NSRange {
        return checker.checkSpelling(of: text, startingAt: offset, language: languageCode)
    }

    func correction(forWord word: String, in text: String) -> String? {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.correction(forWordRange: range, in: word, language: languageCode)
    }
}

// MARK: - Spell-check gating decision
//
// Pure function over the 5 inputs that gate the post-swap spell-check pass.
// Extracted from `runSwapPipeline` so every combination can be unit-tested
// without standing up an AppKit pipeline. The four gates, in priority order:
//
//   1. Option+<hotkey> raw-swap override (skipSpellCheck) wins over everything
//   2. Per-language toggle off → skip silently
//   3. Hebrew target with dict missing → skip AND signal the missing-dict toast
//   4. Otherwise: run the language-matched provider
//
// Silent-routing bugs here would produce wrong-dictionary corrections or
// silent skips — the feedback_silent_mutations posture exists to prevent
// exactly this. Locking the decision under test so a regression trips CI.

enum SpellCheckDecision: Equatable {
    case skip
    case skipAndShowMissingDictToast
    case run(languageCode: String)
}

func spellCheckDecision(
    target: TargetLanguage,
    skipSpellCheck: Bool,
    englishEnabled: Bool,
    hebrewEnabled: Bool,
    hasHebrew: Bool
) -> SpellCheckDecision {
    if skipSpellCheck { return .skip }
    switch target {
    case .english:
        return englishEnabled ? .run(languageCode: "en") : .skip
    case .hebrew:
        guard hebrewEnabled else { return .skip }
        return hasHebrew ? .run(languageCode: "he") : .skipAndShowMissingDictToast
    }
}
