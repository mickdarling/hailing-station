import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderObservedCancellationTests {
    @Test func parentCancellationCancelsLeaseBeforeNoncooperativeListingAndInputJoin() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.configure(holdDispatch: true)
        await rig.adapter.setEmission([])
        let scope = Task {
            try await rig.host.withObservedSession(target: ObservedRig.target,
                                                    configuration: rig.configuration()) { session in
                let sent = try rig.sent(try await session.submit("invented input", utteranceID: UUID()))
                #expect(await session.state(for: sent.id) == .sent)
                return sent
            }
        }
        await rig.adapter.dispatch.arrivals.wait()
        await rig.adapter.holdListing(5)
        let proposed = try #require(await rig.adapter.delivered.first)
        try await rig.adapter.emit(.accepted, turn: proposed)
        await rig.adapter.listing.arrivals.wait()
        scope.cancel()
        await rig.adapter.cancellations.wait() // Neither blocked actor operation has been released yet.
        #expect(rig.adapter.cancellations.count == 1)
        await rig.adapter.listing.release()
        await rig.adapter.dispatch.release()
        #expect(try await scope.value == proposed) // Noncooperative completed write retains truthful sent evidence.
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func cancellationDuringSubmitAuthorizationRemainsCancellationAndNeverWrites() async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            await rig.adapter.holdListing(3)
            let input = Task { try await session.submit("invented input", utteranceID: UUID()) }
            await rig.adapter.listing.arrivals.wait()
            input.cancel()
            await rig.adapter.cancellations.wait()
            #expect(rig.adapter.cancellations.count == 1) // Cancellation does not wait for listing progress.
            await rig.adapter.listing.release()
            await #expect(throws: CancellationError.self) { try await input.value }
            #expect(await rig.adapter.delivered.isEmpty)
            #expect(await session.status == .stopped)
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func cancelledNextWaiterClosesScopeWithoutLeakingContinuation() async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session async throws in
            let next = Task { try await session.next() }
            await rig.adapter.listings.wait(for: 3)
            next.cancel()
            await #expect(throws: CancellationError.self) { try await next.value }
            #expect(await session.status == .stopped)
            #expect(try await session.next() == nil)
            #expect(rig.adapter.cancellations.count == 1)
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test func preCancelledScopeDoesNotStartObservation() async throws {
        let rig = try await ObservedRig.make()
        let gate = ObservedGate()
        let scope = Task {
            await gate.pause()
            try await rig.host.withObservedSession(target: ObservedRig.target) { _ in
                Issue.record("cancelled scope entered")
                return ()
            }
        }
        await gate.arrivals.wait()
        scope.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await scope.value }
        #expect(await rig.adapter.observationCount < 1)
        #expect(await rig.adapter.delivered.isEmpty)
    }

    @Test func cancelledNextAuthorizationCancelsLeaseBeforeBlockedListingReturns() async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                configuration: rig.configuration()) { session in
            await rig.adapter.holdListing(3)
            let next = Task { try await session.next() }
            await rig.adapter.listing.arrivals.wait()
            next.cancel()
            await rig.adapter.cancellations.wait()
            #expect(rig.adapter.cancellations.count == 1)
            await rig.adapter.listing.release()
            await #expect(throws: CancellationError.self) { try await next.value }
        }
        #expect(rig.adapter.cancellations.count == 1)
    }
}
