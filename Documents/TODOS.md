# KeySwap macOS — Deferred Items & Shipped Post-MVP

Items deferred during CEO review (2026-04-02). Not in MVP scope.

## Shipped Post-MVP (2026-04-xx)

### P1 Bugs Fixed

- [x] **Shift+letter characters swallowed on Hebrew layout** — Passive keystroke buffer recovers characters lost when Shift+letter is pressed on the Hebrew layout. Implemented in [KeystrokeBuffer.swift](../KeySwap/KeystrokeBuffer.swift). Security mitigation per SEC-1a (scoped exception in [Engineering Design Doc](./KeySwap%20Engineering%20Design%20Doc.md)).
- [x] **Cursor lands at start after swap when Cmd+Shift+Left fallback used** — Fixed by ensuring line-selection fallback correctly positions the cursor at the beginning of captured text before injection.

### P3 Features Shipped

- [x] **Post-swap spell check** — Corrects common English misspellings after translation via injectable `CorrectionProvider` protocol. Implemented in [SpellCheckFilter.swift](../TranslationContext/Sources/TranslationContext/SpellCheckFilter.swift) with full test coverage ([SpellCheckFilterTests.swift](../TranslationContext/Tests/TranslationContextTests/SpellCheckFilterTests.swift)). Only applies to English target language; Hebrew text returned unchanged.

- [x] **Visible corrections + per-swap opt-out and revert (v1.1)** — Aggressive silent autocorrect is gone. Every correction surfaces in a transient HUD ([CorrectionsHUD.swift](../KeySwap/CorrectionsHUD.swift)) listing `original → replacement` rows. New hotkeys: **Option+F9** swaps raw (skips spell check entirely); **Ctrl+F9** reverts the last autocorrect while the HUD is visible. Pending-revert state on `AppState` auto-clears on timer, new swap, or any non-F9 keydown. See [KeySwapApp.swift:handleHotkey](../KeySwap/KeySwapApp.swift) and [GlobalHotkeyListener.swapMode](../KeySwap/GlobalHotkeyListener.swift). Supersedes the P2 "Spell check toggle" item.

## P2 — Post-MVP

- [ ] **Configurable hotkey:** Allow users to remap F9 to a different key via UserDefaults. Store preference in `UserDefaults.standard`. Add a Preferences window accessible from the menu bar. Default remains F9/Shift+F9/Option+F9/Ctrl+F9.

- [ ] **Multi-language foundation:** Parameterize the language pair in TranslationContext so the engine can support additional layout pairs (e.g., Russian/English, Arabic/English) without rewriting core logic. Current implementation hardcodes English/Hebrew. Refactor the character mapping table to be injected rather than compiled-in.

## P3 — Post-MVP

- [ ] **Correction learning loop:** When the user reverts a correction via Ctrl+F9, remember the reverted word so the next swap doesn't "correct" it again. **Scoping requirement:** use a per-app `NSSpellChecker` instance with `ignoredWords`, NOT the shared checker's `learnWord()` — `learnWord` writes to the system-wide spell dictionary and pollutes every app on the Mac. Store reverted words in a bounded in-memory set (cap ~500, LRU eviction), or persist to UserDefaults with a reset-from-menu affordance. Depends on: keeping the new `SpellCheckResult.corrections` API (shipped v1.1).

- [ ] **QA matrix for correction HUD:** Manual end-to-end test grid covering plain F9 / Option+F9 / Ctrl+F9 / Shift+F9 across TextEdit, Notes, Xcode, Mail, Slack, VS Code, Chrome textareas, Discord. Document expected HUD placement (cursor-adjacent vs corner fallback) per app. Commit results to `Documents/QA-v1.1-matrix.md` before tagging v1.1.

- [x] **Revert on clipboard-only paths (shipped in UX pass):** Implemented via synthesized Backspace × N + paste of pre-correction text. See [ClipboardManager.replaceLastNCharsWithPaste](../KeySwap/ClipboardManager.swift). Works everywhere the original swap works (same trust assumptions).

## QA Fixes (2026-04-14 /qa pass on UX-design-improvement branch)

- [x] **HUD timer reverted to production values** — DEV-doubled duration (6s+1s/correction, cap 12s) corrected back to designed values (3s+0.5s/correction, cap 6s). Fixed by /qa in commit `d89a541`.
- [x] **Removed `learnWord()` calls from warmUpSpellChecker()** — Calls permanently mutated the system-wide spell dictionary (affects all apps). Removed per the prohibition documented in the Correction Learning Loop P3 item above. Fixed by /qa in commit `d89a541`.
