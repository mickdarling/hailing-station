import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderContextCoordinatorTests {
    @Test func adapterIndependentlyEmitsTheExactAuthorizedContextBeforeDispatchReturns() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        let observation = try await adapter.observe(rig.binding)
        defer { observation.cancel() }
        await adapter.holdDispatch()
        let pending = Task { try await rig.submit() }
        await adapter.waitForDispatch()
        var iterator = observation.events.makeAsyncIterator()
        let accepted = try #require(try await iterator.next())
        let output = try #require(try await iterator.next())
        let finish = try #require(try await iterator.next())
        let proposed = try #require(accepted.turn)
        #expect(await rig.coordinator.state(for: proposed.id) == nil)
        #expect(accepted.kind == .accepted)
        #expect(output.kind == .text("synthetic provider output", isFinal: true, visibility: .userVisible))
        #expect(finish.kind == .finished)
        let sequences: [Int] = [accepted.sequence, output.sequence, finish.sequence]
        let contexts: [ProviderTurnContext?] = [accepted.turn, output.turn, finish.turn]
        #expect(sequences == [0, 1, 2])
        #expect(contexts == [proposed, proposed, proposed])
        await #expect(throws: ProviderInputCoordinatorError.dispatchInProgress) {
            try await rig.coordinator.ingest(accepted)
        }
        await adapter.releaseDispatch()
        let sent = try await pending.value
        #expect(sent == proposed)
        #expect(sent.utteranceID == rig.context.utteranceID)
        #expect(sent.connectionID == rig.context.connectionID)
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
        // The test explicitly owns iteration/retry; production has no observation owner in this slice.
        #expect(try await rig.coordinator.ingest(accepted) == .associated(sent, state: .accepted))
        #expect(try await rig.coordinator.ingest(output) == .associated(sent, state: .accepted))
        #expect(try await rig.coordinator.ingest(finish) == .associated(sent, state: .finished))
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func contextualModeCannotSilentlyFallbackToLegacy() async throws {
        let adapter = FakeAdapter(kind: "test", targets: [ProviderContextTestRig.target])
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        await #expect(throws: RegistryError.contextualDeliveryUnsupported) { try await rig.submit() }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func contextualInputIsAllowedWithoutCaptureAndDoesNotStartObservation() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        #expect(await rig.host.currentPolicy.targets[rig.binding.targetID]?.capture == false)
        let sent = try await rig.submit()
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
        #expect(await adapter.observationCount == 0)
    }

    @Test func completeMultilineDeliveryCarriesOneIdenticalProposedContext() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, sanitizing: .init(newlines: .split))
        let sent = try await rig.submit("one\ntwo")
        #expect(await adapter.contextual.map(\.context) == [sent, sent])
        #expect(await adapter.contextual.map(\.text) == ["one", "two"])
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
    }

    @Test func legacyModePreservesTheExistingCoordinatorPath() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter, mode: .legacy)
        let sent = try await rig.submit()
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
        #expect(await adapter.legacy == ["synthetic input"])
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func failedContextualDispatchCreatesNoTurnAndPreservesOriginalError() async throws {
        let adapter = SyntheticContextAdapter(error: ProviderCoordinatorSyntheticError.arbitraryFailure)
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        for _ in 0..<3 {
            await #expect(throws: ProviderCoordinatorSyntheticError.arbitraryFailure) { try await rig.submit() }
        }
        #expect(await adapter.contextual.isEmpty)
    }

    @Test func partialContextualDispatchDoesNotPromoteIndependentlyEmittedEvents() async throws {
        let adapter = SyntheticContextAdapter(failAfter: 1)
        let rig = try await ProviderContextTestRig.make(adapter: adapter, sanitizing: .init(newlines: .split))
        let observation = try await adapter.observe(rig.binding)
        defer { observation.cancel() }
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "adapter delivery failed")) {
            try await rig.coordinator.submit("one\ntwo", utteranceID: rig.context.utteranceID)
        }
        var iterator = observation.events.makeAsyncIterator()
        for _ in 0..<3 {
            let event = try #require(try await iterator.next())
            let proposed = try #require(event.turn)
            #expect(await rig.coordinator.state(for: proposed.id) == nil)
            #expect(try await rig.coordinator.ingest(event) == .unassociated(.unknownTurn))
        }
        #expect(await adapter.contextual.map(\.text) == ["one"])
    }

    @Test func cancellationBeforeDispatchAndAfterCompletedWriteStayTruthful() async throws {
        let adapter = SyntheticContextAdapter()
        let rig = try await ProviderContextTestRig.make(adapter: adapter)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rig.submit()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await adapter.contextual.isEmpty)
        await adapter.holdDispatch()
        let pending = Task { try await rig.submit() }
        await adapter.waitForDispatch()
        pending.cancel()
        await adapter.releaseDispatch()
        let sent = try await pending.value
        #expect(await rig.coordinator.state(for: sent.id) == .sent)
        #expect(await adapter.contextual.count == 1)
    }
}
