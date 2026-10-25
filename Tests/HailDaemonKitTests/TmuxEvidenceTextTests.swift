import Synchronization
import Testing
@testable import HailDaemonKit

/// #894 review: the evidence counts characters, matches haild's own text under the two-column reading of an
/// unknown-width character, and never treats an empty tail as matching. Scripted runner only.
@Suite struct TmuxEvidenceTextTests {
    /// Nine characters, ten scalars (`u` plus a combining diaeresis), two of them two columns wide.
    private static let text = "Zu\u{0308}rich 東京"

    /// `✅` is of unknown width (read as one column and as two); the cursor follows `京` under the two-column reading,
    /// where the one-column reading would also take in the `│` border drawn right after it.
    private static let returned = "✅ \(text)│\n14,0,80\n"
    private static let cleared = "✅ \n3,0,80\n"

    @Test func ownWideNonASCIITextBackAtTheCursorIsOwnWithItsCharacterCount() async throws {
        let screen = Mutex(Self.cleared)
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("paste-buffer") { screen.withLock { $0 = Self.returned } }
            if arguments.last == "Enter" { screen.withLock { $0 = Self.cleared } }
            if arguments.contains("capture-pane") { return CommandResult(exitCode: 0, stdout: screen.withLock { $0 }) }
            return CommandResult(exitCode: 0, stdout: "")
        }
        let harness = EvidenceHarness(runner, timing: EvidenceHarness.timing())
        try await harness.adapter.deliver(Self.text, to: "codex", binding: nil)
        #expect(harness.outcomes.all == [.confirmed])

        // The TUI puts the text back in its input.
        screen.withLock { $0 = Self.returned }
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }

        let refusal = try #require(harness.evidence.lines("tmux_input_pending").only)
        #expect(refusal.hasPrefix(
            "tmux_input_pending reason=stale_input pane=p1 pending_chars=9 placeholder=false own_insert=true own_age_s="
        ))
        #expect(refusal.hasSuffix(" own_submitted=true last_submit=confirmed"))
        harness.evidence.expectTokensOnly(excluding: [Self.text, "Zürich", "東京", "later input"])
    }

    @Test func onlyTheTwoColumnReadingFindsTheTextBeforeTheBorder() throws {
        let look = try #require(PaneObservation(captured: Self.returned))
        #expect(look.endsInTail(PayloadTail(Self.text)))
        // Under the one-column reading alone, the border would end the input.
        let narrow = look.scalarsBeforeCursor(atLeast: 32, unknownWidth: 1)
        #expect(narrow.last == "│")
    }

    @Test func anEmptyTailNeverMatches() throws {
        let look = try #require(PaneObservation(captured: Self.returned))
        #expect(!look.endsInTail(PayloadTail("   ")))
        #expect(!look.endsInTail(PayloadTail("")))
    }

    @Test func anEmptyOwnTailIsNeverReportedAsOwn() throws {
        // A tail with no visible scalars cannot come from a delivery (empty text is refused); the ledger still
        // never reports one as haild's own text at the cursor.
        let evidence = EvidenceLog()
        var ledger = TmuxEvidenceLedger(submitObserver: nil, observer: { evidence.append($0) })
        let look = try #require(PaneObservation(captured: Self.returned))

        ledger.inputPending(.staleInput, in: "%2", seen: look, own: PayloadTail(" \t "))

        #expect(evidence.lines == [
            "tmux_input_pending reason=stale_input pane=p1 pending_chars=none placeholder=false own_insert=false"
                + " own_age_s=none own_submitted=none last_submit=none"
        ])
        evidence.expectTokensOnly(excluding: [Self.text])
    }

    @Test func whitespaceOnlyTextIsRefusedAsBeforeAndLogsNothing() async throws {
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("capture-pane") { return CommandResult(exitCode: 0, stdout: Self.cleared) }
            return CommandResult(exitCode: 0, stdout: "")
        }
        let harness = EvidenceHarness(runner, timing: EvidenceHarness.timing())

        await #expect(throws: AdapterError.deliveryFailed("empty text")) {
            try await harness.adapter.deliver(" \t ", to: "codex", binding: nil)
        }

        #expect(harness.evidence.all.isEmpty)
        #expect(await runner.calls.isEmpty)
    }
}
