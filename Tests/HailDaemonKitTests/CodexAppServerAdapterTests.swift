#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit
@Suite struct CodexAppServerAdapterTests {
    @Test func actualRegisteredGuardedPathReconcilesHeldPreResponseEvents() async throws {
        let gate = try CodexFixtureGate(); defer { try? gate.remove() }
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(gate: gate), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                let utterance = UUID()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let outcome = try await session.submit("invented input", utteranceID: utterance)
                        guard case .sent(let turn) = outcome else { Issue.record("input not sent"); return }
                        #expect(turn.utteranceID == utterance)
                        let generation = await (session.binding, session.connectionID)
                        #expect(turn.binding == generation.0 && turn.connectionID == generation.1)
                        var records: [ProviderObservedEvent] = []
                        for _ in 0..<3 { records.append(try #require(try await session.next())) }
                        #expect(records.map(\.event.turn) == [turn, turn, turn])
                        #expect(records.map(\.event.sequence) == [0, 1, 2])
                        #expect(records.map(\.event.kind) == [.accepted,
                            .text("invented final text", isFinal: true, visibility: .userVisible), .finished])
                        #expect(await session.state(for: turn.id) == .finished)
                    }
                    defer { adapter.cancel(); group.cancelAll() }
                    try await CodexStdioFixtures.waitUntil { await adapter.bufferedEarlyRecords == 3 }
                    try await gate.release()
                    try await group.waitForAll()
                }
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
    @Test(arguments: [nil, "0.158.0"]) func absentOrIncompatibleDeclarationRefusesBeforeLaunch(version: String?)
        async throws {
        await #expect(throws: CodexAppServerError.incompatibleVersion) {
            _ = try await CodexAppServerAdapter.withOwnedAdapter(
                command: OwnedStdioCommand(executable: "/nonexistent-synthetic-child"), verifiedVersion: version) { _ in
                    Issue.record("operation entered despite incompatible version")
                }
        }
    }
    @Test func captureDenialAndWrongObservationBindingStartNoChild() async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: OwnedStdioCommand(executable: "/nonexistent-synthetic-child"),
            verifiedVersion: "0.159.0") { adapter in
                let host = try await CodexAppServerFixtures.host(adapter, capture: false)
                await #expect(throws: ProviderObservedSessionError.captureDenied) {
                    try await host.withObservedSession(target: CodexAppServerFixtures.target) { _ in
                        Issue.record("capture denial bypassed")
                    }
                }
                let wrong = try CodexAppServerFixtures.binding()
                await #expect(throws: CodexAppServerError.unavailable) { try await adapter.observe(wrong) }
                let registry = Registry(); try await registry.register(adapter)
                var policy = Policy()
                try policy.allow(CodexAppServerFixtures.target, binding: "replacement", tier: .open, capture: true)
                let changed = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
                await #expect(throws: ProviderObservedSessionError.captureDenied) {
                    try await changed.withObservedSession(target: CodexAppServerFixtures.target) { _ in
                        Issue.record("changed binding bypassed")
                    }
                }
                return adapter
            }
        #expect(await adapter.isReaped)
    }
    @Test func activeTurnRefusesAnotherProviderRequestAndScopeJoins() async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(terminal: false), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                let outcome = try await session.submit("invented first", utteranceID: UUID())
                guard case .sent(let turn) = outcome else { Issue.record("not sent"); return }
                #expect(try await session.next()?.event.kind == .accepted)
                let text = try #require(try await session.next())
                #expect(text.event.kind == .text("invented final text", isFinal: true, visibility: .userVisible))
                #expect(await session.state(for: turn.id) == .accepted) // Item completion is not turn completion.
                await #expect(throws: CodexAppServerError.turnInProgress) {
                    try await session.submit("invented second", utteranceID: UUID())
                }
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
    @Test(arguments: ["completed", "failed", "interrupted"]) func registeredTerminalStatesAreNotGuessed(status: String)
        async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(status: status), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                let outcome = try await session.submit("invented input", utteranceID: UUID())
                guard case .sent(let turn) = outcome else { Issue.record("not sent"); return }
                for _ in 0..<3 { _ = try #require(try await session.next()) }
                let expected: ProviderTurnState = status == "completed" ? .finished
                    : status == "failed" ? .failed : .interrupted
                #expect(await session.state(for: turn.id) == expected)
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
}
extension CodexAppServerAdapterTests {
    @Test func precancelledScopeRefusesBeforeLaunchOrOperation() async throws {
        let scope = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await CodexAppServerAdapter.withOwnedAdapter(
                command: OwnedStdioCommand(executable: "/nonexistent-synthetic-child"),
                verifiedVersion: "0.159.0") { _ in Issue.record("cancelled operation entered") }
        }
        await #expect(throws: CancellationError.self) { try await scope.value }
    }
    @Test(arguments: ["exit 0; ", #"print "{\n"; "#,
        #"sendmsg({id=>999,method=>'invented/approval',params=>{}}); "#])
    func registeredTransportFailuresNeverPromoteEarlyOutputToSent(extra: String) async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(extra: extra), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                await #expect(throws: CodexAppServerError.unavailable) {
                    try await session.submit("invented input", utteranceID: UUID())
                }
                await #expect(throws: ProviderObservationLoss.self) { try await session.next() }
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
    @Test func cancellingHeldObservationDiscardsEarlyOutputAndReaps() async throws {
        let gate = try CodexFixtureGate(); defer { try? gate.remove() }
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(gate: gate), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await #expect(throws: CodexAppServerError.unavailable) {
                            try await session.submit("invented input", utteranceID: UUID())
                        }
                    }
                    defer { adapter.cancel(); group.cancelAll() }
                    try await CodexStdioFixtures.waitUntil { await adapter.bufferedEarlyRecords == 3 }
                    await session.stop()
                    #expect(try await session.next() == nil)
                    try await group.waitForAll()
                }
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
    @Test func stoppedGenerationCannotRestartAndNewGenerationEmitsZeroBasedEvents() async throws {
        var turns: [ProviderTurnContext] = []
        for _ in 0..<2 {
            let pair = try await CodexAppServerAdapter.withOwnedAdapter(
                command: CodexAppServerFixtures.command(), verifiedVersion: "0.159.0") { adapter in
                let host = try await CodexAppServerFixtures.host(adapter)
                let turn = try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                    let outcome = try await session.submit("invented input", utteranceID: UUID())
                    guard case .sent(let turn) = outcome else { throw ProviderContractError.unknownTurn }
                    #expect(try await session.next()?.event.sequence == 0)
                    return turn
                }
                return (adapter, turn)
            }
            #expect(await pair.0.isReaped)
            await #expect(throws: CodexAppServerError.unavailable) { try await pair.0.observe(pair.1.binding) }
            #expect(try await pair.0.listTargets().isEmpty)
            turns.append(pair.1)
        }
        #expect(turns[0].binding.sessionID != turns[1].binding.sessionID)
        #expect(turns[0].binding.observationID != turns[1].binding.observationID)
        #expect(turns[0].connectionID != turns[1].connectionID)
    }
    @Test func registeredConfirmationAndMultilinePreflightUseTheGuardedHostPath() async throws {
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: CodexAppServerFixtures.command(), verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter, tier: .confirm)
            try await host.withObservedSession(target: CodexAppServerFixtures.target) { session in
                let result = try await session.submit("invented input", utteranceID: UUID())
                guard case .needsConfirmation(let readback) = result else { throw ProviderContractError.unknownTurn }
                await #expect(throws: AdapterInputShapeError.singleLineRequired) {
                    try await session.submit("invented first\ninvented second", utteranceID: UUID())
                }
                let sent = try await session.submit("invented input", utteranceID: UUID(), confirmedHash: readback.hash)
                guard case .sent(let turn) = sent else { throw ProviderContractError.unknownTurn }
                #expect(try await session.next()?.correlation == .associated(turn, state: .accepted))
            }
            return adapter
        }
        #expect(await adapter.isReaped)
    }
}
#endif
