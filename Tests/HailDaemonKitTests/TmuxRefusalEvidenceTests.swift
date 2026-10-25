import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #894: why tmux refused a delivery, and what haild's own last insert there did, reach the error log as tokens.
/// Scripted panes only; no tmux process is spawned.
@Suite struct TmuxRefusalEvidenceTests {
    private static let synthetic = "synthetic input"
    private static func timing(settleLimit: Duration = .seconds(5), settleFloor: Duration = .milliseconds(1))
        -> TmuxSubmitTiming {
        EvidenceHarness.timing(settleLimit: settleLimit, settleFloor: settleFloor)
    }

    @Test func aConfirmedInsertThatCameBackIsNamedStaleAndOwnWithItsLengthAndAge() async throws {
        // The #894 shape: the Enter was confirmed, then the TUI put the text back in its input.
        let pane = ScriptedPane()
        let harness = EvidenceHarness(pane, timing: Self.timing())
        try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)
        // A forced delay, so the age is a whole second at least.
        try await Task.sleep(for: .milliseconds(1_100))
        pane.reset(baseline: ScriptedPane.absorbedScreen)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("a different request", to: "codex", binding: nil)
        }

        #expect(await harness.keys == [Self.synthetic, "Enter"], "behaviour unchanged: refused before any paste")
        #expect(harness.evidence.lines("tmux_submit") == ["tmux_submit pane=p1 outcome=confirmed"])
        let refusal = try #require(harness.evidence.lines("tmux_input_pending").only)
        let age = try #require(refusal.firstMatch(of: #/ own_age_s=(\d+) /#).flatMap { Int($0.1) })
        #expect((1...30).contains(age), "monotonic age of the own insert, in whole seconds")
        #expect(refusal == "tmux_input_pending reason=stale_input pane=p1 pending_chars=15 placeholder=false"
            + " own_insert=true own_age_s=\(age) own_submitted=true last_submit=confirmed")
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, "a different request"])
    }

    @Test func anUnverifiedSubmitLeftAtTheCursorIsNamedWithItsOutcome() async throws {
        // A frozen pane: one Enter, outcome unverifiable, success; the text still there refuses the next one.
        let harness = EvidenceHarness(ScriptedPane(afterEnter: [ScriptedPane.typedScreen]), timing: Self.timing())
        try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }

        let refusal = try #require(harness.evidence.lines("tmux_input_pending").only)
        #expect(refusal.hasPrefix("tmux_input_pending reason=stale_input pane=p1 pending_chars=15 placeholder=false"
            + " own_insert=true own_age_s="))
        #expect(refusal.hasSuffix(" own_submitted=true last_submit=unverifiable"))
        #expect(harness.outcomes.all == [.unverifiable])
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, "later input"])
    }

    @Test func textTheOwnerTypedIsNeverTakenForHaildsOwn() async throws {
        // A different draft at the cursor is not detected at all (unchanged): no refusal, so nothing is named.
        let draft = "owner draft"
        let pane = ScriptedPane(baseline: "> \(draft)▌")
        let harness = EvidenceHarness(pane, timing: Self.timing())
        try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)
        #expect(harness.evidence.lines("tmux_input_pending").isEmpty)

        // The owner then types exactly the next text haild is asked to send: refused, and not haild's own,
        // although haild has a last insert in that pane.
        pane.reset(baseline: "> later input▌")
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }
        let refusal = try #require(harness.evidence.lines("tmux_input_pending").only)
        #expect(refusal.hasPrefix(
            "tmux_input_pending reason=stale_input pane=p1 pending_chars=none placeholder=false own_insert=false"
        ))
        #expect(refusal.hasSuffix(" own_submitted=true last_submit=confirmed"))
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, draft, "later input"])
    }

    @Test func theSameTextTypedIntoAFreshPaneIsNotOwnAndHasNoInsertToDescribe() async throws {
        let harness = EvidenceHarness(
            ScriptedPane(baseline: ScriptedPane.typedScreen, stale: .max), timing: Self.timing()
        )

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)
        }

        #expect(harness.evidence.lines == [
            "tmux_input_pending reason=stale_input pane=p1 pending_chars=none placeholder=false own_insert=false"
                + " own_age_s=none own_submitted=none last_submit=none"
        ])
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic])
    }

    @Test func aPastePlaceholderIsNamedAsOne() async throws {
        let harness = EvidenceHarness(ScriptedPane(baseline: "> [Pasted text #3 +1 lines]▌"), timing: Self.timing())

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)
        }

        #expect(harness.evidence.lines == [
            "tmux_input_pending reason=stale_input pane=p1 pending_chars=none placeholder=true own_insert=false"
                + " own_age_s=none own_submitted=none last_submit=none"
        ])
    }

    @Test func textThatAppearsWhileTheBufferFillsIsNamedAppeared() async throws {
        let screen = Mutex("> \n2,0,80\n")
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("set-buffer") { screen.withLock { $0 = "> ZULIP\n7,0,80\n" } }
            if arguments.contains("capture-pane") { return CommandResult(exitCode: 0, stdout: screen.withLock { $0 }) }
            return CommandResult(exitCode: 0, stdout: "")
        }
        let harness = EvidenceHarness(runner, timing: Self.timing())

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("ZULIP", to: "codex", binding: nil)
        }

        #expect(!(await runner.calls).contains { $0.contains("paste-buffer") }, "behaviour unchanged: no paste")
        #expect(harness.evidence.lines == [
            "tmux_input_pending reason=appeared pane=p1 pending_chars=none placeholder=false own_insert=false"
                + " own_age_s=none own_submitted=none last_submit=none"
        ])
        harness.evidence.expectTokensOnly(excluding: ["ZULIP"])
    }

    @Test func aPaneTaintedByAFailedSubmitIsNamedTainted() async throws {
        let pane = ScriptedPane(afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.absorbedTwiceScreen])
        let harness = EvidenceHarness(pane, timing: Self.timing())
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)
        }
        // The owner clears the input by hand; the taint (until a restart) still refuses, with no look taken, so
        // nothing is claimed about the cursor.
        pane.reset(baseline: ScriptedPane.oldScreen)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }

        #expect(harness.evidence.lines("tmux_submit") == ["tmux_submit pane=p1 outcome=failed"])
        let refusal = try #require(harness.evidence.lines("tmux_input_pending").only)
        #expect(refusal.hasPrefix(
            "tmux_input_pending reason=tainted pane=p1 pending_chars=none placeholder=none own_insert=unobserved"
                + " own_age_s="
        ))
        #expect(refusal.hasSuffix(" own_submitted=true last_submit=failed"))
        #expect(await harness.keys == [Self.synthetic, "Enter", "Enter"])
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, "later input"])
    }

    @Test func aPaneTaintedByAnAbandonedPasteShowsNoSubmit() async throws {
        // The pane draws the pasted text only once the test has cancelled, so the settle is still waiting when the
        // cancel lands: after the paste and before the commit, by structure rather than by a race against the clock.
        let pasted = Mutex(false)
        let drawn = Mutex(false)
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("paste-buffer") { pasted.withLock { $0 = true } }
            if arguments.contains("capture-pane") {
                let shown = pasted.withLock { $0 } && drawn.withLock { $0 }
                return CommandResult(exitCode: 0, stdout: shown ? "> synthetic input\n17,0\n" : "> \n2,0\n")
            }
            return CommandResult(exitCode: 0, stdout: "")
        }
        // The settle limit is never reached: the text is drawn right after the cancel.
        let harness = EvidenceHarness(runner, timing: Self.timing(settleLimit: .seconds(60)))
        let delivery = Task { try await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil) }
        // The repo's bounded wait (15 s), not a tight deadline: a loaded runner may take seconds to reach the paste.
        try #require(await eventually { await !runner.delivered.isEmpty })
        delivery.cancel()
        drawn.withLock { $0 = true }
        await #expect(throws: CancellationError.self) { try await delivery.value }
        // Where the cancel landed: the text was pasted, and no Enter ever followed.
        #expect(await runner.delivered == [Self.synthetic])

        // Pasted and never known submitted: the pane is tainted.
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }

        let refusal = try #require(harness.evidence.lines.only)
        #expect(refusal.hasPrefix(
            "tmux_input_pending reason=tainted pane=p1 pending_chars=none placeholder=none own_insert=unobserved"
        ))
        #expect(refusal.hasSuffix(" own_submitted=false last_submit=none"))
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, "later input"])
    }
}
