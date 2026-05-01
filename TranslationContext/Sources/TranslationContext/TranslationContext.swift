import Foundation

// TRANSLATION PIPELINE
// ====================
//
// INPUT: raw text + targetLanguage + fallbackMacroUsed
//
// PHASE 1: Per-character translation
//   For each character in input:
//     ┌── Rule 0 (gate): target == .hebrew? → skip Rules 1-3, use standard Hebrew output
//     ├── Rule 1: input char is [A-Z]? → output [A-Z] (preserve explicit caps)
//     └── Rule 4: otherwise → lowercase English (default)
//     Map character via bidirectional lookup table
//
// PHASE 2: Post-translation fixups (target == .english only)
//     Rule 2: fallbackMacroUsed? → capitalize first non-whitespace [a-z] in output
//     Rule 3: regex (?<=[.!?]\s)[a-z] → [A-Z] (capitalize after sentence enders)
//
// PHASE 3: Cleanup
//     Strip RTL/LTR direction markers: \u200F \u200E \u202B \u202C
//
// OUTPUT: translated text (RTL-marker-clean)

public enum TargetLanguage {
    case english
    case hebrew
}

public struct TranslationContext {

    public init() {}

    // MARK: - Character Mapping Table

    // Standard Hebrew keyboard layout (Mac "Hebrew" layout) ↔ US English QWERTY, bidirectional.
    // Key: English character → Value: Hebrew character
    // The reverse mapping (Hebrew → English) is derived by inverting this table.
    //
    // Verified against macOS UCKeyTranslate on the "Hebrew" layout (both unshifted and Shift).
    // Entries are included only where Hebrew output differs from English output.
    // Identical characters (digits, !, @, #, $, %, ^, *, +, _, :, |, ?) pass through unchanged.
    private static let englishToHebrew: [Character: Character] = [
        // --- Unshifted letter/punctuation keys ---
        "q": "/",
        "w": "׳",  // U+05F3 Hebrew Punctuation Geresh (not ASCII apostrophe U+0027)
        "e": "ק",
        "r": "ר",
        "t": "א",
        "y": "ט",
        "u": "ו",
        "i": "ן",
        "o": "ם",
        "p": "פ",
        "[": "]",
        "]": "[",
        "\\": "ֿ", // U+05BF Hebrew Point Rafe
        "a": "ש",
        "s": "ד",
        "d": "ג",
        "f": "כ",
        "g": "ע",
        "h": "י",
        "j": "ח",
        "k": "ל",
        "l": "ך",
        ";": "ף",
        "'": ",",
        "z": "ז",
        "x": "ס",
        "c": "ב",
        "v": "ה",
        "b": "נ",
        "n": "מ",
        "m": "צ",
        ",": "ת",
        ".": "ץ",
        "/": ".",

        // --- Shifted keys that differ from US English ---
        // Shift+7: English=& Hebrew=₪ (shekel sign U+20AA)
        "&": "₪",
        // Shift+': English=" Hebrew=״ (Hebrew double geresh U+05F4)
        "\"": "״",
        // Shift+9/0: parens are swapped (Hebrew Shift+9=')' vs English Shift+9='(')
        "(": ")",
        ")": "(",
        // Shift+,/.: angle brackets are swapped (Hebrew Shift+,='>' vs English Shift+,='<')
        "<": ">",
        ">": "<",
        // Shift+[/]: curly braces are swapped (Hebrew Shift+[='}' vs English Shift+[='{')
        "{": "}",
        "}": "{",
    ]

    // Derived reverse mapping: Hebrew character → English character
    private static let hebrewToEnglish: [Character: Character] = {
        var reversed: [Character: Character] = [:]
        for (eng, heb) in englishToHebrew {
            reversed[heb] = eng
        }
        return reversed
    }()

    // RTL/LTR direction markers to strip from output
    private static let rtlMarkers: Set<Character> = [
        "\u{200F}", // RIGHT-TO-LEFT MARK
        "\u{200E}", // LEFT-TO-RIGHT MARK
        "\u{202B}", // RIGHT-TO-LEFT EMBEDDING
        "\u{202C}", // POP DIRECTIONAL FORMATTING
    ]

    // MARK: - Maximum payload size
    public static let maxPayloadCharacters = 2000

    // MARK: - Public Translation API

    /// Translates `text` from the current layout to `targetLanguage`.
    ///
    /// - Parameters:
    ///   - text: The raw input string. Must not exceed 2000 characters.
    ///   - targetLanguage: The desired output language.
    ///   - fallbackMacroUsed: True when the line was auto-selected via Cmd+Shift+Left
    ///                         (triggers Rule 2 capitalization).
    /// - Returns: Translated string with RTL markers stripped.
    public func translate(
        _ text: String,
        to targetLanguage: TargetLanguage,
        fallbackMacroUsed: Bool = false
    ) -> String {
        guard !text.isEmpty else { return text }
        guard text.count <= Self.maxPayloadCharacters else { return text }

        // PHASE 1: Per-character translation
        var output = translateCharacters(text, to: targetLanguage)

        // PHASE 2: Post-translation fixups (English target only)
        if targetLanguage == .english {
            // Rule 2: capitalize first non-whitespace lowercase letter when line was auto-selected
            if fallbackMacroUsed, let idx = output.firstIndex(where: { $0.isLowercase && $0.isLetter }) {
                let upper = output[idx].uppercased()
                output.replaceSubrange(idx...idx, with: upper)
            }

            // Rule 3: capitalize after sentence-ending punctuation
            output = applyPostSentenceCapitalization(output)
        }

        // PHASE 3: Strip RTL/LTR direction markers
        output = stripRTLMarkers(output)

        return output
    }

    // MARK: - Private helpers

    private func translateCharacters(_ text: String, to targetLanguage: TargetLanguage) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for char in text {
            // Rule 0 (gate): if target is Hebrew, skip capitalization rules and map directly
            if targetLanguage == .hebrew {
                // Map English → Hebrew; unmapped characters pass through
                if let heb = Self.englishToHebrew[char] {
                    result.append(heb)
                } else if let heb = Self.englishToHebrew[Character(char.lowercased())] {
                    // Try lowercased version for uppercase English input (e.g. 'A' → 'ש')
                    result.append(heb)
                } else {
                    result.append(char)
                }
            } else {
                // Target is English: apply Rules 1 and 4
                // Rule 1: explicit uppercase [A-Z] in input maps directly to uppercase output
                if char.isUppercase && char.isLetter && char.isASCII {
                    // Try mapping the lowercase version from Hebrew→English
                    let lower = Character(char.lowercased())
                    if let eng = Self.hebrewToEnglish[lower] {
                        result.append(Character(String(eng).uppercased()))
                    } else {
                        // Not a Hebrew char — check if it's already an English uppercase letter
                        result.append(char)
                    }
                } else if let eng = Self.hebrewToEnglish[char] {
                    // Rule 4: map Hebrew → lowercase English (default)
                    result.append(eng)
                } else {
                    // Unmapped: pass through unchanged
                    result.append(char)
                }
            }
        }

        return result
    }

    // Rule 3: capitalize the first lowercase letter that follows [.!?] and whitespace
    private func applyPostSentenceCapitalization(_ text: String) -> String {
        guard text.count > 2 else { return text }

        var result = Array(text)
        var prevPunct = false
        var prevSpace = false

        for i in result.indices {
            let ch = result[i]
            if prevPunct && prevSpace && ch.isLowercase && ch.isLetter {
                result[i] = Character(String(ch).uppercased())
                prevPunct = false
                prevSpace = false
            } else if ch == "." || ch == "!" || ch == "?" {
                prevPunct = true
                prevSpace = false
            } else if prevPunct && ch.isWhitespace {
                prevSpace = true
            } else {
                prevPunct = false
                prevSpace = false
            }
        }

        return String(result)
    }

    private func stripRTLMarkers(_ text: String) -> String {
        return String(text.unicodeScalars.filter { scalar in
            let char = Character(scalar)
            return !Self.rtlMarkers.contains(char)
        })
    }
}
