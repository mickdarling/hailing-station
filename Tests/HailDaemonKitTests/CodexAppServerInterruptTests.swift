#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Provider `turn/interrupt` over actual pipes with the invented child, which dies on any non-exact thread/turn ID.
@Suite(.frozenGuardBudget) struct CodexAppServerInterruptTests {
    /// Sends one turn that stays active (no terminal) and runs `body`. When `terminal` is expected, returns the next
    /// observed kind; otherwise reads nothing more, since no further event will arrive.
    private static func withActiveTurn(
        interrupt: String, terminal: Bool = true,
        _ body: @Sendable @escaping (CodexAppServerAdapter) async throws -> Void
    ) async throws -> (adapter: CodexAppServerAdapter, kinds: [ProviderEventKind]) {
        try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(terminal: false, interrupt: interrupt),
            verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            let kinds = try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                let outcome = try await session.submit("invented input", utteranceID: UUID())
                guard case .sent = outcome else { Issue.record("not sent"); return [ProviderEventKind]() }
                #expect(try await session.next()?.event.kind == .accepted)
                _ = try await session.next() // Completed text is not turn completion.
                try await body(adapter)
                var kinds: [ProviderEventKind] = []
                if terminal, let next = try await session.next() { kinds.append(next.event.kind) }
                return kinds
            }
            return (adapter, kinds)
        }
    }

    @Test func anExactInterruptYieldsTheProvidersInterruptedTerminal() async throws {
        let (adapter, kinds) = try await Self.withActiveTurn(interrupt: "ack") { adapter in
            #expect(await adapter.interruptActiveTurn())
            #expect(await adapter.interruptActiveTurn() == false) // No active turn remains.
        }
        #expect(kinds == [.interrupted])
        #expect(await adapter.isReaped)
    }

    @Test func aTerminalArrivingBeforeTheResponseStillCounts() async throws {
        let (adapter, kinds) = try await Self.withActiveTurn(interrupt: "early") { adapter in
            #expect(await adapter.interruptActiveTurn())
        }
        #expect(kinds == [.interrupted])
        #expect(await adapter.isReaped)
    }

    /// The silent child never sends a terminal, so only the grace expiring can return; a hang hits the time limit.
    /// No wall-clock bound: it also counted child spawn and teardown, and failed on a stalled CI runner (#208).
    @Test(.timeLimit(.minutes(1)))
    func anAcceptedInterruptWithoutATerminalIsNotSuccess() async throws {
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "silent", terminal: false) { adapter in
            #expect(await adapter.interruptActiveTurn(grace: .milliseconds(300)) == false)
        }
        #expect(await adapter.isReaped)
    }

    /// The waiter is armed with exactly the caller's grace (#727), seen through the sleep seam, not wall clock.
    @Test(.timeLimit(.minutes(1)))
    func theTerminalWaiterIsArmedWithTheRequestedGrace() async throws {
        let armed = GraceRecorder()
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "silent", terminal: false) { adapter in
            await adapter.useGraceSleep { grace in armed.record(grace); try await Task.sleep(for: .milliseconds(10)) }
            #expect(await adapter.interruptActiveTurn(grace: .milliseconds(300)) == false)
        }
        #expect(armed.values == [.milliseconds(300)])
        #expect(await adapter.isReaped)
    }

    @Test func aRefusedInterruptIsNotSuccess() async throws {
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "refuse", terminal: false) { adapter in
            #expect(await adapter.interruptActiveTurn() == false)
        }
        #expect(await adapter.isReaped)
    }

    @Test func afterACompletedTurnThereIsNothingToInterrupt() async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                _ = try await session.submit("invented input", utteranceID: UUID())
                for _ in 0..<3 { _ = try await session.next() } // Accepted, text, finished.
                #expect(await adapter.interruptActiveTurn() == false)
            }
            #expect(await adapter.interruptActiveTurn() == false) // Not observing: no transport at all.
            return adapter
        }
        #expect(await adapter.isReaped)
    }

    @Test func concurrentInterruptsResolveOnceAndBothReturn() async throws {
        let (adapter, kinds) = try await Self.withActiveTurn(interrupt: "ack") { adapter in
            async let first = adapter.interruptActiveTurn()
            async let second = adapter.interruptActiveTurn()
            let results = await [first, second]
            #expect(results.filter { $0 }.count == 1)
        }
        #expect(kinds == [.interrupted])
        #expect(await adapter.isReaped)
    }

    @Test func aCancelledCallerGetsFalsePromptlyAndTheSessionSurvives() async throws {
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "silent", terminal: false) { adapter in
            let started = ContinuousClock.now
            let call = Task { await adapter.interruptActiveTurn(grace: .seconds(10)) }
            try await Task.sleep(for: .milliseconds(100)); call.cancel()
            #expect(await call.value == false)
            #expect(ContinuousClock.now - started < .seconds(5))
            let launched = await adapter.launchedChild, reaped = await adapter.isReaped
            #expect(launched && !reaped) // The lease is still alive.
        }
        #expect(await adapter.isReaped)
    }

    @Test(arguments: [Duration.zero, .seconds(11)]) func anUnboundedGraceIsRefused(grace: Duration) async throws {
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "silent", terminal: false) { adapter in
            #expect(await adapter.interruptActiveTurn(grace: grace) == false)
        }
        #expect(await adapter.isReaped)
    }
}
private final class GraceRecorder: Sendable {
    private let armed = Mutex<[Duration]>([])
    var values: [Duration] { armed.withLock { $0 } }
    func record(_ grace: Duration) { armed.withLock { $0.append(grace) } }
}

private extension CodexAppServerAdapter {
    func useGraceSleep(_ sleep: @escaping @Sendable (Duration) async throws -> Void) { graceSleep = sleep }
}
#endif
