import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyQueueLifecycleTests {
    @Test(arguments: [false, true])
    func explicitStopMustEndPreAudioAuthority(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            #expect(await rig.listener.stopReplyPlayback(
                connection: session.connectionID, markQueuedAudio: markQueued
            ) == "stopped")
            _ = try await recipientSocketReceive(on: rig.first.socket)
            #expect(await session.replyRequests[context.id] == nil, "Stop retracts authority immediately")
            #expect(await session.queuedReplyDeadlines.isEmpty)
            for _ in 0..<10 {
                rig.recipient.clock.advance(20_000)
                _ = await session.renewQueuedReplyAuthority()
            }
            let check = try? await rig.listener.replyAudio(.init(action: "check", ticket: ticket, frame: probe))
            #expect(check?.skipped != false)
            if markQueued { #expect(check?.reason == "stopped") }
            let publish = try? await rig.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: probe))
            #expect(publish?.skipped != false)
            #expect(await session.replyRequests[context.id] == nil,
                    "Stopped pre-audio request must not renew past its normal expiry")
            let unqueuedDelivery = try? await rig.listener.publish(probe)
            #expect(unqueuedDelivery != 1, "Stopped pre-audio authority must refuse unticketed audio")
            if unqueuedDelivery == 1 { _ = try await recipientSocketReceive(on: rig.first.socket) }
        }
    }

    @Test func releasedJobMustEndRenewal() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            _ = try await rig.listener.replyAudio(.init(action: "release", ticket: ticket))
            for _ in 0..<10 {
                rig.recipient.clock.advance(20_000)
                _ = await session.renewQueuedReplyAuthority()
            }
            #expect(await session.replyRequests[context.id] == nil,
                    "Released pre-audio job must not keep its request slot alive")
            #expect(await session.queuedReplyDeadlines.isEmpty)
            #expect(await session.queuedReplyAuthorityTask == nil)
            let publication = try? await rig.listener.publish(probe)
            #expect(publication != 1)
            if publication == 1 { _ = try await recipientSocketReceive(on: rig.first.socket) }
        }
    }

    @Test func unticketedTextCannotAcquireAQueueHeartbeat() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await session.queuedReplyDeadlines.isEmpty)
        #expect(await session.queuedReplyAuthorityTask == nil)
        rig.clock.advance(121_000)
        #expect(await !session.renewQueuedReplyAuthority())
        #expect(await !session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
    }

    @Test(arguments: ["connection", "privacy", "dismiss", "job_end"])
    func jobRetirementCannotRenewOrPublish(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        let queue = ReplyAudioQueue(now: rig.clock.instant)
        queue.register(context.connectionID)
        let ticket = try queue.ticket(frame: recipientAudio(reply, sequence: 0))
        await session.bindQueuedReplyAuthority(recipientText(reply), queue: queue)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        switch change {
        case "connection": queue.forget(context.connectionID)
        case "privacy": _ = await session.dropRepliesForPrivacy()
        case "dismiss": await session.stopHeldReply(reply.id)
        default: queue.finish(ticket)
        }
        rig.clock.advance(20_000)
        #expect(await !session.renewQueuedReplyAuthority())
        #expect(await session.replyRequests[context.id] == nil)
        #expect(await !session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
    }

    @Test func authorityDeadlineIsCheckedOnAudioAdmission() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        try await session.reserveTestAudioJob(reply)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        for _ in 0..<134 {
            rig.clock.advance(20_000)
            _ = await session.renewQueuedReplyAuthority()
        }
        // A publication races the next scheduled heartbeat at the fixed 45-minute boundary.
        rig.clock.advance(20_001)
        #expect(await !session.acceptsHostReply(recipientAudio(reply, sequence: 0)),
                "Audio admission must check the fixed deadline even before its periodic sweeper runs")
    }
}
