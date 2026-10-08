import Testing
@testable import HailDaemonKit

/// #304: reading the text that ends at the cursor.
@Suite struct TmuxPaneObservationTests {
    private func observe(_ marked: String) throws -> PaneObservation {
        try #require(PaneObservation(captured: ScriptedPane.render(marked)))
    }

    @Test func parsesRowsAndTheTrailingCursorLine() throws {
        let observed = try #require(PaneObservation(captured: "one\ntwo\n\n\n4,1\n"))
        #expect(observed.rows == ["one", "two", "", ""])
        #expect(observed.cursorX == 4 && observed.cursorY == 1)
        #expect(PaneObservation(captured: "") == nil)
        #expect(PaneObservation(captured: "no cursor line\n") == nil)
        #expect(PaneObservation(captured: "\n-1,0\n") == nil)
        // A cursor below the captured rows gets blank rows to stand on.
        #expect(PaneObservation(captured: "a\n0,3\n")?.rows == ["a", "", "", ""])
    }

    @Test func aTailWrappedAcrossIndentedRowsStillEndsAtTheCursor() throws {
        let tail = PayloadTail("Reply: answer briefly; single-terminal fallback only).")
        let wrapped = try observe("❯ … Reply: answer briefly;\n  single-terminal fallback\n  only).▌\n──────")
        #expect(wrapped.input(tail) == .holding)
        // The same words echoed above an empty prompt are not at the cursor.
        let echoed = try observe("❯ … single-terminal fallback only).\n\n──────\n❯ ▌\n──────")
        #expect(echoed.input(tail) == .clear)
    }

    @Test func whitespaceAfterTheTailIsANewlineInTheInputAndColumnZeroIsAnEndedLine() throws {
        let tail = PayloadTail("synthetic input")
        #expect(try observe("> synthetic input\n  ▌").input(tail) == .holding)
        #expect(try observe("> synthetic input\n▌").input(tail) == .lineEnded)
        #expect(try observe("> synthetic inp▌").input(tail) == .clear)
    }

    @Test func textRightOfTheCursorIsIgnoredAndWideCharactersCountTwoColumns() throws {
        let tail = PayloadTail("ok")
        // A right-aligned prompt on the cursor row does not hide the text before the cursor.
        #expect(try observe("$ say ok▌            [main]").input(tail) == .holding)
        // `界` takes two columns, so the cursor at column 5 sits right after `ok`.
        let wide = try #require(PaneObservation(captured: "界 ok more\n5,0\n"))
        #expect(PaneObservation.prefix(of: "界 ok more", columns: 5) == "界 ok")
        #expect(wide.input(tail) == .holding)
    }

    @Test func claudeCodePastePlaceholdersCountAsHeldText() throws {
        let tail = PayloadTail("a long payload")
        #expect(try observe("❯ [Pasted text #1]▌").input(tail) == .holding)
        #expect(try observe("❯ [Pasted text #2][Pasted text #3 +1 lines]▌").input(nil) == .holding)
        #expect(try observe("❯ [Pasted text #12 +40 lines]\n  ▌").input(nil) == .holding)
        #expect(try observe("❯ [Pasted text]▌").input(nil) == .clear)
        #expect(try observe("❯ ▌").input(nil) == .clear)
    }

    @Test func theTailIsTheLastThirtyTwoVisibleScalars() {
        let tail = PayloadTail("  a b\tc " + String(repeating: "x", count: 40))
        #expect(tail.scalars.count == PayloadTail.length)
        #expect(PayloadTail("a b c").scalars.map(String.init).joined() == "abc")
    }
}
