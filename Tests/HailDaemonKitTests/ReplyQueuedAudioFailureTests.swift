#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension ReplyQueuedAudioBarrierTests {
    @Test(arguments: ["timeout", "lookup", "teardown"])
    func failedResolutionPreservesOtherDevicesStreamingAudio(failure: String) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let holds = QueuedFailureHolds()
        var stopping: Task<Void, Never>?
        defer { holds.release() }
        do {
            let listener = rig.env.listener
            let original = try #require(await listener.peers.first)
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target, "recipient:other"])
            defer { other.close() }
            let (stream, streaming) = try await startQueuedStopUnrelatedStream(other, listener: listener)
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let reply = uncorrelatedDescriptor(audio: true), text = recipientText(reply)
            let audio = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: other.sockets[0], step: "T text retained") == text)
            let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            stopping = try await resolveFailure(rig, original: original, failure: failure, old: old, holds: holds)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: audio))
                == LocalReplyAudioReport(skipped: true))
            try await finishFailureAudio(listener, pair: other, stream: stream, ticket: streaming, audio: audio)
            holds.snapshot.release()
            await stopping?.value
            try await other.boundedBarrier(step: "covered old audio stays silent")
        } catch {
            holds.snapshot.release(); holds.timeout.release()
            await stopping?.value
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    private func resolveFailure(
        _ rig: DeviceVoiceStopRig, original: (key: UUID, value: WebSocketPeer), failure: String,
        old: LocalReplyAudioTicket, holds: QueuedFailureHolds
    ) async throws -> Task<Void, Never>? {
        let listener = rig.env.listener, queue = listener.replyAudioQueue
        let connection = await original.value.session.connectionID
        let snapshotHook: @Sendable () async -> Void = { holds.entered.release(); await holds.snapshot.wait() }
        let captured = ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await holds.timeout.wait() }, operation: {
            ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue(failure == "timeout" ? snapshotHook : nil,
                operation: { queue.captureStop(connection) })
        })
        let stop = try #require(captured)
        if failure == "timeout" {
            let stopping = Task { _ = await listener.dropPrivateReplies(connection: connection, stop: stop) }
            await holds.entered.wait()
            let barrier = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ holds.waiting.release() }, operation: {
                    try await queue.waitForStops(old)
                })
            }
            await holds.waiting.wait()
            holds.timeout.release()
            try await barrier.value
            return stopping
        } else {
            if failure == "lookup" {
                _ = await original.value.session.failure(.malformed, "synthetic closure", close: true)
            } else { await listener.peerEnded(original.key) }
            #expect(await listener.dropPrivateReplies(connection: connection, stop: stop) == 0)
        }
        return nil
    }

    private func finishFailureAudio(
        _ listener: WebSocketListener, pair: FallbackSocketPair, stream: ReplyDescriptor,
        ticket: LocalReplyAudioTicket, audio: Frame
    ) async throws {
        let final = recipientAudio(stream, sequence: 1, final: true)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: final))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[1], step: "U continues after failed stop") == final)
        let fresh = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: fresh, frame: audio))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[0], step: "post-cutoff T plays") == audio)
    }
}

private struct QueuedFailureHolds: Sendable {
    let timeout = VoiceStopConfirmationHold(), snapshot = VoiceStopConfirmationHold()
    let entered = VoiceStopConfirmationHold(), waiting = VoiceStopConfirmationHold()
    func release() { timeout.release(); snapshot.release() }
}

func startQueuedStopUnrelatedStream(
    _ pair: FallbackSocketPair, listener: WebSocketListener
) async throws -> (ReplyDescriptor, LocalReplyAudioTicket) {
    try await recipientSocketSend(sessionFrame(target: "recipient:other",
        payload: .text(TextPayload(text: "synthetic U input"))), on: pair.sockets[1])
    try await recipientSocketBarrier(on: pair.sockets[1], step: "U owns its input")
    let stream = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other", audioStreamID: UUID())
    let first = recipientAudio(stream, sequence: 0)
    let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: first)).ticket)
    #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: first))
        == LocalReplyAudioReport())
    #expect(try await receiveFrame(on: pair.sockets[1], step: "U starts before stop") == first)
    return (stream, ticket)
}

#endif
