#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioCapacityTests {
    @Test(arguments: [false, true])
    func socketFloodReservesAllTicketsWithoutCuttingExistingAudio(framed: Bool) async throws {
        let clock = QueuedAudioClock()
        let rig = try await ReplyAudioEnqueueTesting.$clock.withValue({ clock.now }, operation: {
            try await DeviceVoiceStopRig.make()
        })
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-cap-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            try await rig.start()
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port, selecting: ["recipient:other"])
            defer { other.close() }
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let stream = uncorrelatedDescriptor(audio: true), queued = uncorrelatedDescriptor(audio: true)
            let first = recipientAudio(stream, sequence: 0), final = recipientAudio(stream, sequence: 1, final: true)
            let queuedAudio = recipientAudio(queued, sequence: 0, final: true)
            let streaming = try #require(await exchange(.init(action: "enqueue", frame: first), socket: socket)
                .replyAudio?.ticket)
            #expect(try await exchange(.init(action: "publish", ticket: streaming, frame: first), socket: socket)
                .delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "stream starts before flood") == first)
            let old = try #require(await exchange(.init(action: "enqueue", frame: queuedAudio), socket: socket)
                .replyAudio?.ticket)
            try await flood(framed: framed, endpoint: endpoint, socket: socket, queue: queue)
            try await refusalKeepsText(rig, endpoint: endpoint, socket: socket)
            #expect(queue.outstandingCount == ReplyAudioQueue.jobLimit)
            #expect(try await exchange(.init(action: "publish", ticket: streaming, frame: final), socket: socket)
                .delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "stream survives flood") == final)
            #expect(try await exchange(.init(action: "publish", ticket: old, frame: queuedAudio), socket: socket)
                .delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "unrelated queue survives flood") == queuedAudio)
            try await expiryFreesSlots(clock, queue: queue, socket: socket)
            try await other.boundedBarrier(step: "flood probes never publish")
        } catch { await endpoint.stop(); await rig.finish(); throw error }
        await endpoint.stop()
        await rig.finish()
    }
}

extension ReplyQueuedAudioCapacityTests {
    private func expiryFreesSlots(_ clock: QueuedAudioClock, queue: ReplyAudioQueue, socket: URL) async throws {
        clock.advance(ReplyAudioQueue.jobLifetime)
        #expect(try await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket?.position
            == UInt64(ReplyAudioQueue.jobLimit + 1))
        #expect(queue.outstandingCount == 1)
    }
    private func flood(
        framed: Bool, endpoint: LocalReplyEndpoint, socket: URL, queue: ReplyAudioQueue
    ) async throws {
        let probe = recipientAudio(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other",
            audioStreamID: UUID()), sequence: 0)
        for index in 2..<ReplyAudioQueue.jobLimit {
            if index.isMultiple(of: 16) { await endpoint.resetQueueTestBudget() }
            let issued = try await exchange(.init(action: "enqueue", frame: framed ? probe : nil), socket: socket)
            let ticket = try #require(issued.replyAudio?.ticket)
            #expect(ticket.position == UInt64(index + 1))
            #expect(try await exchange(.init(action: "check", ticket: ticket, frame: probe), socket: socket)
                .replyAudio == LocalReplyAudioReport())
            #expect(queue.outstandingCount == index + 1)
        }
    }
    private func refusalKeepsText(
        _ rig: DeviceVoiceStopRig, endpoint: LocalReplyEndpoint, socket: URL
    ) async throws {
        await endpoint.resetQueueTestBudget()
        let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
        let reply = recipientDescriptor(context, audio: true), audio = recipientAudio(reply, sequence: 0)
        let refused = try await exchange(.init(action: "enqueue", frame: audio), socket: socket)
        #expect(refused == refusal())
        let text = queuedTextCard(reply)
        #expect(try await submit(FrameCoding.encode(text), socket: socket.path).delivered == 1)
        #expect(try await receiveFrame(on: rig.socket, step: "capacity refusal retains text and card") == text)
        #expect(try await exchange(.init(action: "enqueue"), socket: socket) == refusal())
        #expect(rig.details("reply_audio_refused")
            == ["reason=capacity request=\(context.id.uuidString)", "reason=capacity request=none"])
        try await rig.pair.boundedBarrier(step: "overflow sends text only")
    }
    private func refusal() -> LocalReplyResponse {
        var response = LocalReplyResponse(delivered: 0, error: LocalReplyRefusal.publicationFailed.message,
            code: .publicationFailed)
        response.replyAudio = LocalReplyAudioReport()
        return response
    }
    private func exchange(_ request: LocalReplyAudioRequest, socket: URL) async throws -> LocalReplyResponse {
        try await submit(JSONEncoder().encode(request), socket: socket.path)
    }
}

extension LocalReplyEndpoint {
    // Keep the socket framing, audit and dispatch real; advance only the orthogonal per-minute test budget.
    fileprivate func resetQueueTestBudget() { limiter = RateLimiter() }
}
#endif
