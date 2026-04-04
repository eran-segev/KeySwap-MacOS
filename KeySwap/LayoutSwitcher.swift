import Foundation
import Carbon

// MARK: - LayoutSwitcher
//
// Detects whether the active keyboard layout is Hebrew or English,
// and switches the layout after a successful swap.
//
// Direction detection uses TISCopyCurrentKeyboardInputSource() — unambiguous vs.
// the Unicode-range heuristic that was replaced (see Design Doc resolved decisions).

final class LayoutSwitcher {

    enum Direction {
        case hebrewToEnglish  // active layout is Hebrew → swap to English
        case englishToHebrew  // active layout is English (or other) → swap to Hebrew
    }

    // MARK: - Detection

    /// Returns the swap direction based on the current keyboard layout.
    func swapDirection() -> Direction {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String? else {
            // Default to English→Hebrew if we can't determine the layout
            return .englishToHebrew
        }

        return id.contains("Hebrew") ? .hebrewToEnglish : .englishToHebrew
    }

    // MARK: - Switching

    /// Switches the keyboard layout to `target` after a successful swap.
    /// Logs a warning on failure but does not abort (swap already succeeded).
    func switchLayout(to direction: Direction) {
        let targetID: String
        switch direction {
        case .hebrewToEnglish:
            targetID = "com.apple.keylayout.US"  // Standard US English
        case .englishToHebrew:
            targetID = "com.apple.keylayout.Hebrew"
        }

        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [AnyObject] else {
            return
        }

        for source in sources {
            let inputSource = source as! TISInputSource
            guard let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID),
                  let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String?,
                  id == targetID else {
                continue
            }

            let err = TISSelectInputSource(inputSource)
            if err != noErr {
                // Non-fatal: user can switch manually.
                // os_log intentionally omitted (SEC-7: zero logging of state that touches keyboard)
            }
            return
        }

        // Target layout not found (e.g. Hebrew not installed) — non-fatal.
    }
}
