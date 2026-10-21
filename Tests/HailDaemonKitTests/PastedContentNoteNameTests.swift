import Testing
@testable import HailDaemonKit

/// #689 review: rule names that filter away, even to spaces only, still count, and an unnamed rule beside named ones
/// shows as "and more" rather than vanishing. Synthetic rule names only.
@Suite struct PastedContentNoteNameTests {
    /// The validation note that `flagged` puts right after the begin marker.
    private func note(_ matched: [String], _ unchecked: [String]) throws -> String {
        let framed = try PastedContentTests.frame(spoken: "", pasted: "body")
        let begin = PastedContent.begin(PastedContentTests.token)
        return String(PastedContent.flagged(framed, (matched, unchecked)).dropFirst(begin.count + 1))
    }

    @Test func aNameThatFiltersToSpacesIsUnnamed() throws {
        #expect(try note(["удалить файлы"], []).hasPrefix("Validation: contains unnamed rules. "))
        #expect(try note([], ["удалить файлы"]).hasPrefix("Validation: not fully checked. "))
    }

    @Test func anUnnamedRuleBesideANamedOneSaysAndMore() throws {
        #expect(try note(["sudo", "删除"], []).hasPrefix("Validation: contains sudo, and more. "))
        #expect(try note(["sudo"], ["sudo", "删除"])
            .hasPrefix("Validation: contains sudo. Not fully checked: sudo, and more. "))
    }

    @Test func innerRunsOfSpacesCollapse() throws {
        #expect(try note(["a  b "], []).hasPrefix("Validation: contains a b. "))
    }
}
