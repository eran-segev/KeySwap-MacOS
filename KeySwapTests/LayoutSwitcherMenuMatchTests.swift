import Testing
@testable import KeySwap

@Suite("LayoutSwitcher.evaluateMenuNode — scope + target matching")
@MainActor
struct LayoutSwitcherMenuMatchTests {

    private let scope: Set<String> = ["Format", "Edit", "Writing Direction", "Paragraph", "Text", "Text Direction"]
    private let ltrTargets = ["Left to Right", "Left-to-Right"]
    private let rtlTargets = ["Right to Left", "Right-to-Left"]

    // MARK: - Scope entry

    @Test("Top-level Format menu enters scope but doesn't match a target")
    func formatEntersScope() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Format", inScope: false, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == false)
        #expect(r.nextInScope == true)
    }

    @Test("Non-scope top-level menu stays out of scope")
    func viewStaysOutOfScope() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "View", inScope: false, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == false)
        #expect(r.nextInScope == false)
    }

    // MARK: - Target matching inside scope

    @Test("TextEdit-style 'Right to Left Paragraph' matches RTL inside scope")
    func textEditRTLMatches() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Right to Left Paragraph", inScope: true, scopeTitles: scope, targetSubstrings: rtlTargets
        )
        #expect(r.matched == true)
    }

    @Test("Mail-style 'Left to Right' matches LTR inside scope")
    func mailLTRMatches() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Left to Right", inScope: true, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == true)
    }

    @Test("Word-style hyphenated 'Left-to-Right Text Direction' matches LTR inside scope")
    func wordHyphenatedLTRMatches() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Left-to-Right Text Direction", inScope: true, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == true)
    }

    @Test("Word-style hyphenated 'Right-to-Left' matches RTL inside scope")
    func wordHyphenatedRTLMatches() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Right-to-Left", inScope: true, scopeTitles: scope, targetSubstrings: rtlTargets
        )
        #expect(r.matched == true)
    }

    // MARK: - Scope gate (the whole reason this logic exists)

    @Test("'Left to Right' does NOT match when out of scope — blocks Keynote slide transitions")
    func outOfScopeTargetDoesNotMatch() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Left to Right", inScope: false, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == false)
        #expect(r.nextInScope == false)
    }

    // MARK: - Cross-direction negatives

    @Test("RTL title does not match LTR targets")
    func rtlDoesNotMatchLTR() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Right to Left", inScope: true, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == false)
    }

    @Test("LTR title does not match RTL targets")
    func ltrDoesNotMatchRTL() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Left-to-Right", inScope: true, scopeTitles: scope, targetSubstrings: rtlTargets
        )
        #expect(r.matched == false)
    }

    // MARK: - Empty titles (AX can return nil → coerced to "")

    @Test("Empty title inside scope does not match")
    func emptyTitleDoesNotMatch() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "", inScope: true, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.matched == false)
        #expect(r.nextInScope == true)
    }

    // MARK: - Scope inheritance

    @Test("Already-in-scope node keeps scope regardless of its title")
    func scopeIsSticky() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Some Random Submenu", inScope: true, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.nextInScope == true)
    }

    @Test("Nested 'Text Direction' submenu enters scope from Word-style hierarchy")
    func textDirectionEntersScope() {
        let r = LayoutSwitcher.evaluateMenuNode(
            title: "Text Direction", inScope: false, scopeTitles: scope, targetSubstrings: ltrTargets
        )
        #expect(r.nextInScope == true)
    }
}
