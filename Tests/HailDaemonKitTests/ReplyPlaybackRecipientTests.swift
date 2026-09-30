import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Host-side admission gates before playback publication; not physical hearing or UI replay proof.
@Suite struct ReplyPlaybackRecipientTests {
    @Test func requestBelongsOnlyToItsIngressSessionNotDisplayNameOrWireID() async throws {
        let rig = try await RecipientTestRig.make()
        let origin = await rig.session()
        let other = await rig.session()
        let ingress = sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic")))
        #expect(await origin.receive(ingress).frames.isEmpty)
        let context = try #require(await rig.adapter.contexts.last)
        #expect(context.id != ingress.id)
        #expect(await other.receive(ingress).frames.isEmpty)
        let otherContext = try #require(await rig.adapter.contexts.last)
        #expect(otherContext.id != context.id)
        #expect(otherContext.connectionID != context.connectionID)
        let reply = recipientDescriptor(context)
        #expect(!(await other.acceptsHostReply(recipientText(reply))))
        #expect(await origin.acceptsHostReply(recipientText(reply)))
        var wireID = reply
        wireID.requestID = ingress.id
        #expect(!(await origin.acceptsHostReply(recipientText(wireID))))
    }

    @Test func unknownAndLegacyRequestsNeverBecomePrivateReplies() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        for request in [UUID?.none, UUID()] {
            var reply = recipientDescriptor(context, audio: true)
            reply.requestID = request
            #expect(!(await session.acceptsHostReply(recipientText(reply))))
            #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
        }
        #expect(await session.acceptsHostReply(recipientText(recipientDescriptor(context))))
    }

    @Test func duplicateTextAndChangedDescriptorAreRefused() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        var changed = reply
        changed.id = UUID()
        #expect(!(await session.acceptsHostReply(recipientAudio(changed, sequence: 0))))
        changed = reply
        changed.priority = .urgent
        #expect(!(await session.acceptsHostReply(recipientAudio(changed, sequence: 0))))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0, final: true)))
    }

    @Test(arguments: [false, true])
    func textAndAudioSharePinnedIdentityInEitherArrivalOrder(audioFirst: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        let ordered = audioFirst
            ? [recipientAudio(reply, sequence: 0, final: true), recipientText(reply)]
            : [recipientText(reply), recipientAudio(reply, sequence: 0, final: true)]
        for frame in ordered { #expect(await session.acceptsHostReply(frame)) }
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0, final: true))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1))))
    }

    @Test func duplicateSkippedAndMismatchedAudioCannotAdvanceStream() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1))))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 2))))
        var changed = reply
        changed.audioStreamID = UUID()
        #expect(!(await session.acceptsHostReply(recipientAudio(changed, sequence: 1))))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 1, final: true)))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 2))))
    }

    @Test func earlyReplyRequiresSuccessfulCommittedHandoff() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await rig.adapter.holdHandoff()
        let submission = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        let reply = recipientDescriptor(try #require(await rig.adapter.contexts.last))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        await rig.adapter.releaseHandoff()
        #expect(await submission.value.frames.isEmpty)
        #expect(await session.acceptsHostReply(recipientText(reply)))
    }

    @Test func failedHandoffNeverCreatesReplyAuthority() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await rig.adapter.failHandoff()
        let result = await session.receive(sessionFrame(
            target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
        ))
        #expect(!result.frames.isEmpty)
        let reply = recipientDescriptor(try #require(await rig.adapter.contexts.last), audio: true)
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 0))))
    }

    @Test func acceptedAudioFramesAreBoundedEvenBeforeFinalMarker() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        for sequence in 0..<1_024 {
            try #require(await session.acceptsHostReply(recipientAudio(reply, sequence: sequence)))
        }
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 1_024, final: true))))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
    }
}
