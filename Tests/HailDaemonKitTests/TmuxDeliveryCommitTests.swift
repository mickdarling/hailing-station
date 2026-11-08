import Testing
@testable import HailDaemonKit

/// #204: the tmux adapter's submit decision. Scripted runner only; no tmux process is spawned.
@Suite struct TmuxDeliveryCommitTests {
    private static let binding = "$2@1758230001/%2:502"

    @Test func cancellationAfterTheCommitPointStillCompletesTheEnter() async throws {
        let rig = TmuxCommitHarness("send-keys")
        defer { rig.barrier.gate.fire() }
        let delivery = Task { try await rig.adapter.deliver("synthetic input", to: "codex", binding: Self.binding) }
        try await rig.barrier.gate.waitUntilSuspended()
        #expect(await rig.runner.calls.last?.last == "Enter")
        #expect(await rig.runner.delivered == ["synthetic input"])
        #expect(rig.pane.enters == 0, "the recorded Enter has not performed its side effect")
        delivery.cancel()
        #expect(rig.pane.enters == 0)
        try await rig.barrier.gate.finish(delivery)
        #expect(rig.pane.enters == 1)
        let screen = rig.pane.respond(["capture-pane"]).stdout
        let observation = try #require(PaneObservation(captured: screen))
        #expect(!observation.pending(PayloadTail("synthetic input")))
        #expect(await rig.runner.delivered == ["synthetic input", "Enter"])
        try await rig.adapter.deliver("later input", to: "codex", binding: Self.binding)
        #expect(await rig.runner.delivered == ["synthetic input", "Enter", "later input", "Enter"])
    }

    @Test func cancellationBeforeTheCommitPointNeverSendsEnter() async throws {
        let rig = TmuxCommitHarness("set-buffer")
        defer { rig.barrier.gate.fire() }
        let text = String(repeating: "a", count: 10 * TmuxAdapter.defaultChunkSize)
        let delivery = Task { try await rig.adapter.deliver(text, to: "codex", binding: Self.binding) }
        try await rig.barrier.gate.waitUntilSuspended()
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await rig.barrier.gate.finish(delivery) }
        let calls = await rig.runner.calls
        #expect(await rig.runner.delivered.isEmpty)
        #expect(calls.filter { $0.contains("set-buffer") }.count < 10)
        #expect(calls.last?.contains("delete-buffer") == true)
    }

    @Test func aDeliveryAbandonedWhileQueuedTypesNothing() async throws {
        let rig = TmuxCommitHarness("set-buffer")
        defer { rig.barrier.gate.fire() }
        let first = Task { try await rig.adapter.deliver("first input", to: "codex", binding: Self.binding) }
        try await rig.barrier.gate.waitUntilSuspended()
        let queued = try await rig.queued("queued input", binding: Self.binding)
        queued.cancel()
        try await rig.barrier.gate.finish(first)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await rig.runner.delivered == ["first input", "Enter"])
    }
}

/// #204 round 5, #304: abandoning preparation leaves the pane clean; submit failures retain sticky refusal.
@Suite struct TmuxTaintedPaneTests {
    private static let binding = "$2@1758230001/%2:502"

    @Test func anAttemptAbandonedWhileFillingLeavesThePaneCleanForTheQueuedAndLaterDeliveries() async throws {
        let rig = TmuxCommitHarness("set-buffer")
        defer { rig.barrier.gate.fire() }
        let text = String(repeating: "a", count: 10 * TmuxAdapter.defaultChunkSize)
        let first = Task { try await rig.adapter.deliver(text, to: "codex", binding: Self.binding) }
        try await rig.barrier.gate.waitUntilSuspended()
        let queued = try await rig.queued("queued input", binding: Self.binding)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await rig.barrier.gate.finish(first) }
        try await queued.value
        try await rig.adapter.deliver("later input", to: "codex", binding: Self.binding)
        #expect(await rig.runner.delivered == ["queued input", "Enter", "later input", "Enter"])
        #expect(await rig.runner.calls.contains { $0.contains("delete-buffer") })
    }

    @Test func abandonmentBeforeAnyChunkDoesNotTaintThePane() async throws {
        let rig = TmuxCommitHarness("set-buffer")
        defer { rig.barrier.gate.fire() }
        let first = Task { try await rig.adapter.deliver("first input", to: "codex", binding: Self.binding) }
        try await rig.barrier.gate.waitUntilSuspended()
        let queued = try await rig.queued("queued input", binding: Self.binding)
        queued.cancel()
        try await rig.barrier.gate.finish(first)
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await rig.adapter.deliver("later input", to: "codex", binding: Self.binding)
        #expect(await rig.runner.delivered == ["first input", "Enter", "later input", "Enter"])
    }
}
