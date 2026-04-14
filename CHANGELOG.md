# Changelog

All notable changes to KeySwap for macOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
