# Changelog

All notable changes to KeySwap for macOS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
