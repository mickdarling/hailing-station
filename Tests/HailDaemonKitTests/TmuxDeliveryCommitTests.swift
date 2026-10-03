import Foundation
import Testing
@testable import HailDaemonKit

/// #204: the tmux adapter's submit decision. Scripted runner only; no tmux process is spawned.
@Suite struct TmuxDeliveryCommitTests {
    private static let binding = "$2@1758230001/%2:502"

    private func keys(_ runner: FakeCommandRunner) async -> [String] {
        await runner.calls.compactMap { $0.contains("send-keys") ? $0.last : nil }
    }

    private func waitFor(_ runner: FakeCommandRunner, _ condition: @Sendable ([String]) -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !condition(await keys(runner)) {
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
        try await waitFor(runner) { !$0.isEmpty }
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await delivery.value }
        // Let the abandoned task observe the flag and stop; nothing further is typed and nothing submitted.
        try await Task.sleep(for: .milliseconds(100))
        let sent = await keys(runner)
        #expect(!sent.contains("Enter"))
        #expect(!sent.contains("C-u"))
        #expect(sent.count < 10)
    }

    @Test func aDeliveryAbandonedWhileQueuedTypesNothing() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let first = Task { try await adapter.deliver("first input", to: "ordinary", binding: Self.binding) }
        try await waitFor(runner) { !$0.isEmpty }
        let queued = Task { try await adapter.deliver("queued input", to: "ordinary", binding: Self.binding) }
        try await Task.sleep(for: .milliseconds(5))
        queued.cancel()
        try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await keys(runner) == ["first input", "Enter"])
    }
}
