import Testing
@testable import HailDaemonKit

/// #894 ask 1: reading the prompt draft a flush would clear, and how many backspaces clear it. Synthetic screens only.
@Suite struct TmuxFlushDraftTests {
    private func look(_ marked: String) throws -> PaneObservation {
        try #require(PaneObservation(captured: ScriptedPane.render(marked)))
    }

    private func draft(_ marked: String) throws -> TmuxPromptDraft {
        try look(marked).promptDraft()
    }

    @Test func theDraftIsTheCursorRowAfterEitherMarker() throws {
        for marked in ["❯ ZULIP▌", "> ZULIP▌", "│ > ZULIP▌     │", "────\n❯ ZULIP▌\n────\n  ? for shortcuts"] {
            let found = try draft(marked)
            #expect(found.text == "ZULIP", "\(marked)")
            #expect(!found.cursorAtStart && !found.isEmpty)
        }
        // The cursor anywhere in the draft reads the whole row, text right of the cursor included.
        #expect(try draft("❯ ZU▌LIP").text == "ZULIP")
        // A non-breaking space after the marker is a marker too.
        #expect(try draft("❯\u{00A0}ZULIP▌").text == "ZULIP")
    }

    @Test func trailingBlanksAreTrimmedFromTheTextButCountedAsBackspaces() throws {
        let found = try draft("❯ hello   ▌")
        #expect(found.text == "hello")
        // A capture drops trailing blanks; the cursor after the End still counts them: five letters and three blanks.
        let trimmed = PaneObservation(rows: ["❯ hello"], cursorX: 10, cursorY: 0, width: 80)
        #expect(try trimmed.promptDraft().text == "hello")
        #expect(trimmed.backspaces(clearing: found) == 8)
        #expect(PaneObservation(rows: ["❯ hello"], cursorX: 7, cursorY: 0, width: 80).backspaces(clearing: found) == 5)
    }

    @Test func wideAndNonASCIICharactersCountOneBackspaceEach() throws {
        // tmux reports the cursor in columns: each CJK character is two, an accented letter one.
        let wide = PaneObservation(rows: ["❯ 日本語"], cursorX: 8, cursorY: 0, width: 80)
        let wideDraft = try wide.promptDraft()
        #expect(wideDraft.text == "日本語")
        #expect(wide.backspaces(clearing: wideDraft) == 3)
        let accented = PaneObservation(rows: ["❯ café"], cursorX: 6, cursorY: 0, width: 80)
        #expect(accented.backspaces(clearing: try accented.promptDraft()) == 4)
        // A character of uncertain width (✓) is one character whether the terminal drew it one or two columns wide.
        for cursor in [6, 7] {
            let check = PaneObservation(rows: ["❯ ok ✓"], cursorX: cursor, cursorY: 0, width: 80)
            #expect(check.backspaces(clearing: try check.promptDraft()) == 4)
        }
        // A cursor left inside the draft clears only what is before it, never more than is there.
        let inside = PaneObservation(rows: ["❯ 日本語"], cursorX: 5, cursorY: 0, width: 80)
        #expect(inside.backspaces(clearing: wideDraft) == 1)
    }

    @Test func anEmptyPromptHasNothingToClear() throws {
        #expect(try draft("❯ ▌").isEmpty)
        #expect(try draft("> ▌").isEmpty)
        // A capture drops the space after the marker; the cursor stays where the draft would start.
        #expect(try PaneObservation(rows: ["❯"], cursorX: 2, cursorY: 0, width: 80).promptDraft().isEmpty)
        // An agent's greyed hint reads as text with the cursor at its start, which is not empty, and End cannot
        // move past it, so a look after the End clears nothing.
        let hint = try look("❯ ▌Try \"fix lint errors\"")
        let found = try hint.promptDraft()
        #expect(found.cursorAtStart && !found.isEmpty)
        #expect(hint.backspaces(clearing: found) == 0)
    }

    @Test func theLiveInputIsTheCursorRowNotAnEarlierMarkerRow() throws {
        let screen = "❯ an earlier prompt\n\n  ⏺ working…\n────\n❯ live draft▌\n────\n  ? for shortcuts"
        let found = try draft(screen)
        #expect(found.text == "live draft" && found.row == 4)
        let ended = try look(screen)
        #expect(ended.backspaces(clearing: found) == 10)
        // The row is found by the cursor alone, never by searching for the first or last marker.
        #expect(try draft("❯ an earlier prompt▌\n────\n❯ live draft\n────").text == "an earlier prompt")
    }

    @Test func aDraftOnMoreThanOneRowIsRefused() throws {
        // The cursor on a continuation row: no marker there.
        #expect(throws: TmuxFlushRefusal.noMarker) { try draft("❯ first line\n  second line▌\n────") }
        // The cursor on the first row of several, plain and boxed.
        #expect(throws: TmuxFlushRefusal.multiLine) { try draft("❯ first▌ line\n  second line\n────") }
        #expect(throws: TmuxFlushRefusal.multiLine) { try draft("❯ first▌\n\n  third\n────") }
        #expect(throws: TmuxFlushRefusal.multiLine) { try draft("│ > first▌    │\n│   second   │\n╰──────╯") }
        // Rows below the input's bottom rule are the agent's hints, not the draft.
        #expect(try draft("│ > first▌    │\n╰──────╯\n    ? for shortcuts").text == "first")
    }

    @Test func aPastePlaceholderIsRefused() throws {
        for marked in ["❯ [Pasted text #1 +12 lines]▌", "❯ see [Pasted text #3]▌", "> [Image #2] what is this▌"] {
            #expect(throws: TmuxFlushRefusal.placeholder, "\(marked)") { try draft(marked) }
        }
    }

    @Test func aCursorRowWithoutAMarkerIsRefused() throws {
        for marked in ["$ ls▌", "  > quoted line▌", "❯ZULIP▌", "hello ❯ ZULIP▌", "▌", "│  > indented▌"] {
            #expect(throws: TmuxFlushRefusal.noMarker, "\(marked)") { try draft(marked) }
        }
        // A cursor left of where the draft starts is not at the prompt.
        #expect(throws: TmuxFlushRefusal.noMarker) {
            try PaneObservation(rows: ["❯ ZULIP"], cursorX: 1, cursorY: 0, width: 80).promptDraft()
        }
    }

    @Test func logLinesAreTokensAndCountsOnly() {
        let remainders: [TmuxFlushResult.Remainder] = [
            .textLeft, .textAfterCursor, .blankBeforeCursor, .noPrompt, .unreadable
        ]
        let refusals: [TmuxFlushRefusal] = [.unreadable, .notAgent, .noMarker, .multiLine, .placeholder, .changed]
        let lines = [TmuxFlushResult(clearedCharacters: 5, remainder: .empty).logLine]
            + remainders.map { TmuxFlushResult(clearedCharacters: 2, remainder: $0).logLine }
            + refusals.map(\.logLine)
        #expect(lines.first == "targets_flush cleared_chars=5 result=empty reason=none")
        for line in lines {
            #expect(line.wholeMatch(
                of: #/targets_flush cleared_chars=\d+ result=(empty|not_empty|refused) reason=[a-z_]+/#
            ) != nil, "\(line)")
        }
    }
}
