import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderObservationLifecycleTests {
    @Test(.frozenGuardBudget, arguments: [0, 1])
    func earlyFailedAndPartialWritesStayUnknown(completed: Int) async throws {
        try await observedEarlyFailure(completed: completed)
    }

    @Test(.frozenGuardBudget, arguments: [false, true])
    func earlyQueueCountAndBytesOverflowExplicitly(bytes: Bool) async throws {
        try await observedEarlyOverflow(bytes: bytes)
    }

    @Test func undrainedConsumerQueueCannotSilentlyEvictItsPrefix() async throws {
        let rig = try await ObservedRig.make()
        var config = rig.configuration()
        config.maxQueuedEvents = 1
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: config) { session in
            try await rig.adapter.emit(.running)
            try await rig.adapter.emit(.finished)
            await rig.adapter.cancellations.wait()
            #expect(await session.status == .lost(.bufferOverflow))
            #expect(try await session.next()?.correlation == .unassociated(.noTurn))
            await #expect(throws: ProviderObservationLoss.bufferOverflow) { try await session.next() }
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test(.frozenGuardBudget, arguments: [false, true])
    func eofPreservesTheCompleteReadPrefix(held: Bool) async throws {
        try await observedEndedPrefix(held: held, failed: false)
    }

    @Test(.frozenGuardBudget, arguments: [false, true])
    func failedStreamPreservesTheCompleteReadPrefix(held: Bool) async throws {
        try await observedEndedPrefix(held: held, failed: true)
    }

    @Test func postEofRevocationPurgesRetainedTextBeforeConsumption() async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: rig.configuration()) { session in
            try await rig.adapter.emit(.text("invented retained text", isFinal: true, visibility: .userVisible))
            await rig.adapter.finish()
            await rig.adapter.cancellations.wait()
            #expect(await session.status == .lost(.streamEnded))
            try rig.revoke()
            await #expect(throws: ProviderObservationLoss.authorizationLost) { try await session.next() }
            #expect(await session.status == .lost(.authorizationLost))
        }
        #expect(rig.adapter.cancellations.count == 1)
    }

    @Test(.frozenGuardBudget) func internalAmbientAndLateEventsNeverInventTurnCompletion() async throws {
        try await observedTimeoutAndVisibility()
    }

    @Test(.frozenGuardBudget) func duplicatesDoNotAdvanceSequenceAndGapsEndObservation() async throws {
        try await observedDuplicateAndGap()
    }

    @Test(.frozenGuardBudget, arguments: [false, true])
    func correlationCapacityFailsWithoutEvictingEvidence(turns: Bool) async throws {
        try await observedCapacity(turns: turns)
    }

    @Test(arguments: [0, 1, 2]) func idleClockDetectsRevocationRebindingAndLockdown(mode: Int) async throws {
        let rig = try await ObservedRig.make()
        try await rig.host.withObservedSession(target: ObservedRig.target,
                                                     configuration: rig.configuration()) { session in
            await rig.clock.poll.sleeps.wait()
            if mode == 0 { try rig.revoke() }
            if mode == 1 {
                await rig.adapter.replace()
                _ = try await rig.host.allow(ObservedRig.target, tier: .open, capture: true)
            }
            if mode == 2 { _ = await rig.host.engageLockdown(reason: "invented lifecycle test") }
            await rig.clock.advance(.milliseconds(250))
            await rig.adapter.cancellations.wait()
            #expect(await session.status == .lost(.authorizationLost))
            await #expect(throws: ProviderObservationLoss.authorizationLost) { try await session.next() }
        }
        #expect(rig.adapter.cancellations.count == 1)
        #expect(await rig.adapter.delivered.isEmpty)
    }

    @Test(.frozenGuardBudget, .timeLimit(.minutes(1)), arguments: [1, 2])
    func stopCancelsCaptureBeforeJoiningNoncooperativeWrites(lines: Int) async throws {
        try await observedStoppedWrite(lines: lines)
    }

    @Test func expiredGuardBudgetCompletesWithoutDispatch() async throws {
        let rig = try await ObservedRig.make()
        await rig.adapter.setEmission([])
        try await GuardBudgetClock.$current.withValue(.expiring()) {
            try await rig.host.withObservedSession(target: ObservedRig.target,
                                                  configuration: rig.configuration()) { session in
                let outcome = try await session.submit("invented first\ninvented second", utteranceID: UUID())
                guard case .needsConfirmation = outcome else {
                    Issue.record("expired guard budget did not refuse the two-line input")
                    return
                }
                #expect(await rig.adapter.delivered.isEmpty)
                #expect(rig.adapter.dispatch.arrivals.count < 1)
            }
        }
    }

    @Test(.frozenGuardBudget) func earlyScopeReturnStillJoinsItsAdmittedInput() async throws {
        try await observedReturnedScope()
    }

    @Test(.frozenGuardBudget, arguments: [false, true])
    func invalidEarlyTailDoesNotStrandTerminalConsumer(capacity: Bool) async throws {
        try await observedTerminalTail(capacity: capacity)
    }

    @Test(arguments: [false, true]) func earlyConsumerReturnAndThrowCancelExactlyOnce(fails: Bool) async throws {
        let rig = try await ObservedRig.make()
        do {
            try await rig.host.withObservedSession(target: ObservedRig.target,
                                                         configuration: rig.configuration()) { session in
                try await rig.adapter.emit(.running)
                #expect(try await session.next()?.correlation == .unassociated(.noTurn))
                if fails { throw ProviderCoordinatorSyntheticError.arbitraryFailure }
            }
            #expect(!fails)
        } catch {
            #expect(fails)
            #expect(error as? ProviderCoordinatorSyntheticError == .arbitraryFailure)
        }
        #expect(rig.adapter.cancellations.count == 1)
        #expect(rig.adapter.terminations.count == 1)
    }
}
