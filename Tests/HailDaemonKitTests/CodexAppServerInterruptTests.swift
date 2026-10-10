#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Provider `turn/interrupt` over actual pipes with the invented child, which dies on any non-exact thread/turn ID.
@Suite struct CodexAppServerInterruptTests {
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

    @Test func anAcceptedInterruptWithoutATerminalIsNotSuccess() async throws {
        let started = ContinuousClock.now
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "silent", terminal: false) { adapter in
            #expect(await adapter.interruptActiveTurn(grace: .milliseconds(300)) == false)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await adapter.isReaped)
    }

    @Test func aRefusedInterruptIsNotSuccess() async throws {
        let (adapter, _) = try await Self.withActiveTurn(interrupt: "refuse", terminal: false) { adapter in
            #expect(await adapter.interruptActiveTurn() == false)
        }
        #expect(await adapter.isReaped)
    }

    @Test func withoutAnActiveTurnNoInterruptIsSent() async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(), verifiedVersion: "0.159.0") { adapter in
            #expect(await adapter.interruptActiveTurn() == false) // The child dies on an unexpected interrupt.
            return adapter
        }
        #expect(await adapter.isReaped)
    }
}
#endif
