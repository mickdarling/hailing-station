import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #609: an unsolicited notify retains its source authority while held, without borrowing task enrollment.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateAuthorityTests {
    @Test func heldOrdinaryNotifyCannotMoveToAReallowedReplacementBinding() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        await rig.rebind("replacement-binding")
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        // A distinct new submission can use the replacement's explicit grant; the old words cannot.
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        #expect(await rig.listener.drainSessionUpdates(.interaction).count == 1)
        #expect(rig.sends.total == 1)
        await rig.listener.stop()
    }

    @Test func heldOrdinaryNotifyCannotReviveAfterRevokeAndRestore() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        _ = try await rig.host.deny(RecipientTestRig.target)
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }

    @Test func externalRevocationIsObservedByDrainWithoutANewOwnerInput() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        var revoked = rig.store.stored
        revoked.deny(RecipientTestRig.target)
        rig.store.overwrite(revoked)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        var restored = rig.store.stored
        try restored.allow(RecipientTestRig.target, binding: "reply-binding", tier: .open)
        rig.store.overwrite(restored)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }

    @Test func externalRevocationAtThePeerHopCannotBeReplacedByAFreshPermit() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        var revoked = rig.store.stored
        revoked.deny(RecipientTestRig.target)
        let changedPolicy = revoked
        let sent = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            rig.store.overwrite(changedPolicy)
        }, operation: { await rig.listener.drainSessionUpdates(.interaction) })
        #expect(sent.isEmpty && rig.sends.total == 0)
        var restored = rig.store.stored
        try restored.allow(RecipientTestRig.target, binding: "reply-binding", tier: .open)
        rig.store.overwrite(restored)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }

    @Test func preparedOrdinaryCardObservesAnExternalRevocationAtItsFinalEnqueue() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        _ = await rig.listener.sessionUpdate(rig.request)
        let update = try #require(await rig.listener.sessionUpdates.held.first)
        let authority = try #require(await rig.listener.sessionUpdateTaskAuthorities[update.id])
        let admission = try #require(await rig.session.prepareSessionUpdate(update, lastInput: nil,
                                                                            taskAuthority: authority))
        var revoked = rig.store.stored
        revoked.deny(RecipientTestRig.target)
        rig.store.overwrite(revoked)
        let called = Mutex(false)
        let accepted = await rig.session.enqueueSessionUpdate(admission, lastInput: nil, enqueue: {
            called.withLock { $0 = true }; return true
        })
        #expect(!accepted && !called.withLock { $0 })
        await rig.listener.stop()
    }

    @Test(arguments: [false, true]) func deniedOrUnboundSubmitCannotWaitForAFutureGrant(_ unbound: Bool) async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        if unbound { await rig.rebind(nil) } else { _ = try await rig.host.deny(RecipientTestRig.target) }
        let refused = await rig.listener.sessionUpdate(rig.request)
        #expect(refused.outcome == .refused && refused.reason == "retired_authority")
        #expect(refused.held == 0)
        await rig.rebind("reply-binding")
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }

    @Test func ordinarySubmissionKeepsThePrivacyEpochBeforeSuspendedRegistryValidation() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        await rig.adapter.holdNextListing()
        var listing = rig.adapter.listingEvents.stream.makeAsyncIterator()
        let submit = Task { await rig.listener.sessionUpdate(rig.request) }
        _ = try #require(await listing.next())
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connection)
        hold.set(false, connection: rig.connection)
        await rig.adapter.releaseListing()
        let report = await submit.value
        #expect(report.outcome == .dropped && report.reason == "private" && report.held == 0)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }

    @Test func retiredTaskScopeIsNeverReplacedByAnOrdinarySubmissionGrant() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        let generation = await rig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let original = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding",
                                                         taskFence: TaskProgressOutputFence())
        _ = try await rig.host.deny(RecipientTestRig.target)
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        let report = await TaskProgressPublicationScope.$authority.withValue(original) {
            await rig.listener.sessionUpdate(rig.request)
        }
        #expect(report.outcome == .refused && report.reason == "retired_authority" && report.held == 0)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }

    @Test func alreadyPrivateOrdinarySubmissionCannotBeRevivedByAnExit() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        let hold = await rig.listener.replyHold
        hold.set(true, connection: rig.connection)
        let report = await rig.listener.sessionUpdate(rig.request)
        #expect(report.outcome == .dropped && report.reason == "private")
        hold.set(false, connection: rig.connection)
        #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty)
        #expect(rig.sends.total == 0)
        await rig.listener.stop()
    }
}

// Admission preserves the source across the first host validation, before an update enters the held queue.
extension SessionUpdateAuthorityTests {
    @Test func aFreshOrdinarySubmissionObservesAnExternalGrantWithoutAnotherHostRequest() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        let allowed = rig.store.stored
        _ = try await rig.host.deny(RecipientTestRig.target)
        #expect(!rig.host.targetPolicy.snapshot(for: RecipientTestRig.target).wasGranted)
        // Model a separate owner CLI write; no host reload, target input or selection occurs afterward.
        rig.store.overwrite(allowed)
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        #expect(await rig.listener.drainSessionUpdates(.interaction).count == 1)
        #expect(rig.sends.total == 1)
        await rig.listener.stop()
    }

    @Test func aSubmissionCannotBorrowAReplacementGrantWhileItsFirstHostValidationWaits() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        let response = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            await rig.rebind("replacement-binding")
            _ = try? await rig.host.allow(RecipientTestRig.target, tier: .open)
        }, operation: { await rig.listener.sessionUpdate(rig.request) })
        #expect(response.outcome == .refused && response.reason == "retired_authority")
        #expect(response.held == 0 && rig.sends.total == 0)
        // Only a new caller submission may acquire the replacement's explicitly allowed grant.
        #expect(await rig.listener.sessionUpdate(rig.request).held == 1)
        await rig.listener.stop()
    }

    @Test func aSubmissionCannotReviveAnOriginalGrantDuringItsFirstHostValidation() async throws {
        let rig = try await OrdinaryUpdateAuthorityTestRig.make()
        let response = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            _ = try? await rig.host.deny(RecipientTestRig.target)
            _ = try? await rig.host.allow(RecipientTestRig.target, tier: .open)
        }, operation: { await rig.listener.sessionUpdate(rig.request) })
        #expect(response.outcome == .refused && response.reason == "retired_authority")
        #expect(response.held == 0 && rig.sends.total == 0)
        await rig.listener.stop()
    }
}
