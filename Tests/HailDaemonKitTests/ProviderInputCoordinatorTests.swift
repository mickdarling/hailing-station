import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderInputCoordinatorTests {
    @Test func successfulDispatchRegistersFreshSentContext() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target])
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter)
        let utterance = UUID()
        let turn = try rig.context(try await rig.coordinator.submit("synthetic input", utteranceID: utterance))
        #expect(turn.utteranceID == utterance)
        #expect(turn.connectionID == rig.connectionID)
        #expect(turn.binding == rig.binding)
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        let second = try await rig.send()
        #expect(second.id != turn.id)
        #expect(await adapter.deliveries.map(\.binding) == ["opaque-binding", "opaque-binding"])
    }

    @Test func confirmationReservesNoCapacityAndConfirmedRetryDispatches() async throws {
        let rig = try await ProviderCoordinatorRig.make(tier: .confirm, configuration: .init(maxTurns: 1))
        let result = try await rig.coordinator.submit("synthetic input", utteranceID: UUID())
        guard case .needsConfirmation(let readBack) = result else { Issue.record("expected confirmation"); return }
        let turn = try rig.context(try await rig.coordinator.submit(
            "synthetic input", utteranceID: UUID(), confirmedHash: readBack.hash
        ))
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
    }

    @Test func deniedAndSanitizationRefusalReserveNoCapacity() async throws {
        let rig = try await ProviderCoordinatorRig.make(configuration: .init(maxTurns: 1))
        await #expect(throws: HostError.refused(.containsLineBreak)) {
            try await rig.coordinator.submit("one\ntwo", utteranceID: UUID())
        }
        _ = try await rig.host.setTier(.locked, for: rig.binding.targetID)
        await #expect(throws: HostError.denied(.locked(rig.binding.targetID))) { try await rig.send() }
        _ = try await rig.host.setTier(.open, for: rig.binding.targetID)
        _ = try await rig.send()
    }

    @Test func failedDispatchPreservesErrorAndClearsBusyReservation() async throws {
        let error = AdapterError.deliveryFailed("synthetic failure")
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target], deliverError: error)
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(maxTurns: 1))
        for _ in 0..<2 {
            await #expect(throws: error) { try await rig.send() }
        }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func partialDispatchPreservesEvidenceWithoutRegisteringSent() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target], failAfter: 1)
        let rig = try await ProviderCoordinatorRig.make(
            adapter: adapter, configuration: .init(maxTurns: 1), sanitizing: .init(newlines: .split)
        )
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "rebound(\"synthetic\")")) {
            try await rig.coordinator.submit("one\ntwo", utteranceID: UUID())
        }
        await #expect(throws: AdapterError.rebound("synthetic")) { try await rig.send() }
        #expect(await adapter.deliveries.map(\.text) == ["one"])
    }

    @Test func capacityRefusesBeforeDispatchIncludingFinishedTombstones() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target])
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(maxTurns: 1))
        let turn = try await rig.send()
        _ = try await rig.coordinator.ingest(rig.event(0, turn: turn, kind: .finished))
        await #expect(throws: ProviderContractError.capacityExceeded) { try await rig.send() }
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func overlappingSubmissionIsExplicitlyRefused() async throws {
        let adapter = ProviderCoordinatorGatedAdapter()
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter)
        let pending = Task { try await rig.send() }
        await adapter.waitForDispatch()
        await #expect(throws: ProviderInputCoordinatorError.dispatchInProgress) { try await rig.send() }
        await adapter.release()
        let turn = try await pending.value
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func exhaustedEventRetentionRefusesNewDispatchBeforeSideEffects() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target])
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(maxEvents: 1))
        let turn = try await rig.send()
        _ = try await rig.coordinator.ingest(rig.event(0, turn: turn, kind: .running))
        await #expect(throws: ProviderContractError.capacityExceeded) { try await rig.send() }
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func preCancelledSubmissionHasNoSideEffectsAndCapacityRemainsAvailable() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [ProviderCoordinatorRig.target])
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(maxTurns: 1))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rig.send()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await adapter.deliveries.isEmpty)
        _ = try await rig.send()
    }

    @Test func cancellationDuringSuccessfulWritePreservesSentEvidence() async throws {
        let adapter = ProviderCoordinatorGatedAdapter()
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter)
        let pending = Task { try await rig.send() }
        await adapter.waitForDispatch()
        pending.cancel()
        await adapter.release()
        let turn = try await pending.value
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        #expect(await adapter.deliveries.count == 1)
    }
}

extension ProviderInputCoordinatorTests {
    @Test func cancellationDuringListingRefusesBeforeAnyWriteAndReleasesReservation() async throws {
        let adapter = GatedListingFakeAdapter(ProviderCoordinatorRig.target)
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, configuration: .init(maxTurns: 1))
        await adapter.gateNextListing()
        let pending = Task { try await rig.send() }
        await adapter.nextListingArrival()
        pending.cancel()
        await adapter.releaseListing()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await adapter.deliveries.isEmpty)
        _ = try await rig.send()
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func cancellationDuringListingPreservesUnconsumedConfirmation() async throws {
        let adapter = GatedListingFakeAdapter(ProviderCoordinatorRig.target)
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, tier: .confirm)
        let outcome = try await rig.coordinator.submit("synthetic input", utteranceID: UUID())
        guard case .needsConfirmation(let readBack) = outcome else { Issue.record("expected confirmation"); return }
        await adapter.gateNextListing()
        let pending = Task {
            try await rig.coordinator.submit("synthetic input", utteranceID: UUID(), confirmedHash: readBack.hash)
        }
        await adapter.nextListingArrival()
        pending.cancel()
        await adapter.releaseListing()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await adapter.deliveries.isEmpty)
        let retry = try await rig.coordinator.submit(
            "synthetic input", utteranceID: UUID(), confirmedHash: readBack.hash
        )
        let turn = try rig.context(retry)
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
    }

    @Test func cancellationBetweenLinesPreservesPartialWriteAndStopsFurtherDispatch() async throws {
        let adapter = ProviderCoordinatorGatedAdapter()
        let rig = try await ProviderCoordinatorRig.make(adapter: adapter, sanitizing: .init(newlines: .split))
        let pending = Task { try await rig.coordinator.submit("one\ntwo", utteranceID: UUID()) }
        await adapter.waitForDispatch()
        pending.cancel()
        await adapter.release()
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "delivery cancelled")) {
            try await pending.value
        }
        #expect(await adapter.deliveries == ["one"])
    }

    @Test func adapterCancellationAfterFirstLinePreservesPartialEvidence() async throws {
        let adapter = ProviderCoordinatorCancellationAdapter()
        let rig = try await ProviderCoordinatorRig.make(
            adapter: adapter, configuration: .init(maxTurns: 1), sanitizing: .init(newlines: .split)
        )
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "delivery cancelled")) {
            try await rig.coordinator.submit("one\ntwo", utteranceID: UUID())
        }
        await #expect(throws: CancellationError.self) { try await rig.send() }
        #expect(await adapter.deliveries == ["one"])
    }
}
