import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #306 review (Codex P1/P2, #307 item 6b): what may stop a delivery between the pre-check and the paste.
@Suite struct TmuxPrePasteTests {
    private static let binding = "$2@1758230001/%2:502"

    @Test func abandonmentDuringThePrePasteLookupStopsThePasteAndLeavesThePaneClean() async throws {
        // The cancellation lands while the identity lookup right before the paste is in flight (the second
        // `list-sessions`); the lookup itself succeeds. Nothing may be pasted after that.
        let listings = Mutex(0)
        let delivery = Mutex<Task<Void, any Error>?>(nil)
        let runner = FakeCommandRunner { arguments in
            guard arguments.contains("list-sessions") else { return CommandResult(exitCode: 0, stdout: "") }
            if listings.withLock({ value -> Int in value += 1; return value }) == 2 {
                let deadline = Date().addingTimeInterval(5)
                while delivery.withLock({ $0 == nil }), Date() < deadline { usleep(1_000) }
                delivery.withLock { $0?.cancel() }
            }
            return CommandResult(exitCode: 0, stdout: twoSessions)
        }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let task = Task { try await adapter.deliver("synthetic input", to: "codex", binding: Self.binding) }
        delivery.withLock { $0 = task }

        await #expect(throws: CancellationError.self) { try await task.value }
        let calls = await runner.calls
        #expect(!calls.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })
        #expect(calls.last?.contains("delete-buffer") == true, "the filled buffer is deleted")
        // Nothing was pasted, so the pane is not tainted.
        try await adapter.deliver("later input", to: "codex", binding: Self.binding)
        #expect(await runner.delivered == ["later input", "Enter"])
    }

    private static let short = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60), clearLimit: .milliseconds(120)
    )
    private static let patient = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60), clearLimit: .seconds(10)
    )
    /// U+2705 is wide in some terminals and narrow in others: with it before the cursor, whether text is pending
    /// there cannot be told.
    private static let unreadableRow = "\u{2705} synthetic inp▌"

    @Test func aCursorRowThatCannotBeReadIsPendingAndRefusedAtTheBoundWithNothingPasted() async throws {
        let pane = ScriptedPane(baseline: Self.unreadableRow, stale: .max)
        let harness = SubmitHarness(pane, timing: Self.short)
        let start = ContinuousClock.now

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(ContinuousClock.now - start >= .milliseconds(120), "waited out the clear limit first")
        #expect(await harness.runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
    }

    @Test func aCursorRowThatCannotBeReadIsWaitedForUntilItIsClear() async throws {
        // The row clears by look count (two clear looks in a row), so only the script ends the wait.
        let unreadable = Array(repeating: Self.unreadableRow, count: 4)
        let clear = Array(repeating: ScriptedPane.oldScreen, count: 3)
        let pane = ScriptedPane()
        pane.reset(baseline: ScriptedPane.oldScreen, lead: unreadable + clear)
        let harness = SubmitHarness(pane, timing: Self.patient)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }
}
