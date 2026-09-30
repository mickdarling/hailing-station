import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderObservedSessionTests {
    @Test func independentlyEmittedEarlyEventsCorrelateAfterGuardedDispatch() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: rig.configuration()) { session in
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            let proposed = try #require(await rig.adapter.delivered.first)
            #expect(await session.state(for: proposed.id) == nil)
            await rig.adapter.listings.wait(for: 7) // Two startup, input auth/listing, three early-event checks.
            await rig.adapter.dispatch.release()
            let sent = try rig.sent(try await input.value)
            #expect(sent == proposed)
            var records: [ProviderObservedEvent] = []
            for _ in 0..<3 { records.append(try #require(try await session.next())) }
            #expect(records.map(\.event.sequence) == [0, 1, 2] as [Int])
            #expect(records.map(\.event.turn) == [sent, sent, sent])
            #expect(records.map(\.correlation) == [
                .associated(sent, state: .accepted), .associated(sent, state: .accepted),
                .associated(sent, state: .finished)
            ])
            #expect(await session.state(for: sent.id) == .finished)
        }
        #expect(rig.adapter.cancellations.count == 1)
        #expect(rig.adapter.terminations.count == 1)
    }

    @Test func captureDeniedAndUnsupportedAdaptersNeverWrite() async throws {
        let denied = try await ObservedRig.make(capture: false)
        await #expect(throws: ProviderObservedSessionError.captureDenied) {
            try await denied.host.withObservedSession(target: ObservedRig.target) { _ in }
        }
        #expect(await denied.adapter.observationCount == 0)
        let registry = Registry()
        let fake = FakeAdapter(kind: "observed", targets: [.init(name: "session", binding: "opaque-observed")])
        try await registry.register(fake)
        var policy = Policy()
        try policy.allow(ObservedRig.target, binding: "opaque-observed", tier: .open, capture: true)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        await #expect(throws: RegistryError.observationUnsupported) {
            try await host.withObservedSession(target: ObservedRig.target) { _ in }
        }
        #expect(await fake.deliveries.isEmpty)
    }

    @Test func lockedInputTierStillAllowsSeparatelyGrantedCapture() async throws {
        let rig = try await ObservedRig.make(tier: .locked)
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: rig.configuration()) { session in
            await #expect(throws: HostError.denied(.locked(ObservedRig.target))) {
                try await session.submit("invented input", utteranceID: UUID())
            }
            #expect(await session.status == .active)
        }
        #expect(await rig.adapter.delivered.isEmpty)
    }

    @Test func confirmationUsesExistingExactReadbackAndContextualPath() async throws {
        let rig = try await ObservedRig.make(tier: .confirm)
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: rig.configuration()) { session in
            let response = try await session.submit("invented input", utteranceID: UUID())
            guard case .needsConfirmation(let readback) = response else { Issue.record("no readback"); return }
            #expect(await rig.adapter.delivered.isEmpty)
            let sent = try rig.sent(try await session.submit("invented input", utteranceID: UUID(),
                                                           confirmedHash: readback.hash))
            #expect(try await session.next()?.correlation == .associated(sent, state: .accepted))
        }
    }

    @Test func startupRevalidationRefusesRevocationReplacementAndCancellation() async throws {
        for mode in 0..<3 {
            let rig = try await ObservedRig.make()
            await rig.adapter.configure(holdStartup: true)
            let entered = ObservedCounter()
            let scope = Task {
                try await rig.host.withObservedSession(target: ObservedRig.target,
                                                             configuration: rig.configuration()) { _ in
                    entered.increment()
                }
            }
            await rig.adapter.startup.arrivals.wait()
            if mode == 0 { try rig.revoke() }
            if mode == 1 {
                await rig.adapter.replace()
                _ = try await rig.host.allow(ObservedRig.target, tier: .open, capture: true)
            }
            if mode == 2 { scope.cancel() }
            await rig.adapter.startup.release()
            do { try await scope.value; Issue.record("startup unexpectedly succeeded") } catch {
                if mode == 2 { #expect(error is CancellationError) } else {
                    #expect(error as? ProviderObservedSessionError == .captureDenied)
                }
            }
            #expect(entered.count < 1)
            #expect(rig.adapter.cancellations.count == 1)
            #expect(await rig.adapter.delivered.isEmpty)
        }
    }

    @Test func legacyModeRequestIsExplicitlyRejected() async throws {
        let rig = try await ObservedRig.make()
        var config = rig.configuration()
        config.input = .init(deliveryMode: .legacy)
        await #expect(throws: ProviderObservedSessionError.legacyInputUnsupported) {
            try await rig.host.withObservedSession(target: ObservedRig.target,
                                                         configuration: config) { _ in }
        }
        #expect(await rig.adapter.observationCount == 0)
    }

    @Test func reconnectUsesFreshIdentityAndRealZeroBasedEvents() async throws {
        let rig = try await ObservedRig.make()
        var identities: [ProviderTurnContext] = []
        for _ in 0..<2 {
            let turn = try await rig.host.withObservedSession(target: ObservedRig.target,
                                                                  configuration: rig.configuration()) { session in
                let sent = try rig.sent(try await session.submit("invented input", utteranceID: UUID()))
                let first = try #require(try await session.next())
                #expect(first.event.sequence == 0)
                #expect(first.correlation == .associated(sent, state: .accepted))
                return sent
            }
            identities.append(turn)
        }
        #expect(identities[0].binding.observationID != identities[1].binding.observationID)
        #expect(identities[0].connectionID != identities[1].connectionID)
        #expect(rig.adapter.cancellations.count == 2)
    }
}
