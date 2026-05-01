# KeySwap macOS

Native macOS background daemon that corrects bilingual Hebrew/English typing errors via a configurable hotkey (default F9). Includes Preferences window, Hebrew spell check, and per-language autocorrect toggles as of v1.2.

## Documentation

Read these files before implementing anything:

1. `Documents/KeySwap Design Doc - Translation First MVP.md` — primary spec (CEO-reviewed)
2. `Documents/KeySwap Engineering Design Doc.md` — 7 design changes from eng review + security review
3. `Documents/TODOS.md` — deferred work and open verification items

## Archived docs — DO NOT USE

`Documents/Arxiv/` contains 4 obsolete documents written before the Design Doc. They have known inaccuracies (wrong clipboard approach, wrong hotkey API, incomplete AppState enum, missing features). Do not read, reference, or implement from these files. They exist only as historical record.

## Source of truth hierarchy

1. Engineering Design Doc (for the 7 design deltas + security mitigations)
2. Design Doc - Translation First MVP (for everything else)
3. TODOS.md (for deferred work)

## Design System
Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, and aesthetic direction are defined there.
Do not deviate without explicit user approval.
In QA mode, flag any code that doesn't match DESIGN.md.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming -> invoke office-hours
- Bugs, errors, "why is this broken", 500 errors -> invoke investigate
- Ship, deploy, push, create PR -> invoke ship
- QA, test the site, find bugs -> invoke qa
- Code review, check my diff -> invoke review
- Update docs after shipping -> invoke document-release
- Weekly retro -> invoke retro
- Design system, brand -> invoke design-consultation
- Visual audit, design polish -> invoke design-review
- Architecture review -> invoke plan-eng-review
- Save progress, checkpoint, resume -> invoke checkpoint
- Code quality, health check -> invoke health
