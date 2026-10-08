import Synchronization
import Testing
@testable import HailDaemonKit

/// #304: text already pending at the cursor is never appended to.
@Suite struct TmuxStaleInputTests {
    private static let fast = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60), clearLimit: .milliseconds(120)
    )

    @Test func theSameTextAlreadyAtTheCursorIsRefusedBeforeAnyPasteAndNotTainted() async throws {
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen)
        let harness = SubmitHarness(pane, timing: Self.fast)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
        // Cleared by hand: the pane is used again, since nothing was pasted.
        pane.reset(baseline: ScriptedPane.oldScreen)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func theLastDeliveredTextStillAtTheCursorIsRefused() async throws {
        let pane = ScriptedPane()
        let harness = SubmitHarness(pane, timing: Self.fast)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        // The next look finds the last text back at the cursor (an Enter undone, a TUI that restored its input).
        pane.reset(baseline: ScriptedPane.absorbedScreen)
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("a different request", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func pendingTextThatLeavesWithinTheBoundIsWaitedForThenTheDeliveryGoesAhead() async throws {
        // #304: a frozen target still holds the last text at its cursor and submits it a moment later; the next
        // delivery (queued behind it, as back-to-back ambient dispatches are) waits instead of being dropped.
        let pane = ScriptedPane()
        let harness = SubmitHarness(pane, timing: Self.fast)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        let stale = Array(repeating: ScriptedPane.absorbedScreen, count: 4)
        // Held for four looks, then gone on two in a row; the next look is the new baseline.
        let gone = [ScriptedPane.submittedScreen, ScriptedPane.submittedScreen, ScriptedPane.submittedScreen]
        pane.reset(baseline: ScriptedPane.submittedScreen, lead: stale + gone)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter", "synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed, .confirmed])
    }

    @Test func pendingTextStillThereAtTheBoundIsRefusedWithoutAPaste() async throws {
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen, stale: .max)
        let harness = SubmitHarness(pane, timing: Self.fast)
        let start = ContinuousClock.now

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(ContinuousClock.now - start >= .milliseconds(120), "waited out the clear limit first")
        #expect(await harness.runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
    }

    @Test func aPaneReboundWhileWaitingForPendingTextGetsNoPaste() async throws {
        // #306 review: the pane is respawned (same pane id, new pid) while the pre-check waits for pending text to
        // leave the cursor. The identity is checked again right before the paste, so nothing reaches the new pane.
        let looks = Mutex(0)
        let respawned = "$1|1758230000|%1|501|claude-hail\n$2|1758230001|%2|999|codex\n"
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") {
                return CommandResult(exitCode: 0, stdout: looks.withLock { $0 } >= 2 ? respawned : twoSessions)
            }
            if arguments.contains("capture-pane") {
                let look = looks.withLock { value -> Int in value += 1; return value }
                return CommandResult(exitCode: 0, stdout: look <= 3 ? "> synthetic input\n17,0\n" : "> \n2,0\n")
            }
            return CommandResult(exitCode: 0, stdout: "")
        }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: Self.fast)

        await #expect(throws: AdapterError.rebound("codex")) {
            try await adapter.deliver("synthetic input", to: "codex", binding: "$2@1758230001/%2:502")
        }
        let calls = await runner.calls
        #expect(!calls.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })
        #expect(calls.last?.contains("delete-buffer") == true, "the filled buffer is deleted")
        // Nothing was pasted, so the original pane is not tainted.
        await #expect(throws: AdapterError.rebound("codex")) {
            try await adapter.deliver("later input", to: "codex", binding: "$2@1758230001/%2:502")
        }
    }

    @Test func aDeliveryCancelledWhileWaitingForPendingTextLeavesPromptlyAsAbandoned() async throws {
        // #306 review: cancellation during the clear wait ends it at once, with no paste and no taint.
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen, stale: .max)
        let harness = SubmitHarness(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
            settleLimit: .seconds(5), confirmLimit: .milliseconds(60), clearLimit: .seconds(10)
        ))
        let delivery = Task { try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await harness.runner.calls.filter({ $0.contains("capture-pane") }).count < 3 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(2))
        }
        let cancelled = ContinuousClock.now
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await delivery.value }
        #expect(ContinuousClock.now - cancelled < .seconds(2), "left well before the 10 s clear limit")
        #expect(await harness.runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
        // Not tainted: once the input is clear, the pane takes the next delivery.
        pane.reset(baseline: ScriptedPane.oldScreen)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func aPastePlaceholderLeftInTheInputIsRefused() async throws {
        let pane = ScriptedPane(baseline: "> [Pasted text #3 +1 lines]▌")
        let harness = SubmitHarness(pane, timing: Self.fast)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.keys.isEmpty)
    }
}

/// #304: what counts as the text at the cursor, beyond the literal tail.
@Suite struct TmuxCursorInputTests {
    private func adapter(_ pane: ScriptedPane) -> SubmitHarness {
        SubmitHarness(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
            settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
        ))
    }

    @Test func aTerminalThatEndsTheLineConfirmsWithOneEnter() async throws {
        let pane = ScriptedPane(afterEnter: [ScriptedPane.lineEndedScreen])
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }

    @Test func aPastePlaceholderAtTheCursorCountsAsTheText() async throws {
        let pane = ScriptedPane(
            typed: "> [Pasted text #2 +0 lines]▌", afterEnter: ["> [Pasted text #2 +0 lines]\n\n> ▌"]
        )
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }
}
