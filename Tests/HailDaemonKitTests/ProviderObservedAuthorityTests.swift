import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderObservedAuthorityTests {
    @Test(arguments: [false, true]) func terminalLossWaitsForAuthorizedInFlightRecord(failed: Bool) async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([.accepted])
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            await rig.adapter.listings.wait(for: 5)
            await rig.adapter.holdListing(7)
            await rig.adapter.dispatch.release()
            await rig.adapter.listing.arrivals.wait() // Valid record is in post-ingest authorization, not ready.
            await rig.adapter.finish(failed ? ProviderObservationError.unavailable : nil)
            await rig.adapter.cancellations.wait()
            let completed = ObservedCounter()
            let next = Task {
                defer { completed.increment() }
                return try await session.next()
            }
            await rig.adapter.listings.wait(for: 8) // Consumer freshly revalidates while the record stays held.
            let proposed = try #require(await rig.adapter.delivered.first)
            #expect(await session.state(for: proposed.id) == .accepted)
            #expect(completed.count < 1)
            await rig.adapter.listing.release()
            let sent = try rig.sent(try await input.value)
            let record = try #require(try await next.value)
            #expect(record.event.sequence == 0)
            #expect(record.correlation == .associated(sent, state: .accepted))
            let loss: ProviderObservationLoss = failed ? .streamFailed : .streamEnded
            await #expect(throws: loss) { try await session.next() }
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func observationEndingDuringSubmitAuthorizationRefusesNewWrite() async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            await rig.adapter.holdListing(3)
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.listing.arrivals.wait()
            await rig.adapter.finish()
            await rig.adapter.cancellations.wait()
            await rig.adapter.listing.release()
            await #expect(throws: ProviderObservationError.interrupted) { try await input.value }
            #expect(await rig.adapter.delivered.isEmpty)
            #expect(await session.status == .lost(.streamEnded))
        }
    }

    @Test func inFlightRecordStillCountsAcrossSuspendedPostIngestValidation() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([.accepted])
        var config = rig.configuration()
        config.maxQueuedEvents = 1
        try await rig.host.withObservedSession(target: ObservedRig.target, configuration: config) { session in
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            await rig.adapter.listings.wait(for: 5)
            await rig.adapter.holdListing(7) // Receive(5), pre-ingest(6), suspended post-ingest(7).
            await rig.adapter.dispatch.release()
            await rig.adapter.listing.arrivals.wait()
            let proposed = try #require(await rig.adapter.delivered.first)
            try await rig.adapter.emit(.text("invented extra", isFinal: false, visibility: .userVisible),
                                       turn: proposed)
            await rig.adapter.cancellations.wait()
            #expect(await session.status == .lost(.bufferOverflow))
            await rig.adapter.listing.release()
            let sent = try rig.sent(try await input.value)
            #expect(try await session.next()?.correlation == .associated(sent, state: .accepted))
            await #expect(throws: ProviderObservationLoss.bufferOverflow) { try await session.next() }
            #expect(await session.state(for: sent.id) == .accepted)
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func revocationDuringPostIngestSuspensionWithholdsAlreadyCorrelatedText() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([.text("invented final", isFinal: true, visibility: .userVisible)])
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            await rig.adapter.listings.wait(for: 5)
            await rig.adapter.holdListing(7)
            await rig.adapter.dispatch.release()
            await rig.adapter.listing.arrivals.wait()
            try rig.revoke()
            await rig.adapter.listing.release()
            let sent = try rig.sent(try await input.value)
            #expect(await session.status == .lost(.authorizationLost))
            await #expect(throws: ProviderObservationLoss.authorizationLost) { try await session.next() }
            #expect(await session.state(for: sent.id) == .sent) // Final text alone never completes the turn.
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func stopAfterEOFPreventsSuspendedDrainFromRepopulatingPurgedContent() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([.accepted])
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.dispatch.arrivals.wait()
            await rig.adapter.listings.wait(for: 5)
            await rig.adapter.holdListing(7)
            await rig.adapter.dispatch.release()
            await rig.adapter.listing.arrivals.wait()
            await rig.adapter.finish()
            await rig.adapter.cancellations.wait()
            #expect(await session.status == .lost(.streamEnded))
            await session.stop()
            await rig.adapter.listing.release()
            let sent = try rig.sent(try await input.value)
            await #expect(throws: ProviderObservationLoss.streamEnded) { try await session.next() }
            #expect(await session.state(for: sent.id) == .accepted)
        }
        #expect(rig.adapter.cancellations.count == 1)
    }
}
