#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension ReplyQueuedAudioProbeTests {
    @Test(arguments: ["entry-timeout", "restore-timeout", "restore-selection"])
    func slowPrivacyNoticeKeepsOtherDeviceStreamingAndOldQueueSilent(mode: String) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let notice = VoiceStopConfirmationHold(), entered = VoiceStopConfirmationHold()
        let timeout = VoiceStopConfirmationHold()
        defer { notice.release(); timeout.release() }
        do {
            let listener = rig.env.listener
            let original = try #require(await listener.peers.values.first)
            let connection = await original.session.connectionID
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target, "recipient:other"])
            defer { other.close() }
            let replies = try await privacyReplies(rig, pair: other)
            rig.env.router.mediaNotices.enqueue { entered.release(); await notice.wait() }
            await entered.wait()
            try await expirePrivacyStop(rig, connection: connection, ticket: replies.old, mode: mode, timeout: timeout)
            notice.release()
            await rig.env.router.mediaNotices.queued {}.value
            #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 0)
            await rig.env.router.mediaNotices.queued {}.value
            #expect(await !listener.replyHold.holds(connection))
            try await assertPrivacyAudio(listener, pair: other, replies: replies, mode: mode)
        } catch {
            notice.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    private func privacyReplies(
        _ rig: DeviceVoiceStopRig, pair: FallbackSocketPair
    ) async throws -> SlowPrivacyReplies {
        let listener = rig.env.listener
        let (stream, streaming) = try await startQueuedStopUnrelatedStream(pair, listener: listener)
        _ = try await pair.submitInput(on: 0, rig: rig.env.rig)
        let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
        let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
        let unrelated = recipientAudio(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other",
            audioStreamID: UUID()), sequence: 0, final: true)
        let queuedU = try #require(await listener.replyAudio(.init(action: "enqueue", frame: unrelated)).ticket)
        return SlowPrivacyReplies(audio: audio, old: old, stream: stream, streaming: streaming,
            unrelated: unrelated, queuedU: queuedU)
    }

    private func expirePrivacyStop(
        _ rig: DeviceVoiceStopRig, connection: UUID, ticket: LocalReplyAudioTicket,
        mode: String, timeout: VoiceStopConfirmationHold
    ) async throws {
        let router = rig.env.router, queue = rig.env.listener.replyAudioQueue
        let acceptedAt = ContinuousClock.now
        let enter: @Sendable () -> Void = {
            if mode.hasPrefix("restore") { router.state.withLock { state in
                let source = UUID()
                state.parks[source] = ParkedPrivacy(connection: source, device: nil, parkedAt: Date())
                router.restorePrivacy(to: connection, in: &state)
                #expect(state.streamTargets[connection] == nil)
            } } else { router.ambientPrivacyPreArm(connection: connection) }
        }
        let heldTimeout: @Sendable () async -> Void = { await timeout.wait() }
        let timeoutHook = mode == "restore-selection" ? heldTimeout : nil
        ReplyAudioEnqueueTesting.$stopTimeout.withValue(timeoutHook, operation: enter)
        #expect(await rig.env.listener.replyHold.holds(connection))
        try await rig.pair.select("recipient:other", on: 0)
        try await rig.pair.select(RecipientTestRig.target, on: 0)
        if mode != "restore-selection" {
            // The real 250 ms timeout opens this continuation while the notice queue remains held.
            try await queue.waitForStops(ticket)
            #expect(acceptedAt.duration(to: .now) >= .milliseconds(250))
        }
    }

    private func assertPrivacyAudio(
        _ listener: WebSocketListener, pair: FallbackSocketPair, replies: SlowPrivacyReplies, mode: String
    ) async throws {
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: replies.old, frame: replies.audio))
            == LocalReplyAudioReport(skipped: true, reason: "stopped"))
        let final = recipientAudio(replies.stream, sequence: 1, final: true)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: replies.streaming, frame: final))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[1], step: "other device U survives timeout") == final)
        if mode == "restore-selection" {
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: replies.queuedU,
                frame: replies.unrelated)) == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: pair.sockets[1], step: "unrelated queued U survives restore selection")
                == replies.unrelated)
        }
        let fresh = try #require(await listener.replyAudio(.init(action: "enqueue", frame: replies.audio)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: fresh, frame: replies.audio))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[0], step: "post-privacy T plays") == replies.audio)
        try await pair.boundedBarrier(step: "old covered audio stays silent after privacy exit")
    }
}
private struct SlowPrivacyReplies {
    let audio: Frame
    let old: LocalReplyAudioTicket
    let stream: ReplyDescriptor
    let streaming: LocalReplyAudioTicket
    let unrelated: Frame
    let queuedU: LocalReplyAudioTicket
}
#endif
