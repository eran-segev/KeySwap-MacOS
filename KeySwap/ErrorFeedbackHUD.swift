import Cocoa
import TranslationContext

// MARK: - SwapFailureReason

enum SwapFailureReason {
    case noTextSelected
    case readOnly
    case overLimit
    case noFocusedElement
    case timeout
    case clipboardFailed

    var userMessage: String {
        switch self {
        case .noTextSelected:   return "No text selected"
        case .readOnly:         return "Field is read-only"
        case .overLimit:        return "Selection too large"
        case .noFocusedElement: return "No focused field"
        case .timeout:          return "Swap timed out"
        case .clipboardFailed:  return "Clipboard write failed"
        }
    }
}

// MARK: - SwapResult

enum SwapResult {
    case success(corrections: [Correction])
    case failure(SwapFailureReason)
}

// MARK: - ErrorFeedbackHUD
//
// Transient NSPanel for error toasts and the v1.3 missing-Hebrew-dictionary
// notice. Same construction flags as CorrectionsHUD (.nonactivatingPanel,
// .floating, hidesOnDeactivate = false, reused across shows).
//
// Two modes, gated by whether a click handler is supplied:
//
//   1. Plain error toast (existing v1.2 callers): no click handler, no X
//      button, dismisses after 2.5s. Used for swap failures.
//
//   2. Clickable notice (v1.3 Hebrew-dict-missing): caller passes onClick to
//      open System Settings. We render a small X button so the user can
//      dismiss without opening Settings.
//
// `onDismiss` contract: fires only on EXPLICIT dismissal — body click, X
// button, external `dismiss()` call, or supersede by a new toast. Does NOT
// fire on auto-timer expiry. Auto-timer is passive: the user didn't act, so
// treating it as an acknowledgement would let a looked-away user silently
// lose an install prompt (see feedback_silent_mutations).
//
// CRITICAL — focus posture (Eng Review decision 1A):
//
//   The panel STAYS .nonactivatingPanel and is shown via orderFrontRegardless().
//   It does NOT become key. Keyboard activation (Escape/Return/Space) was
//   intentionally dropped: making the panel key-capable would steal focus from
//   the user's active app mid-typing — exactly the silent-text-mutation
//   posture KeySwap exists to prevent. Keyboard-only and VoiceOver users
//   reach the same Install affordance via the Preferences window's
//   tab-reachable Install button.

@MainActor
final class ErrorFeedbackHUD {

    private var panel: NSPanel?
    private var dismissTimer: DispatchWorkItem?
    private var messageLabel: NSTextField?
    private var clickRecognizer: NSClickGestureRecognizer?
    private var closeButton: NSButton?

    /// Callbacks for the current toast. Cleared on dismiss to prevent stale
    /// invocation if the panel is reused for a plain-error toast next.
    private var onClick: (() -> Void)?
    private var onDismiss: (() -> Void)?

    var appSettings: AppSettings?

    /// Overridable in tests to speed up the auto-dismiss timer.
    var dismissDelay: TimeInterval = 2.5

    // MARK: - Public API

    /// Plain error toast — no click handler, no X button, auto-dismisses after 2.5s.
    func show(message: String) {
        showInternal(message: message, onClick: nil, onDismiss: nil)
    }

    /// Clickable notice — used by v1.3 for the missing-Hebrew-dict prompt.
    /// `onClick` fires when the user clicks the body. `onDismiss` fires on
    /// explicit dismissal only (body click, X button, supersede by new toast)
    /// — NOT on auto-timer expiry, so a looked-away user still sees the
    /// prompt on next swap.
    func showClickable(message: String, onClick: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        showInternal(message: message, onClick: onClick, onDismiss: onDismiss)
    }

    private func showInternal(message: String, onClick: (() -> Void)?, onDismiss: (() -> Void)?) {
        dismissTimer?.cancel()
        // A new toast is superseding the previous one — fire the previous
        // onDismiss first so its caller doesn't lose its acknowledgement
        // signal. Supersede counts as explicit dismissal under the contract.
        let previousDismiss = self.onDismiss
        self.onClick = onClick
        self.onDismiss = onDismiss
        previousDismiss?()

        // Always rebuild the content view because the layout differs between
        // plain (single label) and clickable (label + X button) modes. Reuse
        // the panel itself.
        let p = panel ?? buildPanel()
        panel = p

        let isClickable = onClick != nil
        let contentView = buildContent(message: message, clickable: isClickable)
        let targetSize = contentView.frame.size
        p.setContentSize(targetSize)
        p.contentView = contentView
        contentView.frame = NSRect(origin: .zero, size: targetSize)

        let origin = topRightOrigin(for: p)
        p.setFrameOrigin(origin)

        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        let timer = DispatchWorkItem { [weak self] in
            self?.dismiss(reason: .timer)
        }
        dismissTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: timer)
    }

    private enum DismissReason {
        case timer, explicit, bodyClick, xButton
    }

    /// Dismiss without firing onClick. Always fires onDismiss (if set).
    func dismiss() {
        dismiss(reason: .explicit)
    }

    private func dismiss(reason: DismissReason) {
        dismissTimer?.cancel()
        dismissTimer = nil
        let cb = onDismiss
        onDismiss = nil
        onClick = nil
        panel?.orderOut(nil)
        // Timer-dismissal is passive (the user didn't act), so it does NOT
        // fire onDismiss. Every other reason is explicit.
        if reason != .timer {
            cb?()
        }
        #if DEBUG
        print("[ErrorFeedbackHUD] dismiss(reason=\(reason))")
        #endif
    }

    // MARK: - Click handling

    @objc func contentClicked() {
        let cb = onClick
        // Fire onDismiss too — clicking the body counts as acknowledgement.
        dismiss(reason: .bodyClick)
        cb?()
    }

    @objc func closeButtonClicked() {
        // X button dismisses without firing onClick.
        dismiss(reason: .xButton)
    }

    // MARK: - Panel construction

    private func buildPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
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

    private func buildContent(message: String, clickable: Bool) -> NSView {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .labelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false

        let labelSize = label.fittingSize
        // Reserve trailing room for the X button when clickable.
        let trailingPad: CGFloat = clickable ? 32 : 12
        let viewW = max(labelSize.width + 12 + trailingPad, 200)
        let viewH = labelSize.height + 16

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: viewW, height: viewH))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true

        label.frame = NSRect(x: 12, y: 8, width: viewW - 12 - trailingPad, height: labelSize.height)
        bg.addSubview(label)
        messageLabel = label

        if clickable {
            // Click anywhere on the body fires onClick (handled by gesture
            // recognizer on the background view). The X button dismisses
            // without firing onClick.
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(contentClicked))
            bg.addGestureRecognizer(recognizer)
            clickRecognizer = recognizer

            // Pointer cursor hint — small but communicates "this is clickable".
            // Use a tracking area on the background to flip the cursor on hover.
            // Skipping for now to keep the diff small; the X button is enough.

            let close = NSButton(title: "", target: self, action: #selector(closeButtonClicked))
            close.bezelStyle = .inline
            close.isBordered = false
            close.title = ""
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
            close.imagePosition = .imageOnly
            close.contentTintColor = .secondaryLabelColor
            close.setAccessibilityLabel("Dismiss")
            close.frame = NSRect(x: viewW - 24, y: (viewH - 14) / 2, width: 14, height: 14)
            bg.addSubview(close)
            closeButton = close

            bg.setAccessibilityLabel(message)
        } else {
            clickRecognizer = nil
            closeButton = nil
        }

        return bg
    }

    // MARK: - Placement

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
}
