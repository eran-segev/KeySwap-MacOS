import Cocoa
import Carbon
import ApplicationServices

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

        #if DEBUG
        print("[LayoutSwitcher] swapDirection: current layout = \(id)")
        #endif
        return id.contains("Hebrew") ? .hebrewToEnglish : .englishToHebrew
    }

    // MARK: - Switching

    /// Switches the keyboard layout to `target` after a successful swap.
    /// Logs a warning on failure but does not abort (swap already succeeded).
    func switchLayout(to direction: Direction) {
        // Try multiple IDs — "ABC" is the modern macOS English layout,
        // "US" is the legacy name. Hebrew may also have variants.
        let targetIDs: [String]
        switch direction {
        case .hebrewToEnglish:
            targetIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        case .englishToHebrew:
            targetIDs = ["com.apple.keylayout.Hebrew"]
        }

        #if DEBUG
        print("[LayoutSwitcher] switchLayout direction=\(direction), targetIDs=\(targetIDs)")
        #endif

        // Filter to only keyboard layouts that can be selected.
        let filter = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true,
        ] as CFDictionary

        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            #if DEBUG
            print("[LayoutSwitcher] ✗ TISCreateInputSourceList returned nil")
            #endif
            return
        }

        #if DEBUG
        let ids = sources.compactMap { src -> String? in
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        print("[LayoutSwitcher] Installed selectable layouts: \(ids)")
        #endif

        // Try each target ID in priority order
        for targetID in targetIDs {
            for source in sources {
                guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                      let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String?,
                      id == targetID else {
                    continue
                }

                let err = TISSelectInputSource(source)
                #if DEBUG
                print("[LayoutSwitcher] TISSelectInputSource(\(targetID)) → err=\(err)")
                #endif
                return
            }
        }

        // Exact match not found — try partial match (e.g. "Hebrew-QWERTY" variants)
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String? else {
                continue
            }

            let matches: Bool
            switch direction {
            case .hebrewToEnglish:
                matches = !id.contains("Hebrew")
                    && id.hasPrefix("com.apple.keylayout.")
            case .englishToHebrew:
                matches = id.contains("Hebrew")
            }

            if matches {
                let err = TISSelectInputSource(source)
                #if DEBUG
                print("[LayoutSwitcher] Fuzzy match: TISSelectInputSource(\(id)) → err=\(err)")
                #endif
                return
            }
        }

        #if DEBUG
        print("[LayoutSwitcher] ✗ No matching layout found for direction \(direction)")
        #endif
    }

    // MARK: - Paragraph writing direction
    //
    // Invoked ONLY when the swap triggered the Cmd+Shift+Left line-selection
    // fallback (i.e. we know the full paragraph is our target). Walks the
    // focused app's menu bar via AX looking for a "Right to Left" / "Left to
    // Right" leaf (typical hosts: Edit → Writing Direction → …, or
    // Format → Text → Writing Direction → …) and AXPresses it.
    //
    // SAFETY:
    //   1. Scope-gated DFS — only matches inside a subtree rooted at a
    //      menu whose title is in `scopeTitles`. Prevents firing unrelated
    //      menu items titled "Right to Left"/"Left to Right" (Keynote
    //      slide transitions, design tools, etc.).
    //   2. Idempotent — reads kAXMenuItemMarkCharAttribute on the candidate;
    //      skips the press if the target direction is already checked,
    //      otherwise we'd toggle AWAY on consecutive fallback swaps.
    //
    // Silent no-op when the menu path isn't found — non-English UI locales,
    // apps without a writing-direction menu (most Electron, Chrome, Terminal),
    // and sandboxed apps that block menu AX inspection all fall through
    // without user-visible failure. That's intentional: flipping direction
    // is a nice-to-have polish on top of a successful swap, not a contract.

    enum WritingDirectionResult {
        case flipped           // Pressed the menu item; direction changed
        case alreadyAtTarget   // Target was already checked; skipped press
        case unavailable       // No scoped menu item, AX blocked, or press failed
    }

    /// Flips paragraph writing direction to match the new keyboard layout.
    /// LTR for Hebrew→English, RTL for English→Hebrew.
    @discardableResult
    func flipWritingDirection(to direction: Direction) -> WritingDirectionResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            #if DEBUG
            print("[LayoutSwitcher] flipWritingDirection: no frontmost app")
            #endif
            return .unavailable
        }

        // Word for Mac doesn't expose writing direction in the macOS menu bar
        // (the toggle lives in the Ribbon's Home tab, which is custom-drawn
        // and not stably introspectable via AX). Use Word's AppleScript
        // dictionary instead — `right to left text` on `paragraph format`
        // is the documented property for paragraph direction.
        if app.bundleIdentifier == "com.microsoft.Word" {
            return flipWritingDirectionInWord(to: direction)
        }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            #if DEBUG
            print("[LayoutSwitcher] flipWritingDirection: no menu bar (AX blocked?)")
            #endif
            return .unavailable
        }
        let menuBarEl = menuBar as! AXUIElement

        // Substring match — apps vary in phrasing. TextEdit uses "Right to Left
        // Paragraph", Mail uses "Right to Left", Microsoft Word uses phrases
        // like "Left-to-Right Text Direction" (hyphenated). A scoped substring
        // match covers all known variants; the scope gate prevents false
        // positives (Keynote "Left to Right" slide transitions live under the
        // Slide menu, not Format/Edit).
        let targetSubstrings: [String]
        switch direction {
        case .hebrewToEnglish:
            targetSubstrings = ["Left to Right", "Left-to-Right"]
        case .englishToHebrew:
            targetSubstrings = ["Right to Left", "Right-to-Left"]
        }

        // Scope gate: only accept matches inside one of these ancestor menus.
        // "Text Direction" covers Word's submenu naming.
        let scopeTitles: Set<String> = ["Format", "Edit", "Writing Direction", "Paragraph", "Text", "Text Direction"]

        guard let item = findMenuItem(
            substrings: targetSubstrings,
            under: menuBarEl,
            depth: 0,
            inScope: false,
            scopeTitles: scopeTitles
        ) else {
            #if DEBUG
            print("[LayoutSwitcher] flipWritingDirection: no scoped match found")
            #endif
            return .unavailable
        }

        // Idempotency: if the target is already the active direction,
        // skip the press — otherwise we'd toggle AWAY.
        var markRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXMenuItemMarkCharAttribute as CFString, &markRef)
        let markString = markRef as? String ?? ""
        if !markString.isEmpty {
            #if DEBUG
            print("[LayoutSwitcher] flipWritingDirection: already at target (mark=\"\(markString)\") — skipping")
            #endif
            return .alreadyAtTarget
        }

        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        #if DEBUG
        print("[LayoutSwitcher] flipWritingDirection: pressed → err=\(err.rawValue)")
        #endif
        return err == .success ? .flipped : .unavailable
    }

    /// Word-specific paragraph direction flip. Word's macOS menu bar doesn't
    /// surface writing direction (the toggle lives in the Ribbon, which is
    /// custom-drawn and not reliably introspectable via AX). Word's
    /// AppleScript dictionary also doesn't expose paragraph direction as a
    /// settable property — `MsoTextDirection` is defined but no class uses
    /// it. The route that actually works is `run VB macro` with a built-in
    /// Word command name: `LtrPara` and `RtlPara` set paragraph direction
    /// absolutely (not toggle).
    ///
    /// First invocation triggers macOS's "KeySwap wants to control Microsoft
    /// Word" Apple Events consent prompt (NSAppleEventsUsageDescription in
    /// Info.plist explains why).
    private func flipWritingDirectionInWord(to direction: Direction) -> WritingDirectionResult {
        let commandName: String
        switch direction {
        case .hebrewToEnglish: commandName = "LtrPara"
        case .englishToHebrew: commandName = "RtlPara"
        }
        let source = """
        tell application "Microsoft Word"
            run VB macro macro name "\(commandName)"
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            #if DEBUG
            print("[LayoutSwitcher] Word direction flip: NSAppleScript init failed")
            #endif
            return .unavailable
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            #if DEBUG
            print("[LayoutSwitcher] Word direction flip (\(commandName)): AppleScript error = \(error)")
            #endif
            return .unavailable
        }
        #if DEBUG
        print("[LayoutSwitcher] Word direction flip (\(commandName)): ran")
        #endif
        return .flipped
    }

    /// Pure, testable decision for a single menu node: given its title, whether
    /// the traversal is already inside a scoped subtree, and the scope/target
    /// sets, return whether this node matches and whether descendants should
    /// inherit scope. Extracted so the scope + substring rules have unit
    /// coverage independent of AX traversal.
    static func evaluateMenuNode(
        title: String,
        inScope: Bool,
        scopeTitles: Set<String>,
        targetSubstrings: [String]
    ) -> (matched: Bool, nextInScope: Bool) {
        let matched = inScope && targetSubstrings.contains(where: { title.contains($0) })
        let nextInScope = inScope || scopeTitles.contains(title)
        return (matched, nextInScope)
    }

    /// Depth-first search for a menu item whose kAXTitleAttribute contains any of
    /// `substrings` — but ONLY once the traversal has entered a subtree rooted at
    /// an element whose title is in `scopeTitles`. Capped at depth 6.
    private func findMenuItem(
        substrings: [String],
        under element: AXUIElement,
        depth: Int,
        inScope: Bool,
        scopeTitles: Set<String>
    ) -> AXUIElement? {
        guard depth < 6 else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""

            let decision = Self.evaluateMenuNode(
                title: title,
                inScope: inScope,
                scopeTitles: scopeTitles,
                targetSubstrings: substrings
            )
            if decision.matched {
                return child
            }
            if let found = findMenuItem(substrings: substrings, under: child, depth: depth + 1, inScope: decision.nextInScope, scopeTitles: scopeTitles) {
                return found
            }
        }
        return nil
    }
}
