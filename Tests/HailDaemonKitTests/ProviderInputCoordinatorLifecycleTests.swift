import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderInputCoordinatorLifecycleTests {
    @Test func deadlineStartsAfterDispatchAndExpiresAtExactMonotonicBoundary() async throws {
        let adapter = ProviderCoordinatorGatedAdapter()
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(timeout: .seconds(5)))
        let pending = Task { try await rig.send() }
        await adapter.waitForDispatch()
        rig.clock.advance(.seconds(20))
        await adapter.release()
        let turn = try await pending.value
        rig.clock.advance(.seconds(4))
        #expect(await rig.coordinator.expireDueTurns().isEmpty)
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        rig.clock.advance(.seconds(1))
        #expect(await rig.coordinator.expireDueTurns() == [turn.id])
        #expect(await rig.coordinator.state(for: turn.id) == .timedOut)
        #expect(await rig.coordinator.expireDueTurns().isEmpty)
    }

    @Test func textFinalDoesNotFinishAndRepeatedLateOutputStaysUnassociated() async throws {
        let rig = try await ProviderCoordinatorRig.make(configuration: .init(timeout: .seconds(5)))
        let turn = try await rig.send()
        let final = try rig.event(
            0, turn: turn, kind: .text("synthetic final", isFinal: true, visibility: .userVisible)
        )
        #expect(try await rig.coordinator.ingest(final) == .associated(turn, state: .sent))
        rig.clock.advance(.seconds(5))
        for sequence in 1...2 {
            let late = try rig.event(sequence, turn: turn, kind: .finished)
            #expect(try await rig.coordinator.ingest(late) == .unassociated(.timedOut))
        }
        #expect(await rig.coordinator.state(for: turn.id) == .timedOut)
        let newer = try await rig.send()
        #expect(await rig.coordinator.state(for: newer.id) == .sent)
    }

    @Test func explicitTerminalEventsRemoveDeadlinesAndLifecycleStaysDistinct() async throws {
        let rig = try await ProviderCoordinatorRig.make(configuration: .init(timeout: .seconds(5)))
        let turn = try await rig.send()
        #expect(try await rig.coordinator.ingest(rig.event(0, turn: turn, kind: .accepted)) ==
            .associated(turn, state: .accepted))
        #expect(try await rig.coordinator.ingest(rig.event(1, turn: turn, kind: .running)) ==
            .associated(turn, state: .running))
        #expect(try await rig.coordinator.ingest(rig.event(2, turn: turn, kind: .finished)) ==
            .associated(turn, state: .finished))
        let interrupted = try await rig.send()
        _ = try await rig.coordinator.ingest(rig.event(3, turn: interrupted, kind: .interrupted))
        let failed = try await rig.send()
        _ = try await rig.coordinator.ingest(rig.event(4, turn: failed, kind: .failed(.providerFailed)))
        rig.clock.advance(.seconds(10))
        #expect(await rig.coordinator.expireDueTurns().isEmpty)
        #expect(await rig.coordinator.state(for: turn.id) == .finished)
        #expect(await rig.coordinator.state(for: interrupted.id) == .interrupted)
        #expect(await rig.coordinator.state(for: failed.id) == .failed)
    }

    @Test func earlyIngestionRejectsWithoutConsumingSequenceAndCanBeRetried() async throws {
        let adapter = ProviderCoordinatorGatedAdapter()
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter)
        let event = try rig.event(0, turn: nil, kind: .running)
        let pending = Task { try await rig.send() }
        await adapter.waitForDispatch()
        await #expect(throws: ProviderInputCoordinatorError.dispatchInProgress) {
            try await rig.coordinator.ingest(event)
        }
        await adapter.release()
        _ = try await pending.value
        #expect(try await rig.coordinator.ingest(event) == .unassociated(.noTurn))
        #expect(try await rig.coordinator.ingest(event) == .rejected(.duplicateEvent))
    }

    @Test func mismatchedContextConsumesOrderedEventButCannotAffectTurn() async throws {
        let rig = try await ProviderCoordinatorRig.make()
        let turn = try await rig.send()
        let changedUtterance = ProviderTurnContext(
            id: turn.id, utteranceID: UUID(), connectionID: turn.connectionID, binding: turn.binding
        )
        let changedConnection = ProviderTurnContext(
            id: turn.id, utteranceID: turn.utteranceID, connectionID: UUID(), binding: turn.binding
        )
        for (sequence, changed) in [changedUtterance, changedConnection].enumerated() {
            #expect(try await rig.coordinator.ingest(rig.event(sequence, turn: changed, kind: .finished)) ==
                .rejected(.wrongTurnContext))
        }
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        #expect(try await rig.coordinator.ingest(rig.event(2, turn: turn, kind: .finished)) ==
            .associated(turn, state: .finished))
    }

    @Test func freshInstanceIsolatesReconnectObservationAndUnknownTurns() async throws {
        let previous = try await ProviderCoordinatorRig.make()
        let previousTurn = try await previous.send()
        let fresh = try await ProviderCoordinatorRig.make()
        let turn = try await fresh.send()
        #expect(fresh.binding.observationID != previous.binding.observationID)
        #expect(fresh.connectionID != previous.connectionID)
        #expect(try await fresh.coordinator.ingest(previous.event(0, turn: previousTurn, kind: .finished)) ==
            .rejected(.wrongBinding))
        let unknown = ProviderTurnContext(utteranceID: UUID(), connectionID: fresh.connectionID, binding: fresh.binding)
        #expect(try await fresh.coordinator.ingest(fresh.event(0, turn: unknown, kind: .finished)) ==
            .unassociated(.unknownTurn))
        #expect(await fresh.coordinator.state(for: turn.id) == .sent)
    }

    @Test func eventCapacityOrderingAndInternalVisibilityRemainIntact() async throws {
        let rig = try await ProviderCoordinatorRig.make(configuration: .init(maxEvents: 1))
        let turn = try await rig.send()
        let event = try rig.event(
            0, turn: turn, kind: .text("internal fixture", isFinal: true, visibility: .internalOnly)
        )
        #expect(try await rig.coordinator.ingest(rig.event(1, turn: turn, kind: .finished)) == .rejected(.sequenceGap))
        #expect(try await rig.coordinator.ingest(event) == .associated(turn, state: .sent))
        #expect(event.kind == .text("internal fixture", isFinal: true, visibility: .internalOnly))
        #expect(try await rig.coordinator.ingest(rig.event(1, turn: turn, kind: .finished)) ==
            .rejected(.capacityExceeded))
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
    }

    @Test func configurationRejectsInvalidTimeoutCapacityAndProviderTargetMismatch() async throws {
        for timeout in [Duration.zero, .seconds(-1), .seconds(Int64.max)] {
            await #expect(throws: ProviderInputCoordinatorError.invalidTimeout) {
                try await ProviderCoordinatorRig.make(configuration: .init(timeout: timeout))
            }
        }
        await #expect(throws: ProviderContractError.invalidCapacity) {
            try await ProviderCoordinatorRig.make(configuration: .init(maxTurns: 0))
        }
        let rig = try await ProviderCoordinatorRig.make()
        let mismatch = try ProviderSessionBinding(
            hostID: "host-test", providerID: "other", targetID: "tmux:synthetic", sessionID: "opaque-binding"
        )
        #expect(throws: ProviderInputCoordinatorError.invalidBinding) {
            try ProviderInputCoordinator(host: rig.host, binding: mismatch, connectionID: UUID())
        }
    }
}

extension ProviderInputCoordinatorLifecycleTests {
    @Test func cancellationDuringConfirmedReloadPreservesTokenAndRefusesWrites() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:synthetic", binding: "opaque-binding")
        let store = ProviderCoordinatorGatedStore(policy)
        let host = try HailHost(registry: registry, store: store)
        let binding = try ProviderSessionBinding(
            hostID: "host-test", providerID: "tmux", targetID: "tmux:synthetic", sessionID: "opaque-binding"
        )
        let coordinator = try ProviderInputCoordinator(
            host: host, binding: binding, connectionID: UUID(), configuration: .init(maxTurns: 1)
        )
        let outcome = try await coordinator.submit("synthetic input", utteranceID: UUID())
        guard case .needsConfirmation(let readBack) = outcome else { Issue.record("expected confirmation"); return }
        store.gateNextLoad()
        let pending = Task {
            try await coordinator.submit("synthetic input", utteranceID: UUID(), confirmedHash: readBack.hash)
        }
        await store.waitForReload()
        pending.cancel()
        store.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await adapter.deliveries.isEmpty)
        let retry = try await coordinator.submit("synthetic input", utteranceID: UUID(), confirmedHash: readBack.hash)
        guard case .sent(let turn) = retry else { Issue.record("confirmation token was consumed"); return }
        #expect(await coordinator.state(for: turn.id) == .sent)
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func providerMustMatchFirstComponentButTargetNameMayContainColons() async throws {
        let rig = try await ProviderCoordinatorRig.make()
        let mismatch = try ProviderSessionBinding(
            hostID: "host-test", providerID: "tmux:group", targetID: "tmux:group:session", sessionID: "opaque-binding"
        )
        #expect(throws: ProviderInputCoordinatorError.invalidBinding) {
            try ProviderInputCoordinator(host: rig.host, binding: mismatch, connectionID: UUID())
        }
        let valid = try ProviderSessionBinding(
            hostID: "host-test", providerID: "tmux", targetID: "tmux:group:session", sessionID: "opaque-binding"
        )
        let coordinator = try ProviderInputCoordinator(host: rig.host, binding: valid, connectionID: UUID())
        #expect(await coordinator.binding == valid)
    }
}
