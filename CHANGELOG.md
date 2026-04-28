# Changelog

All notable changes to KeySwap for macOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1.0] - 2026-04-28

### Added

- **Launch at login** — New STARTUP section in Preferences with a "Launch at login" checkbox. Backed by `SMAppService.mainApp` (macOS 13+). The setting reflects the real system state and syncs the checkbox back if macOS rejects the request. "Reset to Defaults" leaves this setting untouched — it's a system-level choice the user made explicitly.

### Fixed

- **Unconditional login item registration removed** — Previous builds silently registered KeySwap as a login item on every launch via `SMAppService.mainApp.register()`, with no user control. Registration is now opt-in via the Preferences toggle.

---

## [1.2.0.0] - 2026-04-25

### Added

- **Preferences window** — New "Preferences…" menu item opens a 500x460 window with four sections: Hotkey, Autocorrect (per-language), Sounds, Feedback, plus Reset to Defaults. Settings persist via `UserDefaults`
- **Configurable hotkey** — Pick the primary swap key from F1–F6, F9, or F10 in Preferences. The four modifier variants (plain / Shift / Option / Ctrl) move with the base key automatically
- **Distinct sound cues** — Clean swaps play "Tink", swaps with spell corrections play "Pop". Add a master sound toggle and 0.0–1.0 volume slider (respects system sound settings)
- **Per-language autocorrect toggles** — Independent on/off for English and Hebrew autocorrect in Preferences. Both default on. Option+F9 raw-swap still bypasses both regardless of the toggles
- **Hebrew spell check (v1.3 layered into this release)** — Post-swap spell check now runs on Hebrew swaps as well as English, using the macOS Hebrew dictionary. Corrections appear in the same HUD with an RTL-aware `←` arrow. If the Hebrew dictionary isn't installed on your Mac, KeySwap shows a clickable toast that opens System Settings so you can install it; once dismissed it stays hidden for the rest of the session. Restart KeySwap to pick up newly installed dictionaries
- **Script-aware token filter** — Spell check no longer flags foreign-script words (e.g. "Gmail" in a Hebrew paragraph or `ירושלים` in an English one) — they're skipped instead of routed to the wrong-language dictionary
- **Error toast HUD** — Short top-right toast reports failed swaps with a concrete reason (No text selected, Field is read-only, Selection too large, No focused field, Swap timed out, Clipboard write failed). Toggle to Silent in Preferences to suppress. The same component now powers the clickable "install Hebrew dictionary" notice
- **Red menu-bar flash on failure** — 2-second red tint mirrors the existing green success flash
- **About window status line** — Shows the outcome of your last swap ("Clean swap", "N corrections applied", or "Failed: …")
- **Paragraph writing-direction flip (post-plan addition)** — When KeySwap uses the Cmd+Shift+Left line-selection fallback to grab text, it also presses the frontmost app's "Left to Right" / "Right to Left" menu item so paragraph direction matches the new keyboard layout. Silent no-op when that menu isn't present (most Electron/Chrome/Terminal apps, non-English UI locales). Not in the v1.2 CEO plan — see the post-plan additions section of the plan file for the AX trust-boundary note

### Changed

- SLA timeout path now routes through `completePipeline(.failure(.timeout))` so the new error toast fires on timeouts instead of a bare beep
- Menu bar "Revert last correction" and About window hotkey labels are now dynamic — they follow whatever primary hotkey is set in Preferences
- Spell-check pipeline now uses an internal `NSSpellCheckerProtocol` and `SingleLanguageSpellCheckerProvider` that always passes `language:` explicitly via the 7-argument `NSSpellChecker` overloads. The previous English-only path silently relied on the mutable global `NSSpellChecker.shared.language`; v1.3 closes that footgun
- Stable code-signing identity in `project.yml` (`DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY`) so `xcodegen` regenerations no longer drop into ad-hoc signing and invalidate the Accessibility (TCC) grant on every rebuild

### Fixed

- **Swap succeeds when caret is at line start** — Previously, the Cmd+Shift+Left line-selection fallback was a no-op when the caret was already at the logical start of a line, causing the swap to fail with "No text selected". A second fallback (Cmd+Left then Cmd+Shift+Right) now selects the whole line regardless of starting caret position. BIDI-safe on both Hebrew and English layouts since macOS uses logical direction for these keystrokes
- **Outlook / rich-text field wipeout** — `kAXSelectedTextAttribute` silently succeeds in Outlook but doesn't change text; the previous `kAXValueAttribute` fallback then wrote only the translated snippet as the entire field value, deleting the rest of the email. The fallback now range-splices the translated text into the full field value using the pre-recorded selection range — surrounding content is preserved

### Migrated

- The legacy single `spellCheckEnabled` UserDefaults key (v1.2-only, never shipped) is migrated once on first launch into the two new per-language keys. The migration is guarded by `didMigrateSpellCheck_v1_3` so it runs exactly once even after a downgrade-and-re-upgrade

### Tests

- `KeySwapTests` (Swift Testing) — adds migration coverage (legacy=true / legacy=false / no-legacy / defensive: legacy + new keys both present / idempotency on second init), per-language toggle defaults, and a regression test on `SingleLanguageSpellCheckerProvider` that locks in the 7-argument-with-language overload
- `SpellCheckDecisionTests` — exhaustive gating-matrix coverage: Option+hotkey raw-swap override wins over per-language toggles for both English and Hebrew (including when Hebrew dict is missing — no toast fires on raw-swap), per-language toggles independence, missing-dict signal routing
- `TranslationContextTests` — adds a Hebrew mirror of every English `SpellCheckFilter` test and a script-aware token filter suite (Hebrew paragraph with embedded English brand → English token skipped; English paragraph with embedded Hebrew word → Hebrew token skipped)
- `ErrorFeedbackHUDTests` — 6 tests covering the four `onDismiss` behavioral contracts: timer expiry does not fire `onDismiss`; body click fires both `onDismiss` and `onClick`; X button fires `onDismiss` only; superseding a toast fires the previous `onDismiss` before replacing it

---

## [1.1.0.0] - 2026-04-14

### Added

- **CorrectionsHUD** — Transient floating panel shows every spell-check correction made during a swap (`original → replacement` rows), so you can see exactly what the app changed the moment it happens. Auto-dismisses after 3–6 seconds (adaptive based on correction count). Positions cursor-adjacent when possible; falls back to top-right of screen
- **Option+F9 — raw swap** — Swap without spell check. Skips autocorrect entirely for that swap
- **F9-to-revert while HUD is visible** — Press F9 again while the corrections HUD is showing to undo the spell-check corrections without undoing the keyboard layout swap. The HUD shows "Press F9 to revert" as a hint while the revert window is open
- **Ctrl+F9 — explicit revert** — Revert the last spell-check corrections from the keyboard regardless of HUD state (for users who prefer the explicit shortcut)
- **Clipboard-path revert** — Revert works in apps that use the clipboard-only swap path (Electron apps, VS Code, etc.) via synthesized Backspace injection

### Changed

- All print statements in the swap and spell-check pipeline are now `#if DEBUG` only — no console noise in production builds
- About window updated to document the new hotkey variants (Option+F9, Ctrl+F9 revert)

### Fixed

- Revert state auto-clears when you type after a correction — a stale revert can no longer overwrite your new input

---

## [1.0.0.0] - 2026-04-13

### Added
- **Bilingual Hebrew/English swap correction** — Press F9 to swap typed characters when letters are on the wrong keyboard layout
- **Accessibility Integration (AX)** — Native macOS accessibility API for reliable character detection and clipboard manipulation
- **Clipboard fallback mechanism** — Graceful degradation when AX is unavailable, ensuring the feature works across different macOS configurations
- **Post-swap spell check** — Optional spell checking with injectable correction provider (P3 feature)
- **Multi-layout support** — Detects and handles both Hebrew and English keyboard layouts seamlessly
- **Design system** — Comprehensive design documentation for consistent visual language across the application
- **Project structure** — Xcode-native Swift project with full Swift 6 concurrency support

### Fixed
- Cursor positioning after swap — cursor now lands at the correct position after character swap
- Shift+letter characters on Hebrew layout — characters swallowed with Shift modifier are now properly recovered
- Swift 6 concurrency warnings — project compiles clean with full concurrency checking enabled

### Known Limitations
- Requires accessibility permissions on first launch
- Works with Hebrew/English keyboard layouts (other layouts not yet supported)
- Spell check feature requires system spell check capabilities

---
