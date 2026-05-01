import Testing
import Foundation
import TranslationContext
@testable import KeySwap

// MARK: - SpyNSSpellChecker
//
// Records every call and the language argument passed. Lets the test assert
// that SingleLanguageSpellCheckerProvider always uses the 7-argument overload
// with explicit `language:` — never the 2-argument short form that silently
// reads NSSpellChecker.shared.language.

final class SpyNSSpellChecker: NSSpellCheckerProtocol, @unchecked Sendable {

    struct CheckSpellingCall: Equatable {
        let text: String
        let offset: Int
        let language: String
    }

    struct CorrectionCall: Equatable {
        let range: NSRange
        let text: String
        let language: String
    }

    var checkSpellingCalls: [CheckSpellingCall] = []
    var correctionCalls: [CorrectionCall] = []

    var rangeToReturn: NSRange = NSRange(location: 0, length: 0)
    var correctionsByWord: [String: String] = [:]

    func checkSpelling(of text: String, startingAt offset: Int, language: String) -> NSRange {
        checkSpellingCalls.append(.init(text: text, offset: offset, language: language))
        return rangeToReturn
    }

    func correction(forWordRange range: NSRange, in text: String, language: String) -> String? {
        correctionCalls.append(.init(range: range, text: text, language: language))
        return correctionsByWord[text]
    }
}

@Suite("SingleLanguageSpellCheckerProvider — language plumbing")
struct SpellCheckProviderTests {

    // MARK: - 7-arg overload regression
    //
    // The plan fixes a latent bug: the original NSSpellCheckerProvider used
    // the 2-arg `checkSpelling(of:startingAt:)` short form, which silently
    // routes through NSSpellChecker.shared.language (mutable global state).
    // These tests lock in that the new provider always passes `language:`.

    @Test("misspelledRange passes the configured languageCode")
    func misspelledRangeCarriesLanguage() {
        let spy = SpyNSSpellChecker()
        let provider = SingleLanguageSpellCheckerProvider(languageCode: "he", checker: spy)
        _ = provider.misspelledRange(in: "טקסט", startingAt: 0)
        #expect(spy.checkSpellingCalls.count == 1)
        #expect(spy.checkSpellingCalls.first?.language == "he")
    }

    @Test("correction passes the configured languageCode")
    func correctionCarriesLanguage() {
        let spy = SpyNSSpellChecker()
        spy.correctionsByWord = ["teh": "the"]
        let provider = SingleLanguageSpellCheckerProvider(languageCode: "en", checker: spy)
        let result = provider.correction(forWord: "teh", in: "teh")
        #expect(result == "the")
        #expect(spy.correctionCalls.count == 1)
        #expect(spy.correctionCalls.first?.language == "en")
    }

    @Test("Two providers (en + he) sharing a spy keep their language tags distinct")
    func twoProvidersTwoLanguages() {
        let spy = SpyNSSpellChecker()
        let en = SingleLanguageSpellCheckerProvider(languageCode: "en", checker: spy)
        let he = SingleLanguageSpellCheckerProvider(languageCode: "he", checker: spy)

        _ = en.misspelledRange(in: "teh", startingAt: 0)
        _ = he.misspelledRange(in: "בית", startingAt: 0)

        #expect(spy.checkSpellingCalls.count == 2)
        #expect(spy.checkSpellingCalls[0].language == "en")
        #expect(spy.checkSpellingCalls[1].language == "he")
    }

    @Test("misspelledRange returns whatever the checker returns")
    func misspelledRangeReturnsCheckerResult() {
        let spy = SpyNSSpellChecker()
        spy.rangeToReturn = NSRange(location: 4, length: 3)
        let provider = SingleLanguageSpellCheckerProvider(languageCode: "en", checker: spy)
        let r = provider.misspelledRange(in: "foo bar baz", startingAt: 0)
        #expect(r == NSRange(location: 4, length: 3))
    }

    @Test("correction returns nil when checker has no suggestion")
    func correctionReturnsNilWhenAbsent() {
        let spy = SpyNSSpellChecker()
        let provider = SingleLanguageSpellCheckerProvider(languageCode: "he", checker: spy)
        let r = provider.correction(forWord: "בית", in: "בית")
        #expect(r == nil)
    }
}

// MARK: - SpellCheckAvailability decision helper

@Suite("SpellCheckAvailability — toast contract")
struct SpellCheckAvailabilityDecisionTests {

    @Test("Toast fires when dict missing AND not yet acknowledged")
    func toastFiresWhenMissingAndUnacknowledged() {
        #expect(SpellCheckAvailability.shouldShowMissingDictToast(hasHebrew: false, acknowledged: false) == true)
    }

    @Test("Toast suppressed once user acknowledges")
    func toastSuppressedAfterAck() {
        #expect(SpellCheckAvailability.shouldShowMissingDictToast(hasHebrew: false, acknowledged: true) == false)
    }

    @Test("Toast never fires when dict is present")
    func toastNeverFiresWhenDictPresent() {
        #expect(SpellCheckAvailability.shouldShowMissingDictToast(hasHebrew: true, acknowledged: false) == false)
        #expect(SpellCheckAvailability.shouldShowMissingDictToast(hasHebrew: true, acknowledged: true) == false)
    }
}

// MARK: - Gating decision helper

@Suite("spellCheckDecision — gating matrix")
struct SpellCheckDecisionTests {

    // MARK: - Option+hotkey raw-swap override wins over everything

    @Test("Option+F9 raw wins over English toggle=on")
    func rawOverrideBeatsEnglishOn() {
        let d = spellCheckDecision(
            target: .english, skipSpellCheck: true,
            englishEnabled: true, hebrewEnabled: true, hasHebrew: true
        )
        #expect(d == .skip)
    }

    @Test("Option+F9 raw wins over Hebrew toggle=on (dict present)")
    func rawOverrideBeatsHebrewOn() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: true,
            englishEnabled: true, hebrewEnabled: true, hasHebrew: true
        )
        #expect(d == .skip)
    }

    @Test("Option+F9 raw: never shows missing-dict toast, even when Hebrew dict missing")
    func rawOverrideSuppressesMissingDictToast() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: true,
            englishEnabled: true, hebrewEnabled: true, hasHebrew: false
        )
        #expect(d == .skip)
    }

    // MARK: - Per-language toggle off → skip silently

    @Test("English target, toggle off → skip")
    func englishToggleOff() {
        let d = spellCheckDecision(
            target: .english, skipSpellCheck: false,
            englishEnabled: false, hebrewEnabled: true, hasHebrew: true
        )
        #expect(d == .skip)
    }

    @Test("Hebrew target, toggle off, dict present → skip (no toast)")
    func hebrewToggleOffDictPresent() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: false,
            englishEnabled: true, hebrewEnabled: false, hasHebrew: true
        )
        #expect(d == .skip)
    }

    @Test("Hebrew target, toggle off, dict missing → skip (no toast — user chose off)")
    func hebrewToggleOffDictMissing() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: false,
            englishEnabled: true, hebrewEnabled: false, hasHebrew: false
        )
        #expect(d == .skip)
    }

    // MARK: - Hebrew target, toggle on, dict missing → toast

    @Test("Hebrew target, toggle on, dict missing → skipAndShowMissingDictToast")
    func hebrewToggleOnDictMissing() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: false,
            englishEnabled: true, hebrewEnabled: true, hasHebrew: false
        )
        #expect(d == .skipAndShowMissingDictToast)
    }

    // MARK: - Run paths

    @Test("English target, toggle on → run with languageCode=\"en\"")
    func englishRun() {
        let d = spellCheckDecision(
            target: .english, skipSpellCheck: false,
            englishEnabled: true, hebrewEnabled: false, hasHebrew: true
        )
        #expect(d == .run(languageCode: "en"))
    }

    @Test("Hebrew target, toggle on, dict present → run with languageCode=\"he\"")
    func hebrewRun() {
        let d = spellCheckDecision(
            target: .hebrew, skipSpellCheck: false,
            englishEnabled: false, hebrewEnabled: true, hasHebrew: true
        )
        #expect(d == .run(languageCode: "he"))
    }

    // MARK: - Independence: one language's toggle doesn't affect the other

    @Test("English target ignores Hebrew toggle state")
    func englishIgnoresHebrewToggle() {
        let d1 = spellCheckDecision(target: .english, skipSpellCheck: false, englishEnabled: true, hebrewEnabled: false, hasHebrew: false)
        let d2 = spellCheckDecision(target: .english, skipSpellCheck: false, englishEnabled: true, hebrewEnabled: true, hasHebrew: true)
        #expect(d1 == .run(languageCode: "en"))
        #expect(d2 == .run(languageCode: "en"))
    }

    @Test("Hebrew target ignores English toggle state")
    func hebrewIgnoresEnglishToggle() {
        let d1 = spellCheckDecision(target: .hebrew, skipSpellCheck: false, englishEnabled: false, hebrewEnabled: true, hasHebrew: true)
        let d2 = spellCheckDecision(target: .hebrew, skipSpellCheck: false, englishEnabled: true, hebrewEnabled: true, hasHebrew: true)
        #expect(d1 == .run(languageCode: "he"))
        #expect(d2 == .run(languageCode: "he"))
    }
}
