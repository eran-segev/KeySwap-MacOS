import Foundation

// MARK: - CorrectionProvider

/// Protocol covering both range-finding and word correction.
/// Keeps NSSpellChecker (AppKit) entirely in the app layer — this package never imports AppKit.
public protocol CorrectionProvider {
    /// Returns the NSRange of the first misspelled word in `text` starting at `offset`.
    /// NSRange.length == 0 means no misspelling found from that offset.
    func misspelledRange(in text: String, startingAt offset: Int) -> NSRange

    /// Returns the top correction for `word`, or nil if no correction is available.
    func correction(forWord word: String, in text: String) -> String?
}

// MARK: - Correction

/// A single correction applied during post-processing. All ranges are against
/// the ORIGINAL input string, not the post-correction result — this is what
/// a UI needs to show the user what changed and to revert it.
public struct Correction: Equatable {
    public let originalWord: String
    public let replacementWord: String
    public let rangeInOriginal: NSRange

    public init(originalWord: String, replacementWord: String, rangeInOriginal: NSRange) {
        self.originalWord = originalWord
        self.replacementWord = replacementWord
        self.rangeInOriginal = rangeInOriginal
    }
}

// MARK: - SpellCheckResult

/// Result of spell-checking a string: the corrected output plus the list
/// of individual corrections applied, ordered by ascending range location.
public struct SpellCheckResult: Equatable {
    public let corrected: String
    public let corrections: [Correction]

    public init(corrected: String, corrections: [Correction]) {
        self.corrected = corrected
        self.corrections = corrections
    }

    /// Convenience: true when no corrections were applied.
    public var isEmpty: Bool { corrections.isEmpty }
}

// MARK: - SpellCheckFilter

public struct SpellCheckFilter {

    public init() {}

    /// Corrects misspelled words in `text` using the given provider.
    /// Only runs for `.english` target — Hebrew output is returned unchanged
    /// with an empty corrections array.
    public func postProcess(_ text: String, language: TargetLanguage, provider: CorrectionProvider) -> SpellCheckResult {
        guard language == .english else {
            return SpellCheckResult(corrected: text, corrections: [])
        }
        guard !text.isEmpty else {
            return SpellCheckResult(corrected: text, corrections: [])
        }

        // Phase 1: Collect all misspelled ranges from the original string.
        var ranges: [NSRange] = []
        var offset = 0
        while offset < text.utf16.count {
            let range = provider.misspelledRange(in: text, startingAt: offset)
            guard range.length > 0 else { break }
            let nextOffset = range.location + range.length
            guard nextOffset > offset else { break } // infinite-loop guard: provider must advance
            ranges.append(range)
            offset = nextOffset
        }

        guard !ranges.isEmpty else {
            return SpellCheckResult(corrected: text, corrections: [])
        }

        // Phase 2: Apply corrections back-to-front so earlier NSRange positions
        // are unaffected by variable-length replacements. Track each applied
        // correction against the ORIGINAL string so the UI can show an accurate diff.
        var result = text
        var applied: [Correction] = []
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            // Guard against stale ranges — the original-string range must still
            // be in-bounds for the current working string (true for all corrections
            // we've applied so far since they're ordered back-to-front).
            guard range.location + range.length <= result.utf16.count else { continue }
            let word = (result as NSString).substring(with: range)
            if let correction = provider.correction(forWord: word, in: result), correction != word {
                result = (result as NSString).replacingCharacters(in: range, with: correction)
                applied.append(Correction(
                    originalWord: word,
                    replacementWord: correction,
                    rangeInOriginal: range
                ))
            }
        }

        // Order corrections by ascending range location for display purposes.
        applied.sort { $0.rangeInOriginal.location < $1.rangeInOriginal.location }
        return SpellCheckResult(corrected: result, corrections: applied)
    }
}
