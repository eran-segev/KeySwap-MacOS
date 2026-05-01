---
name: Project implementation status
description: What has been built, what's next, and known blockers
type: project
---

Phase 1 (TranslationContext Swift Package) is COMPLETE.

- `TranslationContext/Package.swift` — tools version 6.0, macOS 13+
- `TranslationContext/Sources/TranslationContext/TranslationContext.swift` — full bidirectional char map, 5 capitalization rules, RTL stripping, 2000-char guard
- `TranslationContext/Tests/TranslationContextTests/TranslationContextTests.swift` — 18 test cases using Swift Testing framework

All 18 test cases validate correctly via standalone Swift script (CLI tools only, no Xcode).
Tests compile but cannot run via `swift test` without Xcode — `lib_TestingInterop.dylib` is missing from CLT.

Phase 2 (macOS app source files) are ALL written in `KeySwap/`:
- `AppState.swift` — PERMISSIONS_REQUIRED / PARTIAL / ACTIVE / DEGRADED state machine
- `GlobalHotkeyListener.swift` — CGEventTap F9/Shift+F9, SEC-1 security gate, re-entrancy guard
- `AccessibilityInteractor.swift` — AX read/write, validation (writable + 2000 char), Cmd+Shift+Left fallback
- `ClipboardManager.swift` — lazy stash, eager dataForType copy, recursive DispatchQueue polling, Cmd+V injection, clipboard restore + zero
- `LayoutSwitcher.swift` — TISCopyCurrentKeyboardInputSource detection, TISSelectInputSource switching
- `PermissionsRouter.swift` — onboarding window, AXIsProcessTrusted polling, System Settings links
- `AboutWindow.swift` — version, hotkey reminder, issue link
- `KeySwapApp.swift` — @main entry point, NSStatusItem menu bar, swap pipeline orchestration, 500ms SLA timeout, visual success flash
- `Info.plist` — LSUIElement=YES, accessibility usage description, com.ersegev.KeySwap bundle ID
- `KeySwap.entitlements` — com.apple.security.automation.apple-events only (no disable-library-validation per SEC-4)

**NEXT STEP:** Create Xcode project. User needs to install Xcode, then either:
- Open a new Xcode project, add `KeySwap/` source files, add `TranslationContext/` as local Swift Package dependency
- Or use XcodeGen once installed

**Why:** Xcode not installed on this machine (only Command Line Tools). Cannot build .app bundle without it.
**How to apply:** When user asks to build/compile/run the app, ask them to install Xcode first.

Key open items (from TODOS.md):
- Shifted-key mapping verification on actual Hebrew keyboard (Shift+numbers, Shift+punctuation)
- Verify IOHIDRequestAccess availability on macOS (Design Change 7)
- SEC-4: Test CGEventTap without disable-library-validation entitlement
