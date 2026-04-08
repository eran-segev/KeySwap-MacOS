# KeySwap macOS — Deferred Items

Items deferred during CEO review (2026-04-02). Not in MVP scope.

## P1 — Before Phase 1 Merge

- [x] **Shifted-key mapping verification:** Verified via UCKeyTranslate against the macOS "Hebrew" layout (no Mac hardware needed — parsed from system bundle). Fixed `w→׳` (U+05F3, was wrong U+0027), fixed `\→ֿ` (U+05BF), added 8 shifted mappings: `&↔₪`, `"↔״`, `(↔)`, `)↔(`, `<↔>`, `>↔<`, `{↔}`, `}↔{`.

- [x] **Verify IOHIDRequestAccess availability:** Dual approach implemented. Startup uses a non-prompting `CGEventTap.tapCreate` probe to check IM status without triggering a system dialog. The onboarding button uses `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` via dlsym to trigger the macOS system prompt. Both paths poll until granted.

## P1 — Eng Review Design Changes

- [x] **Update stale documentation:** Fix 3 documents to match Design Doc (source of truth):
  - PRD: Change "NSPasteboardItem pointer" clipboard preservation to eager `dataForType:` copy
  - Architecture Doc: Change `NSEvent.addGlobalMonitorForEvents` to `CGEventTap`; update AppState enum to include PARTIAL and DEGRADED states; fix clipboard approach
  - Blueprint: Update clipboard approach, add Shift+F9, visual flash, About window, re-entrancy guard, DEGRADED state to testing section

## P1 — Known Bugs

- [x] **Shift+letter dropped on Hebrew layout (lost capitals):** When a user types on the Hebrew layout intending English, Shift+letter keystrokes (e.g., Shift+H for capital "H") produce no output — macOS swallows them because Hebrew letters have no case distinction and the Shift+letter combination has no assigned output for most keys. By the time KeySwap reads the text to swap, those characters are entirely missing from the input (not lowercased — *gone*). **Fix:** Passive keystroke buffer (`KeystrokeBuffer.swift`) records keycode + Shift flag for each keyDown. On F9, the buffer is aligned against the field text to detect and fill in swallowed characters. The original "strip `.maskShift` in real-time" approach was rejected because it would make the app modify keystrokes as they flow, fundamentally changing the trust model. The buffer approach preserves the passive-observer design. See SEC-1a in the Engineering Design Doc.

## P2 — Post-MVP

- [ ] **Configurable hotkey:** Allow users to remap F9 to a different key via UserDefaults. Store preference in `UserDefaults.standard`. Add a Preferences window accessible from the menu bar. Default remains F9/Shift+F9.

- [ ] **Multi-language foundation:** Parameterize the language pair in TranslationContext so the engine can support additional layout pairs (e.g., Russian/English, Arabic/English) without rewriting core logic. Current implementation hardcodes English/Hebrew. Refactor the character mapping table to be injected rather than compiled-in.

## P3 — Nice to Have

- [ ] **Post-swap spell check:** After converting characters, run the translated output through `NSSpellChecker.shared()` to detect grammar/spelling errors introduced by the mapping (e.g., capitalization edge cases the rules miss). Either auto-correct or offer suggestions. Requires careful UX design to avoid surprising the user with unexpected changes.
