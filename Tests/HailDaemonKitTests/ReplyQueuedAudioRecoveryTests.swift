#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioRecoveryTests {
    @Test func transientEnqueueFailureKeepsRequestForOwnTerminalOnly() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
            let peer = try #require(await listener.peers.values.first)
            let reply = recipientDescriptor(context, audio: true), text = queuedTextCard(reply)
            let first = recipientAudio(reply, sequence: 0), middle = recipientAudio(reply, sequence: 1)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: first)).ticket)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text/card before transient refusal") == text)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: first))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "stream starts") == first)
            await #expect(throws: LocalReplyRefusal.publicationFailed) {
                try await ReplyAudioEnqueueTesting.$rejectTransport.withValue(true, operation: {
                    try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: middle))
                })
            }
            #expect(queue.valid(ticket))
            #expect(await peer.session.recoveryRequestExists(context.id))
            #expect(rig.details("reply_audio_refused") == [
                "reason=publication_failed request=\(context.id.uuidString) ticket=\(ticket.position)"
            ])
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: middle)).skipped)
            #expect(queue.valid(ticket))
            #expect(rig.details("reply_audio_skipped") == [
                "reason=terminal_only request=\(context.id.uuidString) ticket=\(ticket.position)"
            ])
            let terminal = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
                payload: .audio(.init(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 1,
                    streamID: reply.audioStreamID, isFinal: true, bytes: Data([0, 0]), reply: reply)))
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: terminal))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "only recovery terminal reaches device") == terminal)
            #expect(!queue.valid(ticket))
            try await rig.pair.boundedBarrier(step: "no extra data or duplicate terminal")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
extension HostSession {
    fileprivate func recoveryRequestExists(_ id: UUID) -> Bool { replyRequests[id] != nil }
}
#endif
