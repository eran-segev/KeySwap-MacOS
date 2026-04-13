# KeySwap macOS — Deferred Items & Shipped Post-MVP

Items deferred during CEO review (2026-04-02). Not in MVP scope.

## Shipped Post-MVP (2026-04-xx)

### P1 Bugs Fixed

- [x] **Shift+letter characters swallowed on Hebrew layout** — Passive keystroke buffer recovers characters lost when Shift+letter is pressed on the Hebrew layout. Implemented in [KeystrokeBuffer.swift](../KeySwap/KeystrokeBuffer.swift). Security mitigation per SEC-1a (scoped exception in [Engineering Design Doc](./KeySwap%20Engineering%20Design%20Doc.md)).
- [x] **Cursor lands at start after swap when Cmd+Shift+Left fallback used** — Fixed by ensuring line-selection fallback correctly positions the cursor at the beginning of captured text before injection.

### P3 Features Shipped

- [x] **Post-swap spell check** — Corrects common English misspellings after translation via injectable `CorrectionProvider` protocol. Implemented in [SpellCheckFilter.swift](../TranslationContext/Sources/TranslationContext/SpellCheckFilter.swift) with full test coverage ([SpellCheckFilterTests.swift](../TranslationContext/Tests/TranslationContextTests/SpellCheckFilterTests.swift)). Only applies to English target language; Hebrew text returned unchanged. Can be disabled post-MVP via toggle in Preferences (P2 feature).

## P2 — Post-MVP

- [ ] **Configurable hotkey:** Allow users to remap F9 to a different key via UserDefaults. Store preference in `UserDefaults.standard`. Add a Preferences window accessible from the menu bar. Default remains F9/Shift+F9.

- [ ] **Spell check toggle:** Add an on/off toggle for post-swap spell check to the Preferences window. When disabled, swap in a `NoOpCorrectionProvider` (implements `CorrectionProvider`, returns nil for every word). Useful if false positives are annoying in practice. **Depends on:** Preferences window (above item).

- [ ] **Multi-language foundation:** Parameterize the language pair in TranslationContext so the engine can support additional layout pairs (e.g., Russian/English, Arabic/English) without rewriting core logic. Current implementation hardcodes English/Hebrew. Refactor the character mapping table to be injected rather than compiled-in.
