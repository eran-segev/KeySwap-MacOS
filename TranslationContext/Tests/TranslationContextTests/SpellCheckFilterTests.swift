import Testing
import Foundation
@testable import TranslationContext

// MARK: - MockCorrectionProvider
//
// Must be a class (not struct) so it can track state between protocol method calls
// without requiring `mutating`. Holds a queue of NSRange values popped sequentially
// and a corrections dictionary keyed by misspelled word.

final class MockCorrectionProvider: CorrectionProvider {
    private var rangeQueue: [NSRange]
    private let corrections: [String: String]
    private(set) var misspelledCallCount = 0
    private(set) var correctionCallWords: [String] = []

    init(ranges: [NSRange] = [], corrections: [String: String] = [:]) {
        self.rangeQueue = ranges
        self.corrections = corrections
    }

    func misspelledRange(in text: String, startingAt offset: Int) -> NSRange {
        misspelledCallCount += 1
        if rangeQueue.isEmpty {
            return NSRange(location: 0, length: 0)
        }
        return rangeQueue.removeFirst()
    }

    func correction(forWord word: String, in text: String) -> String? {
        correctionCallWords.append(word)
        return corrections[word]
    }
}

// MARK: - SpellCheckFilterTests (English mirror — historical coverage)

@Suite("SpellCheckFilter — English")
struct SpellCheckFilterEnglishTests {
    let filter = SpellCheckFilter()

    @Test("Empty string returns empty — provider never called, empty corrections")
    func emptyStringFastPath() {
        let mock = MockCorrectionProvider()
        let result = filter.postProcess("", language: .english, provider: mock)
        #expect(result.corrected == "")
        #expect(result.corrections.isEmpty)
        #expect(mock.misspelledCallCount == 0)
    }

    @Test("No misspellings — fast path, string unchanged, empty corrections")
    func noMisspellingsFastPath() {
        let mock = MockCorrectionProvider(ranges: [], corrections: [:])
        let result = filter.postProcess("hello world", language: .english, provider: mock)
        #expect(result.corrected == "hello world")
        #expect(result.corrections.isEmpty)
    }

    @Test("Single misspelling, same-length correction — range tracks original string")
    func singleMisspellingSameLength() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 3)],
            corrections: ["teh": "the"]
        )
        let result = filter.postProcess("teh", language: .english, provider: mock)
        #expect(result.corrected == "the")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].originalWord == "teh")
        #expect(result.corrections[0].replacementWord == "the")
        #expect(result.corrections[0].rangeInOriginal == NSRange(location: 0, length: 3))
    }

    @Test("Single misspelling, longer correction — correction recorded, range against original")
    func singleMisspellingLongerCorrection() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 7)],
            corrections: ["recieve": "receive"]
        )
        let result = filter.postProcess("recieve", language: .english, provider: mock)
        #expect(result.corrected == "receive")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].originalWord == "recieve")
        #expect(result.corrections[0].replacementWord == "receive")
        #expect(result.corrections[0].rangeInOriginal == NSRange(location: 0, length: 7))
    }

    @Test("Multiple misspellings — back-to-front ordering preserves indices (CRITICAL)")
    func multiMisspellingBackToFront() {
        // "teh recieve foo" — two corrections of different lengths.
        // Proves that correcting "recieve"→"receive" first (back-to-front)
        // does not corrupt the NSRange for "teh" at location 0.
        let mock = MockCorrectionProvider(
            ranges: [
                NSRange(location: 0, length: 3),  // "teh"
                NSRange(location: 4, length: 7)   // "recieve"
            ],
            corrections: ["teh": "the", "recieve": "receive"]
        )
        let result = filter.postProcess("teh recieve foo", language: .english, provider: mock)
        #expect(result.corrected == "the receive foo")
        #expect(result.corrections.count == 2)
        // Corrections sorted ascending by location
        #expect(result.corrections[0].originalWord == "teh")
        #expect(result.corrections[0].rangeInOriginal == NSRange(location: 0, length: 3))
        #expect(result.corrections[1].originalWord == "recieve")
        #expect(result.corrections[1].rangeInOriginal == NSRange(location: 4, length: 7))
    }

    @Test("No correction available — word left unchanged, corrections array empty")
    func noCorrectionAvailable() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 3)],
            corrections: [:]  // empty — correction(forWord:) returns nil
        )
        let result = filter.postProcess("teh", language: .english, provider: mock)
        #expect(result.corrected == "teh")
        #expect(result.corrections.isEmpty)
    }

    @Test("Correction identical to input — not recorded as a correction")
    func correctionEqualToOriginalIsSkipped() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 4)],
            corrections: ["Eran": "Eran"]
        )
        let result = filter.postProcess("Eran", language: .english, provider: mock)
        #expect(result.corrected == "Eran")
        #expect(result.corrections.isEmpty)
    }
}

// MARK: - SpellCheckFilterTests (Hebrew mirror)

@Suite("SpellCheckFilter — Hebrew")
struct SpellCheckFilterHebrewTests {
    let filter = SpellCheckFilter()

    @Test("Empty string returns empty (Hebrew target) — provider never called")
    func emptyStringFastPathHebrew() {
        let mock = MockCorrectionProvider()
        let result = filter.postProcess("", language: .hebrew, provider: mock)
        #expect(result.corrected == "")
        #expect(result.corrections.isEmpty)
        #expect(mock.misspelledCallCount == 0)
    }

    @Test("No misspellings (Hebrew) — fast path, string unchanged")
    func noMisspellingsHebrew() {
        let mock = MockCorrectionProvider(ranges: [], corrections: [:])
        let result = filter.postProcess("שלום עולם", language: .hebrew, provider: mock)
        #expect(result.corrected == "שלום עולם")
        #expect(result.corrections.isEmpty)
    }

    @Test("Single Hebrew misspelling — correction applied, range against original")
    func singleHebrewMisspelling() {
        // NSRange uses UTF16 units. "בית" is 3 Hebrew characters = 3 UTF16 units.
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 3)],
            corrections: ["בית": "ביתו"]
        )
        let result = filter.postProcess("בית", language: .hebrew, provider: mock)
        #expect(result.corrected == "ביתו")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].originalWord == "בית")
        #expect(result.corrections[0].replacementWord == "ביתו")
    }

    @Test("Multiple Hebrew misspellings — back-to-front ordering preserves indices")
    func multiHebrewMisspellingBackToFront() {
        // Source: "שלום עולם" (5 + 1 + 4 = 10 UTF16 units). Hebrew letters are
        // each 1 UTF16 unit (BMP). "שלום" at location 0 length 4, "עולם" at
        // location 5 length 4. Corrections of different lengths exercise the
        // back-to-front guarantee.
        let source = "שלום עולם"
        let mock = MockCorrectionProvider(
            ranges: [
                NSRange(location: 0, length: 4),
                NSRange(location: 5, length: 4)
            ],
            corrections: ["שלום": "שלומות", "עולם": "עולמות"]
        )
        let result = filter.postProcess(source, language: .hebrew, provider: mock)
        #expect(result.corrected == "שלומות עולמות")
        #expect(result.corrections.count == 2)
        #expect(result.corrections[0].originalWord == "שלום")
        #expect(result.corrections[1].originalWord == "עולם")
    }

    @Test("Hebrew correction identical to input — not recorded")
    func hebrewCorrectionEqualToOriginalIsSkipped() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 3)],
            corrections: ["בית": "בית"]
        )
        let result = filter.postProcess("בית", language: .hebrew, provider: mock)
        #expect(result.corrected == "בית")
        #expect(result.corrections.isEmpty)
    }

    @Test("No correction available (Hebrew) — word left unchanged")
    func hebrewNoCorrectionAvailable() {
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 3)],
            corrections: [:]
        )
        let result = filter.postProcess("בית", language: .hebrew, provider: mock)
        #expect(result.corrected == "בית")
        #expect(result.corrections.isEmpty)
    }
}

// MARK: - Script-aware token filter tests

@Suite("SpellCheckFilter — script-aware token filter")
struct SpellCheckFilterScriptTests {
    let filter = SpellCheckFilter()

    @Test("Hebrew target: embedded English brand word is skipped, no correction call")
    func hebrewTargetSkipsEnglishToken() {
        // Source: "שלחתי Gmail" — provider would flag "Gmail" but it's English,
        // not Hebrew. The script filter must skip it: no correction call emitted.
        let source = "שלחתי Gmail"
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 6, length: 5)], // "Gmail" at UTF16 offset 6
            corrections: ["Gmail": "Gemail"]
        )
        let result = filter.postProcess(source, language: .hebrew, provider: mock)
        #expect(result.corrected == "שלחתי Gmail")
        #expect(result.corrections.isEmpty)
        #expect(mock.correctionCallWords.isEmpty)
    }

    @Test("English target: embedded Hebrew word is skipped, no correction call")
    func englishTargetSkipsHebrewToken() {
        // Source: "I visit ירושלים" — provider would flag "ירושלים" but it's
        // Hebrew, not English. Skip.
        let source = "I visit ירושלים"
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 8, length: 7)], // "ירושלים" at UTF16 offset 8
            corrections: ["ירושלים": "ירושלם"]
        )
        let result = filter.postProcess(source, language: .english, provider: mock)
        #expect(result.corrected == "I visit ירושלים")
        #expect(result.corrections.isEmpty)
        #expect(mock.correctionCallWords.isEmpty)
    }

    @Test("Mixed paragraph: matching-script words are corrected, foreign skipped")
    func mixedParagraphSelectiveCorrection() {
        // Source: "teh ירושלים foo" with English target.
        // "teh"@0 length 3 → English, gets corrected.
        // "ירושלים"@4 length 7 → Hebrew, skipped.
        // "foo"@12 length 3 → no misspelling provided.
        let source = "teh ירושלים foo"
        let mock = MockCorrectionProvider(
            ranges: [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 7),
            ],
            corrections: ["teh": "the", "ירושלים": "ירושלם"]
        )
        let result = filter.postProcess(source, language: .english, provider: mock)
        #expect(result.corrected == "the ירושלים foo")
        #expect(result.corrections.count == 1)
        #expect(result.corrections[0].originalWord == "teh")
        // Hebrew word never reached the correction call.
        #expect(mock.correctionCallWords == ["teh"])
    }

    @Test("matchesScript: pure Hebrew word matches Hebrew, not English")
    func matchesScriptHebrewWord() {
        #expect(SpellCheckFilter.matchesScript("בית", for: .hebrew) == true)
        #expect(SpellCheckFilter.matchesScript("בית", for: .english) == false)
    }

    @Test("matchesScript: pure English word matches English, not Hebrew")
    func matchesScriptEnglishWord() {
        #expect(SpellCheckFilter.matchesScript("hello", for: .english) == true)
        #expect(SpellCheckFilter.matchesScript("hello", for: .hebrew) == false)
    }

    @Test("matchesScript: numeric/punctuation token matches neither")
    func matchesScriptNonScriptToken() {
        #expect(SpellCheckFilter.matchesScript("12345", for: .english) == false)
        #expect(SpellCheckFilter.matchesScript("12345", for: .hebrew) == false)
        #expect(SpellCheckFilter.matchesScript("---", for: .english) == false)
    }

    @Test("matchesScript: mixed Hebrew+English token matches both")
    func matchesScriptMixedToken() {
        // A token like "Yair-יאיר" has at least one char in each script —
        // matches when EITHER target is requested. Caller's script-routing
        // policy handles whether to actually correct.
        #expect(SpellCheckFilter.matchesScript("Yair-יאיר", for: .english) == true)
        #expect(SpellCheckFilter.matchesScript("Yair-יאיר", for: .hebrew) == true)
    }
}
