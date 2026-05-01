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

    /// Corrects misspelled words in `text` using the given provider, gated on
    /// the target language's expected script block (script-aware token filter).
    /// The caller must pass a language-matched provider (e.g. an English
    /// provider for `.english`, a Hebrew provider for `.hebrew`). Tokens whose
    /// characters do not match the target script (e.g. an English brand name
    /// inside a Hebrew paragraph) are skipped — the wrong-language dictionary
    /// would only emit garbage suggestions for them.
    public func postProcess(_ text: String, language: TargetLanguage, provider: CorrectionProvider) -> SpellCheckResult {
        guard !text.isEmpty else {
            return SpellCheckResult(corrected: text, corrections: [])
        }

        // Phase 1: Collect all misspelled ranges from the original string,
        // rejecting any range whose characters do not fall within the target
        // language's script block. Rejecting in Phase 1 keeps Phase 2 simple
        // and avoids wasted provider.correction() calls.
        var ranges: [NSRange] = []
        var offset = 0
        while offset < text.utf16.count {
            let range = provider.misspelledRange(in: text, startingAt: offset)
            guard range.length > 0 else { break }
            let nextOffset = range.location + range.length
            guard nextOffset > offset else { break } // infinite-loop guard: provider must advance

            let nsText = text as NSString
            let word = nsText.substring(with: range)
            if Self.matchesScript(word, for: language) {
                ranges.append(range)
            }
            // Always advance past the range, whether kept or skipped, so the
            // next iteration looks for misspellings BEYOND this token.
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

    // MARK: - Script-aware token filter
    //
    // Returns true when the word contains at least one character in the
    // expected Unicode block for `language`. This keeps the wrong-language
    // dictionary from emitting garbage suggestions for embedded foreign words
    // (e.g., "Gmail" inside a Hebrew paragraph; "ירושלים" inside an English one).

    static func matchesScript(_ word: String, for language: TargetLanguage) -> Bool {
        switch language {
        case .english:
            return word.unicodeScalars.contains { isBasicLatinLetter($0) }
        case .hebrew:
            return word.unicodeScalars.contains { isHebrewLetter($0) }
        }
    }

    private static func isBasicLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // U+0041–U+005A (A-Z), U+0061–U+007A (a-z)
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    private static func isHebrewLetter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // U+0590–U+05FF Hebrew block (letters + cantillation marks + nikud)
        return (0x0590...0x05FF).contains(v)
    }
}
