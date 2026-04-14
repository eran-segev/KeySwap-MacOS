# QA Report — KeySwap macOS
**Date:** 2026-04-14  
**Branch:** UX-design-improvement  
**Scope:** Diff vs `main` (1 commit: `feat: add CorrectionsHUD with visible corrections and revert support (v1.1)`)  
**Tier:** Standard  
**Mode:** Diff-aware (native macOS app — no browser)

---

## Summary

| Metric | Value |
|--------|-------|
| Build | PASS |
| Tests | 36/36 pass |
| Issues found | 2 |
| Fixed (verified) | 2 |
| Deferred | 0 |
| Health score baseline | 65/100 |
| Health score final | 85/100 |

**PR Summary:** QA found 2 issues, fixed 2. Health score 65 → 85.

---

## Issues Found and Fixed

### ISSUE-001 — HUD timer at "DEV doubled" values (HIGH)
**Status:** ✅ Fixed — commit `d89a541`  
**File:** `KeySwap/CorrectionsHUD.swift:38-44`  
**Severity:** High  
**Category:** Functional

The `CorrectionsHUD.duration(for:)` function had a comment explicitly reading
"DEV: doubled… Revert before ship." The values were 6s base + 1s/correction capped
at 12s — twice the intended production values.

**Before:**
```swift
/// DEV: doubled from 3s+0.5s/correction (cap 6s) to 6s+1s/correction (cap 12s)
/// while we tune visibility. Revert before ship.
static func duration(for correctionCount: Int) -> TimeInterval {
    let raw = 6.0 + (1.0 * Double(correctionCount))
    return min(raw, 12.0)
}
```

**After:**
```swift
/// 3s base + 0.5s per correction, capped at 6s.
static func duration(for correctionCount: Int) -> TimeInterval {
    let raw = 3.0 + (0.5 * Double(correctionCount))
    return min(raw, 6.0)
}
```

**User impact:** HUD would have lingered on screen for up to 12s per swap. Annoying
in practice, especially in meetings or while taking notes.

---

### ISSUE-002 — `learnWord()` permanently mutates system-wide spell dictionary (HIGH)
**Status:** ✅ Fixed — commit `d89a541`  
**File:** `KeySwap/KeySwapApp.swift:105-113`  
**Severity:** High  
**Category:** Security/Data integrity

`warmUpSpellChecker()` called `NSSpellChecker.shared.learnWord(name)` for 20 Hebrew
transliterated names (Dvir, Tzvi, Noa, etc.). `learnWord()` writes to the system-wide
user dictionary — the same dictionary used by Notes, Mail, Slack, and every other app.

TODOS.md explicitly calls this pattern out as prohibited for the upcoming Correction
Learning Loop feature: "learnWord writes to the system-wide spell dictionary and
pollutes every app on the Mac."

**Before:** 20 `learnWord()` calls at every app launch (guarded by `hasLearnedWord`
but still permanent on first run).

**After:** Warm-up retained (IPC daemon wake); `learnWord()` calls removed entirely.
A comment documents why and where this concern belongs.

**User impact:** Without the fix, installing KeySwap would have silently added 20 words
to the system dictionary, making names like "Tzvi" and "Dvir" appear as correctly
spelled in Mail, Word, and every other macOS app — without the user's knowledge or
consent.

---

## Code Quality Observations (no fix required)

**Clipboard-only revert backspace chain:** `ClipboardManager.replaceLastNCharsWithPaste`
uses recursive `asyncAfter` with 8ms gaps. For a 100-character corrected text this
would take ~800ms just to backspace. In practice, spell corrections are 1-8 chars so
this is fine. If it ever becomes a problem the fix is a single `CGEventPost` batch.
Documented in TODOS.md under P3 QA matrix item.

**AX messaging timeout scope:** `CorrectionsHUD.caretRect(for:)` temporarily sets a
50ms messaging timeout on the pipeline's AX element and restores it via `defer`. The
`defer` guard is correct and protects the pipeline. Worth watching for apps where AX
queries are slow.

**About window size:** DESIGN.md specifies 300x200; the window is now 380x320 to
accommodate three hotkey hint rows. This was already a violation before this branch
(360x260). Flagged, not fixed — the content justifies the size. A future cleanup
should update DESIGN.md to reflect the actual intended size.

---

## Unchanged Files — No Regressions Found

- `GlobalHotkeyListener.swift` — hotkey routing + pendingRevert clearing on non-F9
  keydown: logic is correct
- `AppState.swift` — `setPendingRevert`/`clearPendingRevert` timer hygiene: correct
- `SpellCheckFilter.swift` — back-to-front correction pass + correction tracking: correct
- `SpellCheckFilterTests.swift` — all 36 tests pass including new correction-tracking
  assertions
- `AccessibilityInteractor.swift` — new `currentSelectionRange`/`setSelectionRange`
  helpers: correct
- `CorrectionsHUD.swift` — placement logic (AX caret → top-right fallback),
  panel reuse, alpha fade-in: correct

---

## Build + Test Results

```
** BUILD SUCCEEDED **
Test run with 36 tests in 8 suites passed after 0.002 seconds.
```
