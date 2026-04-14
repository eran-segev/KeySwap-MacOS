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
        return corrections[word]
    }
}

// MARK: - SpellCheckFilterTests

@Suite("SpellCheckFilter")
struct SpellCheckFilterTests {
    let filter = SpellCheckFilter()

    @Test("Hebrew target is a no-op — provider never called, empty corrections")
    func hebrewTargetNoOp() {
        let mock = MockCorrectionProvider(ranges: [NSRange(location: 0, length: 3)], corrections: ["teh": "the"])
        let result = filter.postProcess("teh something", language: .hebrew, provider: mock)
        #expect(result.corrected == "teh something")
        #expect(result.corrections.isEmpty)
        #expect(mock.misspelledCallCount == 0)
    }

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
        // Provider returns length-0 range immediately — no misspellings
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
        // Provider has a misspelled range but returns nil for correction
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
        // Provider flags a word but returns the same word as correction (edge case:
        // e.g., Hebrew name pre-learned at a different casing). Don't count as correction.
        let mock = MockCorrectionProvider(
            ranges: [NSRange(location: 0, length: 4)],
            corrections: ["Eran": "Eran"]
        )
        let result = filter.postProcess("Eran", language: .english, provider: mock)
        #expect(result.corrected == "Eran")
        #expect(result.corrections.isEmpty)
    }
}
