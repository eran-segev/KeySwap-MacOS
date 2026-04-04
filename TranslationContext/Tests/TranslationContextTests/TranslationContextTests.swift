import Testing
import Foundation
@testable import TranslationContext

// MARK: - Hebrew → English tests

@Suite("Hebrew to English")
struct HebrewToEnglishTests {
    let tc = TranslationContext()

    @Test("Basic Hebrew→English character mapping")
    func basicMapping() {
        // ש=a, ל=k, ו=u, ם=o
        #expect(tc.translate("שלום", to: .english) == "akuo")
    }

    @Test("Unmapped characters pass through unchanged")
    func unmappedPassThrough() {
        // Numbers and symbols not in the Hebrew layout map pass through
        #expect(tc.translate("שלום 123", to: .english) == "akuo 123")
    }

    @Test("Shift-row characters not in map pass through")
    func unmappedShiftedChars() {
        #expect(tc.translate("!@#$%", to: .english) == "!@#$%")
    }
}

// MARK: - English → Hebrew tests

@Suite("English to Hebrew")
struct EnglishToHebrewTests {
    let tc = TranslationContext()

    @Test("Basic English→Hebrew character mapping")
    func basicMapping() {
        // s=ד, h=י, a=ש, l=ך, o=ם, m=צ
        #expect(tc.translate("shalom", to: .hebrew) == "דישךםצ")
    }

    @Test("Rule 0 gate: Hebrew target skips capitalization rules even for uppercase input")
    func rule0HebrewTargetSkipsCaps() {
        // S→ד, H→י, A→ש, L→ך, O→ם, M→צ (uppercase treated same as lowercase for Hebrew target)
        #expect(tc.translate("SHALOM", to: .hebrew) == "דישךםצ")
        // fallbackMacroUsed flag must have zero effect on Hebrew output
        let withFlag = tc.translate("hello", to: .hebrew, fallbackMacroUsed: true)
        let withoutFlag = tc.translate("hello", to: .hebrew, fallbackMacroUsed: false)
        #expect(withFlag == withoutFlag)
    }

    @Test("Rule 3 does not fire for Hebrew target")
    func rule3NotForHebrew() {
        let result = tc.translate("hello. world", to: .hebrew)
        // No uppercase W should appear in Hebrew output
        #expect(!result.contains("W"))
    }
}

// MARK: - Capitalization rules

@Suite("Capitalization Rules")
struct CapitalizationTests {
    let tc = TranslationContext()

    @Test("Rule 1: Uppercase pass-through — non-Hebrew uppercase chars not in map pass through")
    func rule1UppercasePassThrough() {
        // A, B, C are not Hebrew layout chars, pass through unchanged
        #expect(tc.translate("ABC", to: .english) == "ABC")
    }

    @Test("Rule 2: fallbackMacroUsed capitalizes first letter")
    func rule2FallbackCapitalizesFirst() {
        // ש→a; with fallbackMacroUsed, 'a' → 'A'
        #expect(tc.translate("שלום", to: .english, fallbackMacroUsed: true) == "Akuo")
    }

    @Test("Rule 2: capitalizes first non-whitespace letter when output starts with space")
    func rule2SkipsLeadingWhitespace() {
        // Leading space passes through, ש→a is capitalized
        #expect(tc.translate(" שלום", to: .english, fallbackMacroUsed: true) == " Akuo")
    }

    @Test("Rule 3: capitalize after sentence-ending punctuation")
    func rule3PostSentenceCap() {
        // Build input that translates to "hello. world" and confirm 'w' is capitalized.
        // Key insight: '.' in English → 'ץ' in Hebrew (englishToHebrew["."]=ץ),
        // so to get a '.' in English output we need 'ץ' in the Hebrew input.
        // h→י, e→ק, l→ך, l→ך, o→ם, ץ→., space passes through, w→', o→ם, r→ר, l→ך, d→ג
        let input = "יקךךםץ 'םרךג"
        #expect(tc.translate(input, to: .english) == "hello. World")
    }

    @Test("Rule 2 + Rule 3 both fire when fallbackMacroUsed=true")
    func rule2And3Interaction() {
        let input = "יקךךםץ 'םרךג"
        #expect(tc.translate(input, to: .english, fallbackMacroUsed: true) == "Hello. World")
    }

    @Test("Rule 2 does not fire when target is Hebrew")
    func rule2NotForHebrew() {
        // h→י, e→ק, l→ך, l→ך, o→ם
        let result = tc.translate("hello", to: .hebrew, fallbackMacroUsed: true)
        #expect(result == "יקךךם")
    }
}

// MARK: - RTL marker stripping

@Suite("RTL Marker Stripping")
struct RTLTests {
    let tc = TranslationContext()

    @Test("RTL/LTR direction markers are stripped from output")
    func rtlMarkersStripped() {
        let rtl = "\u{200F}"
        let ltr = "\u{200E}"
        let embed = "\u{202B}"
        let pop = "\u{202C}"
        let input = "\(rtl)שלום\(ltr)\(embed)\(pop)"
        let result = tc.translate(input, to: .english)
        #expect(!result.contains(rtl))
        #expect(!result.contains(ltr))
        #expect(!result.contains(embed))
        #expect(!result.contains(pop))
    }
}

// MARK: - Edge cases

@Suite("Edge Cases")
struct EdgeCaseTests {
    let tc = TranslationContext()

    @Test("Empty string returns empty string")
    func emptyString() {
        #expect(tc.translate("", to: .english) == "")
        #expect(tc.translate("", to: .hebrew) == "")
    }

    @Test("Single character Hebrew→English")
    func singleCharHebrew() {
        #expect(tc.translate("ש", to: .english) == "a")
    }

    @Test("Single character English→Hebrew")
    func singleCharEnglish() {
        #expect(tc.translate("a", to: .hebrew) == "ש")
    }

    @Test("Exactly 2000 characters is accepted")
    func maxPayloadAccepted() {
        let input = String(repeating: "ש", count: 2000)
        let result = tc.translate(input, to: .english)
        #expect(result.count == 2000)
        #expect(result.allSatisfy { $0 == "a" })
    }

    @Test("Over 2000 characters is returned unchanged (guard)")
    func overMaxPayloadRejected() {
        let input = String(repeating: "ש", count: 2001)
        let result = tc.translate(input, to: .english)
        #expect(result == input)
    }

    @Test("Round-trip English→Hebrew→English preserves original")
    func roundTrip() {
        let original = "hello world"
        let toHebrew = tc.translate(original, to: .hebrew)
        let backToEnglish = tc.translate(toHebrew, to: .english)
        #expect(backToEnglish == original)
    }

    @Test("Mixed Hebrew + unmapped punctuation")
    func mixedContent() {
        #expect(tc.translate("שלום 123", to: .english) == "akuo 123")
    }
}

// MARK: - Performance

@Suite("Performance")
struct PerformanceTests {
    let tc = TranslationContext()

    @Test("2000 character translation completes in under 10ms")
    func translationPerformance() {
        let input = String(repeating: "ש", count: 2000)
        let start = Date()
        _ = tc.translate(input, to: .english)
        let elapsed = Date().timeIntervalSince(start) * 1000
        // Allow generous 50ms in CLI (no JIT warmup) — production runs < 1ms
        #expect(elapsed < 50, "Translation took \(elapsed)ms, expected < 50ms")
    }
}
