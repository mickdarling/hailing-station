import Foundation
import Testing
@testable import HailDaemonKit

/// #204: the tmux adapter's submit decision. Scripted runner only; no tmux process is spawned.
@Suite struct TmuxDeliveryCommitTests {
    private static let binding = "$2@1758230001/%2:502"

    private func keys(_ runner: FakeCommandRunner) async -> [String] {
        await runner.delivered
    }

    private func waitForFill(_ runner: FakeCommandRunner) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await runner.calls.contains { $0.contains("set-buffer") }) {
            try #require(ContinuousClock().now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitFor(_ runner: FakeCommandRunner, _ condition: @Sendable ([String]) -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !condition(await runner.calls.compactMap { $0.contains("send-keys") ? $0.last : nil }) {
            try #require(ContinuousClock().now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func cancellationAfterTheCommitPointStillCompletesTheEnter() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(50))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let delivery = Task { try await adapter.deliver("synthetic input", to: "ordinary", binding: Self.binding) }
        // The Enter invocation has started, so the delivery committed before this cancellation.
        try await waitFor(runner) { $0.contains("Enter") }
        delivery.cancel()
        try await delivery.value
        #expect(await keys(runner) == ["synthetic input", "Enter"])
    }

    @Test func cancellationBeforeTheCommitPointNeverSendsEnter() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let text = String(repeating: "a", count: 10 * TmuxAdapter.defaultChunkSize)
        let delivery = Task { try await adapter.deliver(text, to: "ordinary", binding: Self.binding) }
        try await waitForFill(runner)
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await delivery.value }
        // Let the abandoned task observe the flag and stop: the buffer is never pasted, and it is deleted.
        try await Task.sleep(for: .milliseconds(100))
        let calls = await runner.calls
        #expect(await keys(runner).isEmpty)
        #expect(calls.filter { $0.contains("set-buffer") }.count < 10)
        #expect(calls.last?.contains("delete-buffer") == true)
    }

    @Test func aDeliveryAbandonedWhileQueuedTypesNothing() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let first = Task { try await adapter.deliver("first input", to: "ordinary", binding: Self.binding) }
        try await waitForFill(runner)
        let queued = Task { try await adapter.deliver("queued input", to: "ordinary", binding: Self.binding) }
        try await Task.sleep(for: .milliseconds(5))
        queued.cancel()
        try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await keys(runner) == ["first input", "Enter"])
    }
}

/// #204 round 5, #304: text reaches a pane only as one paste, so a delivery abandoned while its buffer fills leaves
/// the pane clean. A pane left holding a pasted, unsubmitted text is tainted; that path is covered with a scripted
/// pane in `TmuxSubmitConfirmationTests.abandonmentDuringSettleSendsNoEnterAndTaintsThePane`.
@Suite struct TmuxTaintedPaneTests {
    private static let binding = "$2@1758230001/%2:502"

    @Test func anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let text = String(repeating: "a", count: 10 * TmuxAdapter.defaultChunkSize)
        let first = Task { try await adapter.deliver(text, to: "ordinary", binding: Self.binding) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await runner.calls.contains { $0.contains("set-buffer") }) {
            try #require(ContinuousClock().now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        let queued = Task { try await adapter.deliver("queued input", to: "ordinary", binding: Self.binding) }
        try await Task.sleep(for: .milliseconds(5))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await queued.value
        try await adapter.deliver("later input", to: "ordinary", binding: Self.binding)
        #expect(await runner.delivered == ["queued input", "Enter", "later input", "Enter"])
        #expect(await runner.calls.contains { $0.contains("delete-buffer") })
    }

    @Test func abandonmentBeforeAnyChunkDoesNotTaintThePane() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let first = Task { try await adapter.deliver("first input", to: "ordinary", binding: Self.binding) }
        try await Task.sleep(for: .milliseconds(5))
        let queued = Task { try await adapter.deliver("queued input", to: "ordinary", binding: Self.binding) }
        try await Task.sleep(for: .milliseconds(5))
        queued.cancel()
        try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await adapter.deliver("later input", to: "ordinary", binding: Self.binding)
        #expect(await runner.delivered == ["first input", "Enter", "later input", "Enter"])
    }
}
