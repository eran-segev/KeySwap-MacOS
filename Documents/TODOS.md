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

## P2 — Post-MVP

- [ ] **Configurable hotkey:** Allow users to remap F9 to a different key via UserDefaults. Store preference in `UserDefaults.standard`. Add a Preferences window accessible from the menu bar. Default remains F9/Shift+F9.

- [ ] **Spell check toggle:** Add an on/off toggle for post-swap spell check to the Preferences window. When disabled, swap in a `NoOpCorrectionProvider` (implements `CorrectionProvider`, returns nil for every word). Useful if false positives are annoying in practice. **Depends on:** Preferences window (above item) + post-swap spell check (P3 below) being built first.

- [ ] **Multi-language foundation:** Parameterize the language pair in TranslationContext so the engine can support additional layout pairs (e.g., Russian/English, Arabic/English) without rewriting core logic. Current implementation hardcodes English/Hebrew. Refactor the character mapping table to be injected rather than compiled-in.

## P3 — Next Up

- [x] **Post-swap spell check:** After converting characters, run the translated English output through `NSSpellChecker` to silently correct user typos (e.g., "teh" → "the") that survived the layout swap.
  - **Architecture:** `SpellCheckFilter` struct in TranslationContext package with an injectable `CorrectionProvider` protocol (AppKit stays in the app layer). `NSSpellCheckerProvider` in KeySwapApp implements the protocol.
  - **CorrectionProvider has two methods** (eng review finding — keeps NSSpellChecker entirely out of the package):
    - `misspelledRange(in:startingAt:) -> NSRange`
    - `correction(forWord:in:) -> String?`
  - **Insertion point:** KeySwapApp.swift **after the Shift-index uppercase pass** (~line 303), NOT after `translationEngine.translate()` at line 291. The Shift-index pass recovers intentional user capitalizations from the keystroke buffer — spell check before it will corrupt those positions.
  - **Correction algorithm:** Two-phase back-to-front — collect all misspelled `NSRange` values from the original string via `provider.misspelledRange()`, sort descending, apply corrections end→start. Add bounds check before substring: `guard range.location + range.length <= text.utf16.count else { continue }`.
  - **Language:** Hardcode `"en"` — do NOT use `NSSpellChecker.shared().language()` which reflects system language.
  - **Startup requirements (add to `applicationDidFinishLaunching`):**
    1. Warm up NSSpellChecker on a background queue (first IPC call can take 100–300ms, busting the 500ms SLA): `DispatchQueue.global(qos: .utility).async { _ = NSSpellChecker.shared.checkSpellingOfString("warmup", startingAt: 0) }`
    2. Pre-learn common Hebrew transliterations to prevent silent "corrections" (Dvir→Diver, Tzvi→TV, etc.) via `NSSpellChecker.shared.learnWord()` for each name — call only if `!hasLearnedWord()`.
  - **Tests:** `MockCorrectionProvider` must be a **class** (not struct) with an explicit `[NSRange]` queue it pops sequentially. Required test cases: Hebrew no-op, empty string, no misspellings fast path, single correction, longer correction, **multi-misspelling back-to-front** (`"teh recieve foo"` → `"the receive foo"`), nil correction path.
  - **Scope:** English target only.
  - **Design doc:** `~/.gstack/projects/eran-segev-KeySwap-MacOS/eransegev-main-design-20260408-234220.md`
  - **Shipped:** 2026-04-09 (commits 5b2b4b9 + e7eff10). Two bugs found during testing and fixed:
    1. **SpellCheckFilter infinite loop:** `NSSpellChecker` returned a non-advancing range for some inputs; Phase 1 while-loop never exited. Fix: `guard nextOffset > offset else { break }` in `SpellCheckFilter.postProcess`.
    2. **Cursor at line start after swap:** `kAXSelectedTextAttribute` write with a backward selection (created by `Cmd+Shift+Left` fallback) left cursor at position 0. Fix: read `kAXSelectedTextRangeAttribute` before write, then explicitly reposition to `selRange.location + text.utf16.count` after write.
