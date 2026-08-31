# Changelog

All notable changes to KeySwap for macOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.5] - 2026-08-31

### Fixed

- **Translated word still typed twice in Slack** — the 1.3.4 fix was aimed at the wrong mechanism. It assumed `kAXValueAttribute` was the only stale attribute and that the selection attributes could be trusted to reveal whether an AX write had landed. The Slack logs show they cannot: on Chromium/Electron fields, AX reads and writes are both serviced asynchronously by the renderer, so during the write window nothing AX reports about the field is reliable — an AX write can report success, stay invisible to every subsequent AX read, and still land. No gate built on AX state can decide whether the selection survived, which is why 1.3.4 changed nothing.

  The paste no longer asks. When the text being translated is exactly one whole logical line (the case the line-selection macro produces, and the case Slack's search box hits), the whole-line macro is replayed with real keystrokes immediately before Cmd+V. Cmd+Left, Cmd+Shift+Right and Cmd+V ride the same event queue in order, so the line is provably selected when the paste arrives and the translation replaces it rather than being appended a second time — whatever the AX writes did or didn't do.

### Changed

- `ReadResult` now carries a `SelectionOrigin` (`userSelection` / `caretToLineStart` / `wholeLine`) instead of a `fallbackMacroUsed` Bool. The write path needs to know *which* macro produced the selection, not just that one did: replaying the whole-line macro over a caret-to-line-start selection would select text that was never translated and the paste would destroy it. `usedFallbackMacro` preserves the old Bool's meaning for the writing-direction flip.

- The write path now logs its pre-write selection snapshot, the post-write selection state, and which branch the clipboard-fallback gate took (lengths and booleans only, never user text). The 1.3.4 gate logged only its suppress branch, so its logs could not distinguish "the original text is still there" from "the app would not tell us" — the two cases that need opposite fixes.

## [1.3.4] - 2026-08-31

### Fixed

- **Translated word typed twice in Slack (and any app whose `kAXValueAttribute` is a stale mirror)** — Slack's search field is an Electron `AXComboBox` whose `kAXValueAttribute` never reflects the field's real text content. Both of `write()`'s verification steps read only that one attribute, so both reported "the write didn't land" even though the `kAXSelectedTextAttribute` write had in fact replaced the selection. `write()` returned `.needsClipboardFallback`, the pipeline fired Cmd+V into a field whose selection was already consumed, and the paste appended a second copy instead of replacing anything — the user saw `YoavYoav`. The 1.3.3 fix only widened the poll budget, which cannot help when the attribute is stale rather than slow.

  Verification no longer depends on a single attribute. `write()` now also treats a consumed selection (the range moved, or the text under it changed) as proof the write landed, and every clipboard-fallback exit passes through a safety gate that re-asserts the pre-write selection and reads back what actually sits under it. If the original text is still there, the fallback proceeds — and the restored selection makes Cmd+V a replace rather than an insert. If something else is there, the write landed and the paste is suppressed. Read-backs the app can't answer keep the previous behavior, so apps that genuinely need Cmd+V (Word's note/comment panel) are unaffected.

## [1.3.3] - 2026-08-08

### Fixed

- **Double-paste of the *same* translated text in Chrome/Chromium fields** — `write()` verified its own AX writes by reading `kAXValueAttribute` immediately after setting it, with no tolerance for apps that commit the change asynchronously (the same pattern as the 1.3.2 OneNote fix below, but on the write-verification side). Chrome's text fields can lag between the AX write landing and `kAXValueAttribute` reflecting it, so the immediate re-read saw the pre-write value, wrongly concluded the write had failed, and fell through to the Cmd+V clipboard fallback — pasting the same translated text a second time on top of a write that had already succeeded. Both write-verification checks (`kAXSelectedTextAttribute` and the `kAXValueAttribute` splice) now poll for up to 100ms before declaring failure, same budget and reasoning as the selection-read poll.

## [1.3.2] - 2026-08-08

### Fixed

- **Double-paste with cursor stranded between the old and new word in OneNote** — The v1.3.1 OneNote fix polled `kAXSelectedTextAttribute` (the selection text) but never checked whether `kAXSelectedTextRangeAttribute` (the selection's offset range) had caught up. OneNote and similar canvas-based apps commit these two attributes asynchronously and independently, so the text could be readable before the range settled. Writing back against a still-collapsed range inserted the translation next to the untouched original word instead of replacing it, leaving the cursor between the two. The poll now waits for both signals to agree before trusting the selection; if they never agree it falls through to the pre-v1.3.1 safe clipboard path, same as before.

- **Info.plist version stuck at 1.3.0 (12) since the 1.3.1 release** — The v1.3.1 version bump updated `VERSION`, `CHANGELOG.md`, and `TODOS.md` but missed `KeySwap/Info.plist`, so the About window kept showing "Version 1.3.0 (12)" through the entire 1.3.1 release. Corrected to match.

## [1.3.1] - 2026-06-14

### Fixed

- **Swap now works reliably in Microsoft OneNote** — OneNote commits its AX text selection asynchronously after a key macro lands, so a single read at t+50ms saw nothing and fell through to the clipboard path, which also failed. Fixed with a polling retry: `kAXSelectedTextAttribute` is polled every 20ms for up to 100ms on both AX macro fallback paths, and the clipboard path retries after 150ms for apps that also commit their clipboard selection asynchronously.

### For contributors

- **XCTest rpath for macOS 26** — Added `@loader_path/../../MacOS` to the test target's `LD_RUNPATH_SEARCH_PATHS` so `KeySwap.debug.dylib` resolves correctly when the test bundle is loaded as a host-app plugin.

## [1.3.0] - 2026-05-21

### Fixed

- **Swap now works in Microsoft Word note and comment panels** — Word's note/comment panel incorrectly reports both `kAXSelectedTextAttribute` and `kAXValueAttribute` as non-settable even though the field accepts keyboard input and paste. KeySwap now trusts the AX role (`AXTextArea`/`AXTextField`) over the broken settable flag and attempts the write anyway — falling back to Cmd+V paste if AX is rejected at write time. Previously the panel was treated as read-only and every swap attempt silently failed.

- **Clipboard paste now reliably fires in Word note/comment panels** — The pasteboard change-count used to poll for write confirmation was captured *after* the write instead of before it. This meant the poll saw the post-write count and never detected a change, so the Cmd+V paste trigger never fired. Count is now captured before `clearContents()`.

- **Clipboard fallback for fields with no `kAXValueAttribute`** — Fields that don't expose `kAXValueAttribute` (Word notes/comments, some sandboxed fields) caused the AX-value polling loop to compare `nil == nil` on every tick and never resolve. These fields now use a fixed 150 ms wait — generous enough for the paste to land, short enough to stay responsive.

- **Writing direction in Word note/comment panels** — The VBA macro used to flip paragraph direction fails in Word's note/comment panel context (error −1708, wrong AppleScript context). KeySwap now falls back to a generic menu-bar AX traversal that finds the active "Format → Writing Direction" item regardless of focus context.

- **Spurious AX write success from Word's kAXValueAttribute path** — Word's note/comment panel accepts `kAXValueAttribute` writes, returns success, but silently ignores them. KeySwap now re-reads the value after writing and routes to the Cmd+V clipboard path if the value didn't change.

- **Chromium direction flip now consistent across all swap paths** — The Chromium browser check was re-evaluated inside the async clipboard-only closure, so an app switch during a long paste could cause the direction flip to fire on the wrong app. Now captured once at pipeline start and used by all branches.

- **ASCII apostrophe swaps correctly in Hebrew→English** — Apps and some keyboards substitute ASCII apostrophe U+0027 for the Hebrew Geresh character U+05F3 (the `w` key on the Hebrew layout). The mapping table now handles both — `'יט` correctly swaps to `why`.

---

## [1.2.2.0] - 2026-05-06

### Fixed

- **Version number now shows correctly in About window** — The About window was displaying `1.2.1` instead of the current version. Fixed by updating `CFBundleShortVersionString` in Info.plist to `1.2.2` (Apple requires three-part versions in this key; the full four-part version is tracked in the `VERSION` file).

- **Single-instance enforcement** — KeySwap now prevents multiple instances from running simultaneously. A second launch will activate the already-running instance and show a brief "KeySwap is already running" dialog before exiting. Previously, two instances could coexist silently, causing duplicate hotkey listeners and unpredictable swap behavior. Enforced both at the OS level (`LSMultipleInstancesProhibited`) and via a runtime check on launch.

### Added

- **DMG now includes drag-to-Applications shortcut** — The installer DMG contains a shortcut to `/Applications` alongside `KeySwap.app`, so installation is a single drag without needing to open a separate Finder window. Standard macOS install pattern.

- **Release script (`scripts/release.sh`)** — New helper script that bumps all version fields (`VERSION` file, `CFBundleShortVersionString`, `CFBundleVersion`) in one command, then prints step-by-step instructions for building and packaging the release. Eliminates the manual version-field drift that caused the 1.2.1 display bug.

- **DMG build script (`scripts/build-dmg.sh`)** — Creates a distributable DMG with the Applications symlink from a built `.app`. Takes `<path-to-app> <version>` as arguments. Safe to re-run (overwrites existing DMG).

---

## [1.2.1.1] - 2026-05-06

### Fixed

- **Text direction in Chrome browsers** — Paragraph direction (RTL/LTR) now flips correctly when swapping in Gmail, Google Docs, Microsoft Edge, Brave, and other Chromium-based browsers. Chrome renders text via Blink rather than NSTextView, so it doesn't expose a "Format → Writing Direction" menu via the macOS accessibility API. KeySwap now uses AppleScript to execute a small JavaScript snippet that sets `style.direction` on the focused contenteditable element directly.

---

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
