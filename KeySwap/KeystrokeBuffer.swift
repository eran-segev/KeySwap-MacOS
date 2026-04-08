import Foundation
import Carbon

// MARK: - KeystrokeBuffer
//
// Passive ring buffer of recent keystrokes used to recover characters
// swallowed by macOS when Shift+letter is pressed on the Hebrew layout.
//
// SEC-1 EXCEPTION: This buffer records the virtual keycode (integer) and
// Shift modifier flag (boolean) for character-producing keyDown events.
// It does NOT record Unicode strings, app names, or field content.
//
// Security invariants:
//   - In-memory only, never persisted to disk
//   - Bounded at `capacity` entries (default 64, ~1KB)
//   - Cleared on navigation keys, backspace, Cmd/Ctrl combos, and after every swap
//   - IsSecureEventInputEnabled() blocks the CGEventTap entirely for password fields
//   - The app does NOT modify keystrokes in real-time — it only observes passively

@MainActor
final class KeystrokeBuffer {

    // MARK: - Entry

    struct Entry {
        let keyCode: Int64
        let isLetter: Bool      // true for a-z keycodes (Shift swallowed on Hebrew)
        let shiftHeld: Bool     // was Shift held when this key was pressed
    }

    // MARK: - Ring buffer storage

    private var buffer: [Entry?]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    // MARK: - Static tables

    // The 26 letter keycodes (ANSI a-z). On the Hebrew layout, Shift+letter
    // produces no output for these keys — macOS swallows the keystroke.
    static let letterKeyCodes: Set<Int64> = [
        0x00, // a
        0x01, // s
        0x02, // d
        0x03, // f
        0x04, // h
        0x05, // g
        0x06, // z
        0x07, // x
        0x08, // c
        0x09, // v
        0x0B, // b
        0x0C, // q
        0x0D, // w
        0x0E, // e
        0x0F, // r
        0x10, // y
        0x11, // t
        0x1F, // o
        0x20, // u
        0x22, // i
        0x23, // p
        0x25, // l
        0x26, // j
        0x28, // k
        0x2D, // n
        0x2E, // m
    ]

    // All character-producing keycodes (letters + numbers + punctuation + space).
    // Only these are recorded into the buffer. F-keys, media keys, etc. are ignored.
    static let characterKeyCodes: Set<Int64> = letterKeyCodes.union([
        0x12, // 1
        0x13, // 2
        0x14, // 3
        0x15, // 4
        0x16, // 6
        0x17, // 5
        0x18, // =
        0x19, // 9
        0x1A, // 7
        0x1B, // -
        0x1C, // 8
        0x1D, // 0
        0x1E, // ]
        0x21, // [
        0x27, // '
        0x29, // ;
        0x2A, // \
        0x2B, // ,
        0x2C, // /
        0x2F, // .
        0x31, // space
        0x32, // `
    ])

    // Keys that invalidate (clear) the buffer — navigation and editing keys
    // that break the correspondence between buffer entries and field text.
    static let invalidatingKeyCodes: Set<Int64> = [
        0x33, // kVK_Delete (Backspace)
        0x75, // kVK_ForwardDelete
        0x24, // kVK_Return
        0x4C, // kVK_ANSI_KeypadEnter
        0x30, // kVK_Tab
        0x35, // kVK_Escape
        0x73, // kVK_Home
        0x77, // kVK_End
        0x74, // kVK_PageUp
        0x79, // kVK_PageDown
        0x7B, // kVK_LeftArrow
        0x7C, // kVK_RightArrow
        0x7D, // kVK_DownArrow
        0x7E, // kVK_UpArrow
    ]

    // Maps the 26 letter keycodes to the unshifted Hebrew character they produce
    // on the standard macOS "Hebrew" layout. Used for alignment verification and
    // gap-filling during enrichment.
    //
    // This is the composition of keycode → QWERTY letter → englishToHebrew.
    // Verified against TranslationContext's mapping table in tests.
    static let keycodeToHebrew: [Int64: Character] = [
        0x00: "ש", // a
        0x01: "ד", // s
        0x02: "ג", // d
        0x03: "כ", // f
        0x04: "י", // h
        0x05: "ע", // g
        0x06: "ז", // z
        0x07: "ס", // x
        0x08: "ב", // c
        0x09: "ה", // v
        0x0B: "נ", // b
        0x0C: "/", // q
        0x0D: "׳", // w (U+05F3)
        0x0E: "ק", // e
        0x0F: "ר", // r
        0x10: "ט", // y
        0x11: "א", // t
        0x1F: "ם", // o
        0x20: "ו", // u
        0x22: "ן", // i
        0x23: "פ", // p
        0x25: "ך", // l
        0x26: "ח", // j
        0x28: "ל", // k
        0x2D: "מ", // n
        0x2E: "צ", // m
    ]

    // MARK: - Recording

    /// Records a keyDown event into the buffer.
    /// Called from GlobalHotkeyListener.handleEvent() for every keyDown, before the F9 gate.
    func record(keyCode: Int64, flags: CGEventFlags) {
        // Invalidate on Command or Control modifier (not Option — Option+key can produce
        // characters on Hebrew layout and .maskAlternate fires spuriously on layout switches)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            clear()
            return
        }

        // Invalidate on navigation/editing keys
        if Self.invalidatingKeyCodes.contains(keyCode) {
            clear()
            return
        }

        // Only record character-producing keys
        guard Self.characterKeyCodes.contains(keyCode) else {
            return
        }

        let isLetter = Self.letterKeyCodes.contains(keyCode)
        let entry = Entry(
            keyCode: keyCode,
            isLetter: isLetter,
            shiftHeld: flags.contains(.maskShift)
        )
        append(entry)
    }

    /// Clears all buffer entries. Stale Entry values in the backing array are
    /// harmless — recentEntries() uses `count` to bound its walk.
    func clear() {
        writeIndex = 0
        count = 0
    }

    // MARK: - Enrichment

    /// Result of buffer enrichment: the enriched text plus indices of characters
    /// that were recovered from swallowed Shift+letter keystrokes.
    struct EnrichmentResult {
        let text: String
        /// Indices into `text` where a swallowed Shift+letter was inserted.
        /// These should be uppercased after translation to English.
        let shiftIndices: Set<Int>
    }

    // RTL/LTR direction markers that may appear in field text but have no
    // corresponding buffer entry (they are inserted by the OS, not typed).
    private static let rtlMarkers: Set<Character> = [
        "\u{200F}", "\u{200E}", "\u{202B}", "\u{202C}",
    ]

    /// Attempts to reconstruct swallowed Shift+letter characters by aligning
    /// the buffer against the field text.
    ///
    /// Returns an `EnrichmentResult` with the enriched Hebrew string and the
    /// indices of inserted Shift+letter characters, or `nil` if alignment fails.
    /// When `nil` is returned, the caller falls back to the original field text.
    func enrichedText(fieldText: String) -> EnrichmentResult? {
        guard !fieldText.isEmpty else { return nil }

        let entries = recentEntries()
        guard !entries.isEmpty else { return nil }

        // Strip RTL/LTR markers from field text before alignment — these are
        // injected by macOS, not typed, so they have no buffer entries.
        let strippedField = fieldText.filter { !Self.rtlMarkers.contains($0) }
        guard !strippedField.isEmpty else { return nil }

        // Find the suffix of buffer entries that corresponds to the field text.
        // Non-swallowed entries should equal fieldText.count when counted from the end.
        let fieldChars = Array(strippedField)
        let fieldCount = fieldChars.count

        // Walk entries from the end backward, counting non-swallowed entries
        // until we have enough to cover the field text.
        var nonSwallowedCount = 0
        var startIdx = entries.count

        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let entry = entries[i]
            let isSwallowed = entry.isLetter && entry.shiftHeld
            if !isSwallowed {
                nonSwallowedCount += 1
            }
            startIdx = i
            if nonSwallowedCount == fieldCount {
                break
            }
        }

        // If we couldn't find enough non-swallowed entries, buffer is too short
        guard nonSwallowedCount == fieldCount else { return nil }

        // Extend backward to include leading swallowed entries that precede the
        // matched suffix. Example: "I love" — Shift+I is swallowed, field is
        // " ךםהק". Without this, the Shift+I entry would be outside the suffix.
        while startIdx > 0 {
            let prev = entries[startIdx - 1]
            if prev.isLetter && prev.shiftHeld {
                startIdx -= 1
            } else {
                break
            }
        }

        let suffix = Array(entries[startIdx...])

        // Check if any entries are actually swallowed — if not, no enrichment needed
        let hasSwallowed = suffix.contains { $0.isLetter && $0.shiftHeld }
        guard hasSwallowed else { return nil }

        // Walk the suffix and field text in parallel, building the enriched string
        var result = ""
        result.reserveCapacity(suffix.count)
        var shiftIndices = Set<Int>()
        var fieldIdx = 0
        var resultIdx = 0

        for entry in suffix {
            let isSwallowed = entry.isLetter && entry.shiftHeld

            if isSwallowed {
                // This keystroke produced no output — insert the unshifted Hebrew character
                guard let hebrewChar = Self.keycodeToHebrew[entry.keyCode] else {
                    // Unknown letter keycode — alignment broken
                    return nil
                }
                result.append(hebrewChar)
                shiftIndices.insert(resultIdx)
                resultIdx += 1
            } else {
                // This keystroke produced output — verify alignment with field text
                guard fieldIdx < fieldCount else {
                    // More non-swallowed entries than field characters — misaligned
                    return nil
                }

                if entry.isLetter {
                    // Letter key: verify the expected Hebrew character matches the field
                    guard let expectedHebrew = Self.keycodeToHebrew[entry.keyCode],
                          fieldChars[fieldIdx] == expectedHebrew else {
                        // Mismatch — buffer is stale
                        return nil
                    }
                }
                // Non-letter keys: accept the field character as-is (wildcard match).
                // We don't have a complete keycode-to-output mapping for all modifier
                // combinations on numbers/punctuation, so we trust the field text.

                result.append(fieldChars[fieldIdx])
                fieldIdx += 1
                resultIdx += 1
            }
        }

        // Verify we consumed all field characters
        guard fieldIdx == fieldCount else { return nil }

        return EnrichmentResult(text: result, shiftIndices: shiftIndices)
    }

    // MARK: - Private helpers

    private func append(_ entry: Entry) {
        buffer[writeIndex] = entry
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity {
            count += 1
        }
    }

    /// Returns buffer entries in chronological order (oldest first).
    private func recentEntries() -> [Entry] {
        guard count > 0 else { return [] }

        var entries: [Entry] = []
        entries.reserveCapacity(count)

        let start = (writeIndex - count + capacity) % capacity
        for i in 0..<count {
            let idx = (start + i) % capacity
            if let entry = buffer[idx] {
                entries.append(entry)
            }
        }
        return entries
    }
}
