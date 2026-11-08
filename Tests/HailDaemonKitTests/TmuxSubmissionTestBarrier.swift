import Synchronization
import Testing
@testable import HailDaemonKit

extension PolicyWriteGate {
    /// Acknowledges a parked wait on a dedicated executor; the gate timeout is only a watchdog.
    func pause() async {
        await Task(executorPreference: executor) { self.suspend() }.value
    }
}

/// Pauses the first settle-floor wait and advances all submit deadlines with virtual time.
final class TmuxSettleBarrier: Sendable {
    let gate = PolicyWriteGate()
    let manual = ManualSubmitClock()
    let floor: Duration
    private let pending = Mutex(true)

    init(floor: Duration) { self.floor = floor }

    var clock: TmuxSubmitClock {
        TmuxSubmitClock(now: { self.manual.now }, sleep: { duration in
            if duration == self.floor, self.pending.withLock({ value in
                let first = value
                value = false
                return first
            }) { await self.gate.pause() }
            await self.manual.clock.sleep(duration)
        })
    }
}

/// Holds one recorded command before its responder side effect, without racing runner latency.
final class TmuxCommandBarrier: Sendable {
    let gate = PolicyWriteGate()
    private let command: String
    private let pending = Mutex(true)

    init(_ command: String) { self.command = command }

    func pause(_ arguments: [String]) async {
        guard arguments.contains(command) else { return }
        let first = pending.withLock { value in
            let first = value
            value = false
            return first
        }
        if first { await gate.pause() }
    }
}

struct TmuxCommitHarness {
    let pane = ScriptedPane()
    let runner: FakeCommandRunner
    let adapter: TmuxAdapter
    let barrier: TmuxCommandBarrier

    init(_ command: String) {
        let barrier = TmuxCommandBarrier(command)
        let pane = pane
        let runner = FakeCommandRunner(beforeResponse: { await barrier.pause($0) }, { pane.respond($0) })
        self.barrier = barrier
        self.runner = runner
        adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing(),
                              submitClock: ManualSubmitClock().clock)
    }

    func queued(_ text: String, binding: String) async throws -> Task<Void, any Error> {
        let entered = AsyncStream<Void>.makeStream()
        var arrivals = entered.stream.makeAsyncIterator()
        let gate = DeliveryAdmission.Gate(validate: { entered.continuation.yield(()) }, perform: { try $0() })
        let authority = DeliveryAuthority(admission: DeliveryAdmission(gates: [.attemptCancellation: gate]))
        let delivery = Task { try await adapter.deliver(text, to: "codex", binding: binding, authority: authority) }
        _ = try #require(await arrivals.next())
        // The actor fence follows the initial authority check and the uninterrupted enqueue actor turn.
        _ = await adapter.lastTails
        return delivery
    }
}
