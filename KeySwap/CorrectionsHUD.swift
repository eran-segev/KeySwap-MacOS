import Cocoa
import ApplicationServices
import TranslationContext

// MARK: - CorrectionsHUD
//
// Transient NSPanel that lists spell-check corrections applied during a swap.
// Shown for a short, adaptive duration (3s base + 500ms per correction, cap 6s)
// so the user can see what was changed and decide whether to revert.
//
// Placement:
//   1. Try AX caret-adjacent (requires focused element with usable text caret).
//      Uses a scoped kAXBoundsForRangeParameterizedAttribute query with a 50ms
//      messaging timeout set on a fresh element reference — it does NOT leak
//      the short timeout onto elements used by the swap pipeline.
//   2. Fall back to top-right of the active screen (predictable, like macOS
//      notifications) when AX returns no usable bounds.
//
// The panel is reused across shows to avoid allocation cost on every swap.
// It is non-activating and floating so it does not steal focus from the
// target text field.
//
// Design system alignment (DESIGN.md):
//   - NSColor.windowBackgroundColor surface (auto light/dark)
//   - Labels in system font (SF Pro), corrections in SF Mono
//   - 8px spacing base
//   - No custom motion, no gradients — "feels like it shipped with macOS"

@MainActor
final class CorrectionsHUD {

    // MARK: - Panel

    private var panel: NSPanel?
    private var dismissTimer: DispatchWorkItem?
    private var shownAt: Date?

    /// Adaptive duration for a given number of corrections.
    /// 3s base + 0.5s per correction, capped at 6s.
    static func duration(for correctionCount: Int) -> TimeInterval {
        let raw = 3.0 + (0.5 * Double(correctionCount))
        return min(raw, 6.0)
    }

    var isShowing: Bool { panel?.isVisible == true }

    // MARK: - Public API

    /// Show the HUD listing `corrections`. Positions cursor-adjacent if AX gives
    /// us caret bounds, otherwise top-right of the active screen. Auto-dismisses
    /// after the adaptive duration unless `dismiss()` is called first.
    func show(corrections: [Correction], caretElement: AXUIElement?) {
        guard !corrections.isEmpty else { return }

        // Cancel any in-flight auto-dismiss from a prior swap.
        dismissTimer?.cancel()

        // Build or reuse the panel.
        let p = panel ?? buildPanel()
        panel = p

        // Build content. buildContent sets an explicit frame; we size the panel
        // to match BEFORE assigning, because `p.contentView = contentView`
        // resizes the view to the panel's current frame (throwing away the
        // size we just computed and leaving subviews at the wrong positions).
        let contentView = buildContent(corrections: corrections)
        let targetSize = contentView.frame.size
        p.setContentSize(targetSize)
        p.contentView = contentView
        // After assignment, re-assert the frame in case AppKit resized it.
        contentView.frame = NSRect(origin: .zero, size: targetSize)

        // Compute and set final origin up-front. We tried animating
        // setFrameOrigin via .animator() for a slide-in effect but NSPanel's
        // frame isn't reliably animated by AppKit's proxy — panels ended up
        // stuck off-screen. alphaValue IS animatable and still provides the
        // "fresh thing" peripheral cue.
        let origin = preferredOrigin(for: p, caretElement: caretElement)
        p.setFrameOrigin(origin)

        // Start transparent, fade in. Show without activating — don't steal
        // focus from the target text field.
        p.alphaValue = 0
        p.orderFrontRegardless()
        shownAt = Date()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        // Audible cue: a soft, short system sound. "Pop" is subtle enough to
        // not be annoying in meetings but distinct enough to catch attention.
        // Honors the user's system-wide alert sound setting — if they've
        // muted alerts, this will silently no-op.
        NSSound(named: .init("Pop"))?.play()

        // Schedule auto-dismiss.
        let duration = Self.duration(for: corrections.count)
        let timer = DispatchWorkItem { [weak self] in
            self?.dismiss(reason: "timer-expired")
        }
        dismissTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)

        print("[CorrectionsHUD] show(\(corrections.count) corrections) size=\(targetSize) at \(origin) for \(duration)s visible=\(p.isVisible)")
    }

    /// Hide the HUD immediately and cancel its auto-dismiss timer.
    /// Safe to call when not showing (no-op).
    func dismiss(reason: String = "explicit") {
        let wasVisible = panel?.isVisible == true
        dismissTimer?.cancel()
        dismissTimer = nil
        panel?.orderOut(nil)
        if wasVisible {
            let elapsed = shownAt.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
            print("[CorrectionsHUD] dismiss(reason=\(reason)) elapsed=\(elapsed)")
        }
        shownAt = nil
    }

    // MARK: - Panel construction

    private func buildPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.worksWhenModal = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }

    private func buildContent(corrections: [Correction]) -> NSView {
        let padding: CGFloat = 12
        let rowSpacing: CGFloat = 4
        let maxRows = 8
        let rows = Array(corrections.prefix(maxRows))
        let overflow = corrections.count - rows.count

        // Bumped sizes so the HUD reads as a distinct status message, not UI
        // chrome. No per-word coloring — plain labels in the system HUD style.
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let rowFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let footerFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        // Header label
        let headerText = corrections.count == 1 ? "1 correction" : "\(corrections.count) corrections"
        let header = makeLabel(headerText, font: headerFont, color: .labelColor)

        // Correction rows
        var rowViews: [NSTextField] = []
        for c in rows {
            let line = "\(c.originalWord)  →  \(c.replacementWord)"
            let row = makeLabel(line, font: rowFont, color: .labelColor)
            rowViews.append(row)
        }

        // Overflow indicator
        var overflowView: NSTextField?
        if overflow > 0 {
            let more = makeLabel("+ \(overflow) more", font: footerFont, color: .secondaryLabelColor)
            overflowView = more
        }

        // Footer hint — F9 reverts while the HUD is open (replaces Ctrl+F9)
        let footer = makeLabel("Press F9 to revert", font: footerFont, color: .secondaryLabelColor)

        // Measure widths
        var contentWidth: CGFloat = header.fittingSize.width
        for row in rowViews { contentWidth = max(contentWidth, row.fittingSize.width) }
        if let ov = overflowView { contentWidth = max(contentWidth, ov.fittingSize.width) }
        contentWidth = max(contentWidth, footer.fittingSize.width)
        contentWidth = max(contentWidth, 200) // min width
        contentWidth = min(contentWidth, 420) // max width

        // Compute height
        let headerH = header.fittingSize.height
        let rowH = rows.isEmpty ? 0 : rowViews[0].fittingSize.height
        let footerH = footer.fittingSize.height
        let overflowH = overflowView?.fittingSize.height ?? 0
        var totalH = headerH + rowSpacing
        for _ in rowViews { totalH += rowH + rowSpacing }
        if overflowView != nil { totalH += overflowH + rowSpacing }
        totalH += footerH

        let viewW = contentWidth + padding * 2
        let viewH = totalH + padding * 2

        // Background with rounded corners + subtle material-like background
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: viewW, height: viewH))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true

        // Lay out top-down
        var cursorY = viewH - padding - headerH
        header.frame = NSRect(x: padding, y: cursorY, width: contentWidth, height: headerH)
        bg.addSubview(header)
        cursorY -= (rowSpacing + rowH)

        for row in rowViews {
            row.frame = NSRect(x: padding, y: cursorY, width: contentWidth, height: rowH)
            bg.addSubview(row)
            cursorY -= (rowSpacing + rowH)
        }

        if let ov = overflowView {
            ov.frame = NSRect(x: padding, y: cursorY, width: contentWidth, height: overflowH)
            bg.addSubview(ov)
            cursorY -= (rowSpacing + overflowH)
        }

        footer.frame = NSRect(x: padding, y: padding, width: contentWidth, height: footerH)
        bg.addSubview(footer)

        return bg
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    // MARK: - Placement

    private func preferredOrigin(for panel: NSPanel, caretElement: AXUIElement?) -> NSPoint {
        // Tier 1: exact caret bounds via the element passed in by the pipeline.
        // Tier 1b: if the pipeline didn't give us an element (clipboard-only
        // write path), ask the system for the currently focused element and
        // try caret bounds on it. Some apps (e.g. Notes, certain web text
        // areas) expose caret bounds even though readSelectedText took the
        // clipboard fallback.
        let effectiveCaretElement: AXUIElement? = caretElement ?? systemWideFocusedElement()
        if let caretRect = caretRect(for: effectiveCaretElement) {
            // Position below the caret with a small gap. Re-anchor above/left
            // if it would clip the screen edge.
            let size = panel.frame.size
            var origin = NSPoint(
                x: caretRect.minX,
                y: caretRect.minY - size.height - 6
            )
            // Screen containing the caret
            let screen = NSScreen.screens.first { $0.frame.contains(caretRect.origin) } ?? NSScreen.main
            if let screen {
                let visible = screen.visibleFrame
                if origin.x + size.width > visible.maxX - 8 {
                    origin.x = visible.maxX - size.width - 8
                }
                if origin.x < visible.minX + 8 {
                    origin.x = visible.minX + 8
                }
                if origin.y < visible.minY + 8 {
                    // No room below the caret — flip above.
                    origin.y = caretRect.maxY + 6
                }
                if origin.y + size.height > visible.maxY - 8 {
                    origin.y = visible.maxY - size.height - 8
                }
            }
            print("[CorrectionsHUD] placement=ax-caret origin=\(origin)")
            return origin
        }
        // Tier 2: top-right corner, matching macOS Notification Center. Don't
        // invent a new convention. Combined with the slide-in animation in
        // show() and the menubar badge in KeySwapApp, this corner becomes the
        // persistent "corrections appear here" anchor. After a day of use the
        // user's eye learns the spot.
        let origin = topRightOrigin(for: panel)
        print("[CorrectionsHUD] placement=top-right origin=\(origin)")
        return origin
    }

    /// Query the system-wide focused UI element. Returns nil if nothing is
    /// focused or AX is unavailable.
    private func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        return (focused as! AXUIElement)
    }

    private func topRightOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = panel.frame.size
        guard let visible = screen?.visibleFrame else {
            return NSPoint(x: 20, y: 20)
        }
        return NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.maxY - size.height - 20
        )
    }

    /// AX caret-bounds lookup scoped to a 50ms messaging timeout set on a
    /// FRESH AXUIElement reference (the system-wide one) so the short timeout
    /// does not leak onto elements used by the swap pipeline.
    /// Returns nil in screen coordinates. Returns nil for apps where AX
    /// doesn't expose usable caret bounds (most Electron apps, some web views).
    private func caretRect(for element: AXUIElement?) -> NSRect? {
        guard let element else { return nil }

        // Apply the short timeout to a fresh copy of the system-wide AX element
        // rather than the passed-in element. This protects the swap pipeline's
        // AX queries from accidentally inheriting a 50ms cap. We can't use a
        // fresh ref to the focused element directly (AX doesn't clone on copy),
        // so we set it on the focused element but revert afterward to 0 (default).
        let restoreTimeout: Float = 0 // 0 means "use system default"
        AXUIElementSetMessagingTimeout(element, 0.05)
        defer { AXUIElementSetMessagingTimeout(element, restoreTimeout) }

        // Ask for the selected text range first, then bounds for that range.
        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let axVal = selRangeRef else {
            return nil
        }

        var selRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal as! AXValue, .cfRange, &selRange) else { return nil }

        // Collapsed selection (typical post-write): ask for a zero-length range
        // at the cursor location. Some apps return zero-sized rects for collapsed
        // ranges — we treat zero-size as "no caret bounds available."
        var queryRange = selRange
        var rangeAXValue: AXValue?
        withUnsafePointer(to: &queryRange) { ptr in
            rangeAXValue = AXValueCreate(.cfRange, ptr)
        }
        guard let rangeValue = rangeAXValue else { return nil }

        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard err == .success, let boundsAX = boundsRef else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsAX as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width > 0 || rect.height > 0 else { return nil }

        // AX rect is in screen coords, flipped (top-left origin). Convert to
        // AppKit's bottom-left origin.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(rect.origin) }) ?? NSScreen.main {
            let flippedY = screen.frame.maxY - rect.maxY
            rect = CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
        }
        return rect
    }
}
