import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Injected request clock and synthetic transport; no physical playback or live daemon.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueueAuthorityTests {
    @Test func queuedTextKeepsAuthorityForWholeWatchdogAndThenStreamsInFull() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        try await session.reserveTestAudioJob(reply)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        let before = try #require(await session.replyRequests[context.id])
        // Past both ordinary request lifetime and stream cap, but inside the explicit 45-minute queue bound.
        for _ in 0..<130 {
            rig.clock.advance(20_000)
            #expect(await session.renewQueuedReplyAuthority())
        }
        let after = try #require(await session.replyRequests[context.id])
        #expect(after.frames == before.frames && after.audioSequence == 0 && after.descriptor == before.descriptor)
        #expect(await session.repliesInFlight.isEmpty)
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        #expect(await session.queuedReplyDeadlines.isEmpty)
        // A complete 30-minute stream after waiting: queue time does not consume the stream watchdog.
        for sequence in 1...90 {
            rig.clock.advance(20_000)
            #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: sequence, final: sequence == 90)))
        }
    }

    @Test func queueDeadlineRetiresAuthorityWithQueueTimeoutReason() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        let events = ReplySegmentsEvents()
        await session.observeQueueEvents(events)
        try await session.reserveTestAudioJob(reply)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        for _ in 0..<134 {
            rig.clock.advance(20_000)
            #expect(await session.renewQueuedReplyAuthority())
        }
        rig.clock.advance(20_000)
        #expect(await !session.renewQueuedReplyAuthority())
        #expect(await session.replyRequests[context.id] == nil)
        #expect(events.queueTimeoutCount == 1)
        #expect(await !session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
    }

    @Test func explicitQueueStopCannotBeUndoneByAuthorityRenewal() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.first.socket)
            #expect(await rig.listener.stopReplyPlayback(
                connection: session.connectionID, markQueuedAudio: true
            ) == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            rig.recipient.clock.advance(20_000)
            _ = await session.renewQueuedReplyAuthority()
            let report = try await rig.listener.replyAudio(.init(action: "check", ticket: ticket, frame: probe))
            #expect(report.skipped && report.reason == "stopped")
            #expect(try await rig.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: probe)).skipped)
            #expect(await session.repliesInFlight.isEmpty)
            try await recipientSocketBarrier(on: rig.first.socket)
        }
    }

    @Test(arguments: ["privacy", "selection", "policy", "dismiss", "expired"])
    func reservationCannotRestoreLostAuthority(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        let reply = recipientDescriptor(context, audio: true)
        try await session.reserveTestAudioJob(reply)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        switch change {
        case "privacy": _ = await session.dropRepliesForPrivacy()
        case "selection":
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        case "policy": _ = try await rig.host.deny(RecipientTestRig.target)
        case "dismiss": await session.stopHeldReply(reply.id)
        default: rig.clock.advance(121_000) // missed heartbeats may not revive already-expired authority
        }
        _ = await session.renewQueuedReplyAuthority()
        #expect(await !session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        if change == "privacy" || change == "selection" || change == "expired" {
            #expect(await session.replyRequests[context.id] == nil)
        }
    }
}

extension HostSession {
    func observeQueueEvents(_ events: ReplySegmentsEvents) { replyEvent = { events.record($0) } }
}

extension HostSession {
    func reserveTestAudioJob(_ reply: ReplyDescriptor) throws {
        let queue = ReplyAudioQueue(now: requestClock)
        queue.register(connectionID)
        _ = try queue.ticket(frame: recipientAudio(reply, sequence: 0))
        bindQueuedReplyAuthority(recipientText(reply), queue: queue)
    }
}
