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
  - Permissions onboarding: 480x360 (compact, one permission per screen)
  - About window: 300x200 (standard macOS about size)
  - Future settings: 500x400 (standard preferences size)
- **Alignment:** Left-aligned labels, right-aligned controls (macOS convention)
- **Border radius:** System default (NSVisualEffectView handles this)
- **Permissions flow:** Stepped, one permission per screen. One clear ask at a time.

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

## Future: V2 Settings Panel
- **Hotkey configuration:** Standard macOS preferences window layout
- **Design:** Follow same system: SF Pro, system colors, blue accent on save/apply buttons
- **Extensible:** The spacing and color system scales to a preferences panel without changes

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-03 | Initial design system created | Native Minimal aesthetic, system fonts, one blue accent. Created by /design-consultation for non-technical bilingual audience. |
| 2026-04-03 | Fixed accent (#2563EB) over system accent | Brand consistency. Accent appears in few places, so mismatch with system accent is minimal. |
| 2026-04-03 | Stepped permissions onboarding | One permission per screen is less intimidating for non-technical users than a checklist. |
