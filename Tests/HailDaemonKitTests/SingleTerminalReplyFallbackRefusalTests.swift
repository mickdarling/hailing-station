import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Never-started transports: every refusal here happens before any enqueue attempt could exist.
@Suite struct SingleTerminalReplyFallbackRefusalTests {
    @Test func fallbackRefusesWhenNoConnectionSelectsTheTarget() async throws {
        let rig = try await RecipientTestRig.make()
        let frame = recipientText(uncorrelatedDescriptor())
        let unselected = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await unselected.receive(helloFrame())
        let elsewhere = await rig.session()
        _ = await elsewhere.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        for peers in [[], [unselected], [elsewhere], [unselected, elsewhere]] {
            let listener = try fallbackListener(rig: rig, enabled: true)
            await listener.installFallbackSyntheticPeers(peers)
            await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(frame) }
            await listener.stop(reason: "synthetic test complete")
        }
    }

    @Test func fallbackRefusesWhenMoreThanOneConnectionSelectsTheTarget() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        await listener.installFallbackSyntheticPeers([await rig.session(), await rig.session(), await rig.session()])
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
            try await listener.publish(recipientText(uncorrelatedDescriptor()))
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func fallbackNeverOverridesTheOwnersMediaRefusal() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let descriptor = recipientDescriptor(try await rig.submit(on: session), audio: true)
        let listener = try fallbackListener(rig: rig, enabled: true)
        await listener.installFallbackSyntheticPeers([session])
        // Sequence 1 before 0 is a media refusal of a known request, not an unknown reply.
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientAudio(descriptor, sequence: 1))
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test(arguments: ["lockdown", "deny", "locked", "rebound", "deselect"])
    func fallbackHonoursHostGates(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let listener = try fallbackListener(rig: rig, enabled: true)
        await listener.installFallbackSyntheticPeers([session])
        let frame = recipientText(uncorrelatedDescriptor())
        #expect(await session.uncorrelatedReplyAdmission(frame) == .selectsTarget)
        switch change {
        case "lockdown": _ = await rig.host.engageLockdown(reason: "synthetic panic")
        case "deny": _ = try await rig.host.deny(RecipientTestRig.target)
        case "locked": _ = try await rig.host.setTier(.locked, for: RecipientTestRig.target)
        case "rebound": await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement")])
        default: _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        }
        #expect(await session.uncorrelatedReplyAdmission(frame) == .unrelated)
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(frame) }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func expiredRequestsAreUncorrelatedAgain() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let frame = recipientText(recipientDescriptor(try await rig.submit(on: session)))
        #expect(await session.uncorrelatedReplyAdmission(frame) == .ownsRequest)
        rig.clock.advance(120_000)
        #expect(await session.uncorrelatedReplyAdmission(frame) == .selectsTarget)
        #expect(!(await session.enqueueUncorrelatedReply(frame, enqueue: { false })))
        #expect(await session.enqueueUncorrelatedReply(frame, enqueue: { true }))
    }
}
