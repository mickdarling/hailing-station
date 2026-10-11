import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ReplyPlaybackRecipientLifecycleTests {
    @Test(arguments: [-60_000, 604_800_000])
    func wallClockChangesCannotAlterMonotonicReplyLifetime(adjustment: Int64) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let descriptor = recipientDescriptor(try await rig.submit(on: session), audio: true)
        rig.clock.advance(100_000)
        rig.clock.adjustWallClock(adjustment)
        #expect(await session.acceptsHostReply(recipientText(descriptor)))
        rig.clock.advance(20_000)
        #expect(!(await session.acceptsHostReply(recipientAudio(descriptor, sequence: 0, final: true))))
    }

    @Test func changingDestinationInvalidatesTextAndAlreadyStartedAudioEvenAfterReturning() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
    }

    @Test func repeatedSameDestinationDoesNotInvalidateRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 1, final: true)))
    }

    @Test func reconnectAndClosedConnectionCannotAcquireOldRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let original = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: original), audio: true)
        let reconnect = await rig.session()
        #expect(!(await reconnect.acceptsHostReply(recipientText(reply))))
        _ = await original.receive(sessionFrame(version: 99, payload: .control(.ping(nonce: "close"))))
        #expect(!(await original.acceptsHostReply(recipientText(reply))))
        #expect(!(await original.acceptsHostReply(recipientAudio(reply, sequence: 0))))
    }

    @Test func expiryInvalidatesAnOpenAudioStream() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        rig.clock.advance(119_999)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        rig.clock.advance(1)
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1, final: true))))
    }

    @Test func capacityRefusesNewHandoffRatherThanEvictingLiveOrigin() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        var contexts: [ProviderTurnContext] = []
        for _ in 0..<64 { contexts.append(try await rig.submit(on: session)) }
        let refused = await session.receive(sessionFrame(
            target: RecipientTestRig.target, payload: .text(TextPayload(text: "capacity probe"))
        ))
        #expect(try onlyControl(refused) == .error(code: .rateLimited, message: "target action was refused"))
        #expect(refused.disposition == .keepOpen)
        #expect(await rig.adapter.contexts.count == 64)
        #expect(await session.acceptsHostReply(recipientText(recipientDescriptor(contexts[0]))))
        rig.clock.advance(120_000)
        _ = try await rig.submit(on: session)
        #expect(await rig.adapter.contexts.count == 65)
        #expect(!(await session.acceptsHostReply(recipientText(recipientDescriptor(contexts[1])))))
    }

    @Test(arguments: [false, true])
    func capacityReclaimsRetiredAuthorityWithoutPublishing(bindingRevocation: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        var contexts: [ProviderTurnContext] = []
        for _ in 0..<64 { contexts.append(try await rig.submit(on: session)) }
        if bindingRevocation {
            await rig.adapter.setTargets([
                AdapterTarget(name: "reply", binding: "reply-binding"),
                AdapterTarget(name: "other", binding: "other-binding")
            ])
        } else {
            _ = try await rig.host.deny(RecipientTestRig.target)
            _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        }
        let fresh = try await rig.submit(on: session)
        #expect(await rig.adapter.contexts.count == 65)
        #expect(await session.replyRequests.count == 1)
        #expect(await session.acceptsHostReply(recipientText(recipientDescriptor(fresh))))
        for context in contexts {
            #expect(!(await session.acceptsHostReply(recipientText(recipientDescriptor(context)))))
        }
    }

    @Test func deniedPolicyRetiresContextAndCannotReviveAfterRestoringGrant() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        _ = try await rig.host.deny(RecipientTestRig.target)
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1))))
        _ = try await rig.host.allow(RecipientTestRig.target, tier: .open)
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
    }

    @Test func reboundBindingRetiresContextEvenWhenOriginalBindingReturns() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "rebound-binding")])
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "reply-binding")])
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
    }

    @Test func selectionChangeDuringHandoffCannotCommitOldOrigin() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await rig.adapter.holdHandoff()
        let task = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        let reply = recipientDescriptor(try #require(await rig.adapter.contexts.last))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        await rig.adapter.releaseHandoff()
        _ = await task.value
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
    }

    @Test func lockedTierAndHostLockdownRefuseReplyPublication() async throws {
        for lockdown in [false, true] {
            let rig = try await RecipientTestRig.make()
            let session = await rig.session()
            let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
            if lockdown {
                _ = await rig.host.engageLockdown(reason: "synthetic test")
            } else {
                _ = try await rig.host.setTier(.locked, for: RecipientTestRig.target)
            }
            #expect(!(await session.acceptsHostReply(recipientText(reply))))
            #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
        }
    }
}
