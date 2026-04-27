# Design System -- KeySwap macOS

## Product Context
- **What this is:** Native macOS background daemon that corrects bilingual Hebrew/English typing errors via F9 hotkey
- **Who it's for:** Non-technical bilingual Hebrew/English users (friends and family)
- **Space/industry:** macOS keyboard/input utilities (Karabiner, Punto Switcher, etc.)
- **Project type:** Native macOS menu bar app (AppKit, LSUIElement)

## Aesthetic Direction
- **Direction:** Native Minimal
- **Decoration level:** Minimal -- system chrome does the work. No custom window chrome, gradients, or textures.
- **Mood:** Feels like it shipped with macOS. Trust comes from looking native, not fancy. Users shouldn't notice the design, they should just feel comfortable.

## Typography
- **Display/Hero:** SF Pro Bold 24pt -- used only for "KeySwap" in the About window
- **Body:** SF Pro (system default) -- .body text style
- **UI/Labels:** SF Pro (system default) -- .headline, .subheadline, .caption styles
- **Data/Tables:** SF Mono -- for any technical strings, hotkey labels
- **Code:** SF Mono
- **Loading:** System fonts, no loading required
- **Scale:** Follow Apple HIG Dynamic Type sizes:
  - Title1: 28pt
  - Title2: 22pt
  - Title3: 20pt
  - Headline: 17pt semibold
  - Body: 17pt
  - Callout: 16pt
  - Subheadline: 15pt
  - Footnote: 13pt
  - Caption1: 12pt
  - Caption2: 11pt

## Color
- **Approach:** Restrained -- one brand accent + system colors
- **Accent:** #2563EB (confident medium blue) -- brand identity, used on primary buttons, links, menu bar icon tint. Culturally neutral between Hebrew and English.
- **Success:** #22C55E (green) -- menu bar flash on successful swap (0.5s fade)
- **Error:** #EF4444 (warm red) -- error messages, failed swap states
- **Warning:** #F59E0B (amber) -- partial permission states
- **Info:** #3B82F6 (lighter blue) -- informational messages
- **Surfaces:** NSColor.windowBackgroundColor (automatic light/dark)
- **Text primary:** NSColor.labelColor (automatic light/dark)
- **Text secondary:** NSColor.secondaryLabelColor (automatic light/dark)
- **Dark mode:** Automatic via NSColor system colors. Only the accent (#2563EB) and semantic colors are fixed. Reduce accent saturation ~10% in dark mode if needed.

## Spacing
- **Base unit:** 8px
- **Density:** Comfortable
- **Scale:**
  - 2xs: 2px (hairline separators)
  - xs: 4px (tight element gaps)
  - sm: 8px (between related elements)
  - md: 12px (label-to-control)
  - lg: 20px (between sections)
  - xl: 32px (major section breaks)
  - 2xl: 48px (window padding from content edge)

## Layout
- **Approach:** Native macOS conventions (grid-disciplined within Apple HIG)
- **Window sizes:**
  - Permissions onboarding: 480x340 (single window, both permissions with status)
  - About window: 380x350 (grown from 380x320 in v1.2 to accommodate the last-swap status line)
  - Preferences window: 500x460 (grown from 500x400 in v1.3 to accommodate per-language autocorrect toggles and inline install affordance)
- **Alignment:** Left-aligned buttons, right-aligned status indicators (macOS convention)
- **Border radius:** System default (NSVisualEffectView handles this)
- **Permissions flow:** Single window with both permissions shown side-by-side, each with live status. User grants both sequentially in one window; both buttons remain active until granted.

## Motion
- **Approach:** Minimal-functional
- **Success flash:** 0.5s ease-out fade from #22C55E to normal icon tint
- **Window transitions:** Standard NSWindow animations only
- **Easing:** System default (CAMediaTimingFunction)
- **Duration:** Only the success flash is custom (500ms). Everything else uses system defaults.
- **Rule:** No custom transitions. Native macOS apps that animate too much feel wrong.

## Menu Bar Icon
- **Style:** Monochrome template image (NSImage isTemplate = true)
- **Size:** 16x16 @1x, 32x32 @2x
- **Concept:** Two overlapping characters or bidirectional arrow suggesting "keyboard swap"
- **Behavior:** macOS handles light/dark automatically via template rendering
- **States:** Normal (monochrome), success (green tint flash), error (brief red tint or system beep)

## Error Messages
- **Style:** Native NSAlert or inline label with .secondaryLabelColor
- **Tone:** Plain English, no jargon. "KeySwap needs permission to read your keyboard" not "Input Monitoring entitlement required"
- **Color:** Error text in #EF4444, warning in #F59E0B

## Bidi / RTL Rendering

KeySwap's UI chrome is English-only. User text, however, can be Hebrew (or any future RTL language). When rendering correction rows or any label that mixes RTL content with directional glyphs (arrows, brackets), use explicit Unicode bidi markers to prevent NSTextField's automatic bidi from flipping glyphs relative to the surrounding text.

- **Arrow direction:** English rows use `→` (U+2192). Hebrew rows use `←` (U+2190). Direction matches the target language's reading order.
- **Marker wrapping:** Wrap the arrow character in LRM (`\u{200E}`) inside English rows, RLM (`\u{200F}`) inside Hebrew rows. Example: `"\(word) \u{200E}\u{2192}\u{200E} \(replacement)"`. This locks the arrow's render direction regardless of paragraph bidi.
- **Do not use** `.naturalTextAlignment` for rows containing directional glyphs without markers. NSTextField infers paragraph direction from the first strong-directional character and will flip your arrow.
- **Label ordering:** for Hebrew rows, place `original` first (leftmost in source, rightmost in visual render). The ← arrow points from replacement (left) to original (right), matching the Hebrew reader's right-to-left scan: "this word (right) was replaced by that word (left)."

## Inline Action Buttons

When a settings row needs a small call-to-action (e.g., "Install…", "Learn more…"), use `NSButton` with `bezelStyle = .inline` and system font at body size. Place inline with a sub-label, not on its own row. The inline bezel reads as a link-weight affordance without the full button chrome of a `.rounded` Reset-style button. Preserves the Native Minimal aesthetic: the button earns its visual weight only by proximity to the label that describes its action.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-03 | Initial design system created | Native Minimal aesthetic, system fonts, one blue accent. Created by /design-consultation for non-technical bilingual audience. |
| 2026-04-03 | Fixed accent (#2563EB) over system accent | Brand consistency. Accent appears in few places, so mismatch with system accent is minimal. |
| 2026-04-03 | Stepped permissions onboarding | One permission per screen is less intimidating for non-technical users than a checklist. |
| 2026-04-22 | Bidi/RTL rendering rules (LRM/RLM markers around arrow glyphs) | v1.3 Hebrew spell check requires mixed Hebrew + arrow rendering in CorrectionsHUD. Unicode bidi markers prevent NSTextField auto-flip. Template for future RTL languages. |
| 2026-04-22 | Inline action button convention (`.inline` bezel) | v1.3 Preferences needs "Install…" affordance next to a sub-label. `.inline` reads as link-weight without heavy button chrome. |
