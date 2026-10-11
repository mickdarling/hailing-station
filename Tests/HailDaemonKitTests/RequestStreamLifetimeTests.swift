import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #467: a request stays current while its reply keeps flowing, so a long spoken answer plays in full. Synthetic
/// adapter and injected clock only.
@Suite struct RequestStreamLifetimeTests {
    private static let frame: Int64 = 1_250 // ms of audio per paced frame

    /// Text, then `count` audio frames paced one per `frame`; returns how many were accepted before the first refusal.
    private func stream(
        _ session: HostSession, _ rig: RecipientTestRig, _ reply: ReplyDescriptor, from start: Int = 0, count: Int,
        final: Bool = false
    ) async -> Int {
        for sequence in start..<(start + count) {
            let last = final && sequence == start + count - 1
            guard await session.acceptsHostReply(recipientAudio(reply, sequence: sequence, final: last)) else {
                return sequence - start
            }
            rig.clock.advance(Self.frame)
        }
        return count
    }

    @Test func aRequestBoundReplyOf170SecondsDeliversInFullWithItsTerminalMarker() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        rig.clock.advance(30_000) // the provider thinks for 30 s before answering
        #expect(await session.acceptsHostReply(recipientText(reply)))
        // 136 frames of 1.25 s (170 s), the last one final: past the old 120 s from the request.
        #expect(await stream(session, rig, reply, count: 136, final: true) == 136)
    }

    @Test func theFirstFrameStillHasTheOrdinaryTwoMinutes() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        rig.clock.advance(120_000)
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
    }

    @Test func anIdleGapBeyondTheBoundExpiresAFlowingRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await stream(session, rig, reply, count: 120) == 120) // 150 s in
        rig.clock.advance(60_000)
        #expect(await session.replyPublicationStatus(recipientAudio(reply, sequence: 120)) == .absent)
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 120))))
    }

    @Test func refusedFramesDoNotKeepARequestAlive() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await stream(session, rig, reply, count: 100) == 100) // 125 s in, past the first two minutes
        // Out-of-sequence and repeated frames are refused, every 20 s, and must not extend the request.
        for _ in 0..<3 {
            rig.clock.advance(20_000)
            #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 150))))
            #expect(!(await session.acceptsHostReply(recipientText(reply))))
        }
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 100))))
    }

    @Test func theStreamIsCappedAt35MinutesFromItsFirstFrame() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        // 35 minutes at 1.25 s a frame is 1,680 frames, inside the 3,072-frame cap; the cap ends it there.
        let accepted = await stream(session, rig, reply, count: 1_700)
        #expect(accepted == 1_680) // frames at 0 to 2,098.75 s; the next, at 2,100 s, is past the cap
    }

    /// The real `--request` path: an unleased ambient record (#230), re-read from the listing before every frame
    /// (`unleasedBindingIsCurrent`) as the listener does, then enqueued.
    @Test func anUnleasedAmbientRecordStreamsA170SecondReplyAndARebindStillEndsIt() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let owner = try #require(try await LegacyReferenceRig.dispatch(session, reference: UUID()))
        #expect(try #require(await session.replyRequests[owner]).bindingLease == nil)
        let reply = referenceDescriptor(owner, audio: true)
        func publish(_ frame: Frame) async -> Bool {
            guard await session.unleasedBindingIsCurrent(frame) else { return false }
            return await session.acceptsHostReply(frame)
        }
        rig.clock.advance(30_000)
        #expect(await publish(recipientText(reply)))
        for sequence in 0..<136 {
            #expect(await publish(recipientAudio(reply, sequence: sequence, final: sequence == 135)))
            rig.clock.advance(Self.frame)
        }
        // A second stream on a fresh reference: a rebind mid-stream (150 s in) still refuses it.
        let next = try #require(try await LegacyReferenceRig.dispatch(session, reference: UUID()))
        let second = referenceDescriptor(next, audio: true)
        #expect(await publish(recipientText(second)))
        for sequence in 0..<120 {
            #expect(await publish(recipientAudio(second, sequence: sequence)))
            rig.clock.advance(Self.frame)
        }
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement")])
        #expect(!(await publish(recipientAudio(second, sequence: 120))))
        #expect(await session.replyRequests[next] == nil)
    }

    @Test(arguments: ["selection", "policy", "stop"])
    func revocationStillEndsAStreamMidway(change: String) async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let reply = recipientDescriptor(try await rig.submit(on: session), audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(await stream(session, rig, reply, count: 120) == 120) // 150 s in, kept current only by the stream
        switch change {
        case "selection":
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        case "policy": _ = try await rig.host.deny(RecipientTestRig.target)
        default: _ = await session.stopReplyPlayback()
        }
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 120))))
        #expect(!(await session.acceptsHostReply(recipientAudio(reply, sequence: 120, final: true))))
    }
}
