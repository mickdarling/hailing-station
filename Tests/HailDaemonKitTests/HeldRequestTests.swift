import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestTests {
    @Test func exactPreparedContentScopeAndReferenceAreRetained() async throws {
        let rig = try await HeldTestRig.make()
        let reference = UUID()
        let text = "HELD_TOKEN reply reference \(reference.uuidString)"
        let entry = try await rig.hold(text, reference: reference)
        #expect(entry.text == text)
        #expect(entry.reference == reference)
        #expect(await entry.connection == rig.session.connectionID)
        #expect(await entry.selection == rig.session.selectionGeneration)
        #expect(entry.target == RecipientTestRig.target)
        #expect(entry.binding == "reply-binding")
        #expect(entry.reasons == [.ruleMatch])
        #expect(entry.rules == [.custom])
        #expect(entry.readBack.hash == DeliveryRequest(target: entry.target, binding: entry.binding,
            lines: entry.readBack.lines, device: HostSession.dispatchDevice).confirmationHash)
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.session.replyRequests.isEmpty)
    }

    @Test func sendAndConflictingTerminalDecisionsReplayWithoutAnotherHandoff() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        #expect(await rig.send(entry.id) == .sent)
        #expect(await rig.send(entry.id) == .sent)
        #expect(await rig.discard(entry.id) == .sent)
        #expect(await rig.adapter.contexts.count == 1)
        #expect(await rig.host.heldRequests.entries[entry.id] == nil)
    }

    @Test func discardReleasesContentAndReplaysAcrossConflictingSend() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        #expect(await rig.discard(entry.id) == .discarded)
        #expect(await rig.send(entry.id) == .discarded)
        #expect(await rig.discard(entry.id) == .discarded)
        #expect(await rig.host.heldRequests.entries[entry.id] == nil)
        #expect(await rig.adapter.contexts.isEmpty)
    }

    @Test func unknownAndOtherConnectionsSeeStale() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        #expect(await rig.send(UUID()) == .stale)
        #expect(await rig.discard(UUID()) == .stale)
        #expect(await rig.session.sendHeld(entry.id, from: UUID()) == .stale)
        #expect(await rig.session.discardHeld(entry.id, from: UUID()) == .stale)
        let other = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer())
        #expect(await other.sendHeld(entry.id, from: other.connectionID) == .stale)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test(arguments: [false, true]) func selectionChangesCannotBeReversed(back: Bool) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.select("recipient:other")
        if back { await rig.select(RecipientTestRig.target) }
        #expect(await rig.send(entry.id) == .refused(.selectionChanged))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        #expect(await rig.adapter.contexts.isEmpty)
    }

    @Test(arguments: [false, true]) func bindingAndTargetChangesRefuseContentKept(missing: Bool) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        await rig.adapter.setTargets(missing ? [] : [.init(name: "reply", binding: "replacement")])
        #expect(await rig.send(entry.id) == .refused(missing ? .targetUnavailable : .bindingChanged))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test(arguments: [false, true]) func policyChangeOrDenyRetainsTheContent(deny: Bool) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        if deny { _ = try await rig.host.deny(entry.target) } else {
            _ = try await rig.host.setTier(.locked, for: entry.target)
        }
        #expect(await rig.send(entry.id) == .refused(.policyChanged))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test(arguments: [false, true]) func privacyAndLockdownKeepSendInertButAllowDiscard(lockdown: Bool) async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        if lockdown { _ = await rig.host.engageLockdown(reason: "synthetic") } else {
            rig.privacy.isOn = true
        }
        #expect(await rig.send(entry.id) == .refused(.lockdown))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        #expect(await rig.discard(entry.id) == .discarded)
        #expect(await rig.adapter.contexts.isEmpty)
    }

    @Test func expiredNoticeRenewsBeforeAnyDelivery() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        rig.clock.advance(120_000)
        guard case .held(let notice) = await rig.send(entry.id) else { throw HeldTestError.expectedHold }
        #expect(notice.held == entry.id)
        let renewed = try #require(await rig.host.heldRequests.entries[entry.id])
        #expect(renewed.expires > entry.expires)
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.send(entry.id) == .sent)
    }

    @Test func rateLimitedSendRetainsContentAndCanBeRetried() async throws {
        let rig = try await HeldTestRig.make(limit: 1)
        let entry = try await rig.hold()
        _ = try await rig.dispatch("benign")
        #expect(await rig.send(entry.id) == .refused(.rateLimited))
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
        rig.clock.advance(60_001)
        #expect(await rig.send(entry.id) == .sent)
    }

    @Test func initialRateLimitIsHeldAndConfirmTierHasItsOwnReason() async throws {
        let rig = try await HeldTestRig.make(limit: 1)
        _ = try await rig.dispatch("benign")
        let entry = try await rig.hold("second benign")
        #expect(entry.reasons == [.rateLimited])
        let confirm = try await HeldTestRig.make(tier: .confirm)
        #expect(try await confirm.hold("benign").reasons == [.confirmTier])
    }

    @Test func freshGuardTimeoutRenewsInsteadOfUsingOldConsent() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        let clock = GuardBudgetClock(now: { .now }, cpuNow: { nil })
        let result = await GuardBudgetClock.$current.withValue(clock) { await rig.send(entry.id) }
        guard case .held(let notice) = result else { throw HeldTestError.expectedHold }
        #expect(notice.reasons == [.guardTimeout])
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.host.heldRequests.entries[entry.id]?.text == entry.text)
    }

    @Test func boundsRefuseAdmissionVisiblyWithoutEviction() async throws {
        let rig = try await HeldTestRig.make()
        var ids: [UUID] = []
        for _ in 0..<8 { ids.append(try await rig.hold().id) }
        #expect(try await rig.dispatch() == .holdAdmissionRefused)
        #expect(await rig.host.heldRequests.entries.count == 8)
        for id in ids { #expect(await rig.host.heldRequests.entries[id]?.text == "HELD_TOKEN") }
        #expect(await rig.discard(ids[0]) == .discarded)
        _ = try await rig.hold()
        let store = HeldRequestStore()
        for _ in 0..<64 { #expect(await store.reserve(connection: UUID()) != nil) }
        #expect(await store.reserve(connection: UUID()) == nil)
    }
}
