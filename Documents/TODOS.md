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

- [x] **Configurable hotkey:** Allow users to remap F9 to a different key via UserDefaults. Store preference in `UserDefaults.standard`. Add a Preferences window accessible from the menu bar. Default remains F9/Shift+F9/Option+F9/Ctrl+F9. **Completed in v1.2.0.0 (2026-04-25).**

- [ ] **Multi-language foundation:** Parameterize the language pair in TranslationContext so the engine can support additional layout pairs (e.g., Russian/English, Arabic/English) without rewriting core logic. Current implementation hardcodes English/Hebrew. Refactor the character mapping table to be injected rather than compiled-in.

## Shipped Post-MVP — v1.2 (pulled forward)

- [x] **Extract `SpellCheckDecision` helper** — pulled forward from the v1.4 trigger during v1.2 pre-landing review (2026-04-23) to back the Option+F9-wins-over-per-language-toggle test deliverable from the v1.3 eng review. Pure function `spellCheckDecision(target:skipSpellCheck:englishEnabled:hebrewEnabled:hasHebrew:) -> SpellCheckDecision` lives in [SpellCheckProvider.swift](../KeySwap/SpellCheckProvider.swift); exhaustive gating-matrix tests (Option+F9 override, per-language toggles, dict-missing signal) in [SpellCheckProviderTests.swift](../KeySwapTests/SpellCheckProviderTests.swift). Adding a 3rd language is now a pure-function extension, not a pipeline rewrite.

- [ ] **Hebrew correction quality audit (post-v1.2 ship, 2 weeks in):** Curate a 100-sentence Hebrew corpus with realistic typos, run the swap pipeline against it, measure correction precision. **Why load-bearing:** v1.3 defaults Hebrew autocorrect to ON without empirical validation of NSSpellChecker Hebrew quality. Hebrew morphology (root+template, prefix chains ו/ה/ש/ב/כ/ל/מ, possessive suffixes) is hard for NSSpellChecker; if precision < 90%, default-on violates the pinned `feedback_silent_mutations` memory (wrong noisy corrections are as bad as silent ones). **Fix sketch:** build a test harness that reads corpus fixtures, runs `SingleLanguageSpellCheckerProvider(languageCode: "he")` against each, computes precision/recall vs hand-labeled expected corrections, reports a score. If precision < 90%, patch v1.2.1 flips `spellCheckEnabledHebrew` default to `false` and adds an "experimental" sub-label in Preferences. **Depends on:** v1.2 with Hebrew check shipped, 2+ weeks of real-world usage. **Context:** See `~/.gstack/projects/eran-segev-KeySwap-MacOS/ceo-plans/2026-04-21-v1.3-hebrew-spell-check.md` Outside Voice Decisions section (tensions #1 and #2).

## P3 — Post-MVP (deferred from v1.2 eng review, 2026-04-16)

- [ ] **completePipeline sound-routing tests (deferred from v1.2 pre-landing review, 2026-04-18).** CEO plan for v1.2 specified a `completePipelineSoundRoutingTests` suite to verify that `completePipeline(.success(corrections: []))` plays the success sound and `completePipeline(.success(corrections: [one]))` does NOT (CorrectionsHUD owns that sound). The test was not written in the v1.2 branch because it requires dependency injection: either a fake `NSSound` factory or an `AppSettings` protocol so the test can observe which sound method was called. **Why load-bearing:** any future stray `playSuccess()` call in the corrections path would produce a double-sound (success + pop) with no regression guard. **Fix sketch:** extract `AppSettings.playSuccess()`/`playCorrections()` behind a protocol, inject a spy into KeySwapApp for tests, assert call counts per SwapResult case.

- [x] **Update DESIGN.md About window size.** DESIGN.md lists "About window: 300x200 (standard macOS about size)" but the actual implementation is 380x320, now 380x350 per v1.2 design review. Update the doc to reflect the current size so future implementers use accurate specs. **Why:** prevents reference debt and confusion from stale specs. **Depends on:** v1.2 shiipping (status line addition finalizes the size at 380x350). **Completed:** v1.2.0.0 (2026-04-27) — updated Documents/DESIGN.md window sizes, removed stale "Future settings" entry, synced Bidi/RTL and Inline Action Buttons sections. Currently `hotkeyListener.swapCompleted()` is called in 4 separate places within `runRevertPipeline()` (lines 661, 695, 723, 729 in KeySwapApp.swift). After v1.2 ships SwapResult, a natural follow-up is introducing `completeRevert(_ result: RevertResult)` that owns the sound + swapCompleted() call, mirroring `completePipeline`. **Depends on:** v1.2 SwapResult being shipped. **Why deferred:** revert doesn't map cleanly to SwapResult; consolidation would need a parallel RevertResult enum and rewrites of 4 call sites — scope expansion during v1.2 eng review.

- [ ] **Guard `completePipeline()` against double-fire.** If the 500ms SLA fires while a clipboard paste callback is in flight, `completePipeline(.failure(.timeout))` fires first, then `completePipeline(.success)` fires when the callback returns. The `swapCompleted()` double-call is idempotent but a success flash and beep could fire on the same swap. Fix: add an `isCompleted` flag inside the swap operation, or check `slaTimeoutItem == nil` as a guard inside `completePipeline`. Pre-existing race; made more visible by v1.2 typed SwapResult.

- [ ] **Correction learning loop:** When the user reverts a correction via Ctrl+F9, remember the reverted word so the next swap doesn't "correct" it again. **Scoping requirement:** use a per-app `NSSpellChecker` instance with `ignoredWords`, NOT the shared checker's `learnWord()` — `learnWord` writes to the system-wide spell dictionary and pollutes every app on the Mac. Store reverted words in a bounded in-memory set (cap ~500, LRU eviction), or persist to UserDefaults with a reset-from-menu affordance. Depends on: keeping the new `SpellCheckResult.corrections` API (shipped v1.1).

- [ ] **QA matrix for correction HUD:** Manual end-to-end test grid covering plain F9 / Option+F9 / Ctrl+F9 / Shift+F9 across TextEdit, Notes, Xcode, Mail, Slack, VS Code, Chrome textareas, Discord. Document expected HUD placement (cursor-adjacent vs corner fallback) per app. Commit results to `Documents/QA-v1.1-matrix.md` before tagging v1.1.

- [x] **Revert on clipboard-only paths (shipped in UX pass):** Implemented via synthesized Backspace × N + paste of pre-correction text. See [ClipboardManager.replaceLastNCharsWithPaste](../KeySwap/ClipboardManager.swift). Works everywhere the original swap works (same trust assumptions).

## QA Fixes (2026-04-14 /qa pass on UX-design-improvement branch)

- [x] **HUD timer reverted to production values** — DEV-doubled duration (6s+1s/correction, cap 12s) corrected back to designed values (3s+0.5s/correction, cap 6s). Fixed by /qa in commit `d89a541`.
- [x] **Removed `learnWord()` calls from warmUpSpellChecker()** — Calls permanently mutated the system-wide spell dictionary (affects all apps). Removed per the prohibition documented in the Correction Learning Loop P3 item above. Fixed by /qa in commit `d89a541`.
