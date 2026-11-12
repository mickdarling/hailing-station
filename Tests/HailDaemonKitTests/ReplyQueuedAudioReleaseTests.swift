#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioReleaseTests {
    @Test func socketReleaseUsesOwnKeyEvenWhenPublicationBudgetIsFull() async throws {
        let clock = QueuedAudioClock(), rig = try await clock.makeRig()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-rel-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            let queue = rig.env.listener.replyAudioQueue
            let ticket = try #require(await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket)
            let other = try #require(await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket)
            #expect(ticket.releaseKey != nil && ticket.releaseKey != other.releaseKey)
            await endpoint.fillReleaseTestBudget()
            let forged = LocalReplyAudioTicket(epoch: other.epoch, position: other.position,
                                               releaseKey: ticket.releaseKey)
            try await release(forged, socket: socket)
            #expect(queue.valid(other))
            try await release(ticket, socket: socket)
            try await release(ticket, socket: socket)
            #expect(!queue.valid(ticket))
            #expect(queue.outstandingCount == 1)
            try await release(.init(epoch: ticket.epoch, position: other.position + 100), socket: socket)
            #expect(queue.valid(other))
            clock.advance(ReplyAudioQueue.jobLifetime)
            try await release(other, socket: socket)
            #expect(queue.outstandingCount == 0)
            let finished = try queue.ticket()
            queue.finish(finished)
            try await release(finished, socket: socket)
            #expect(queue.outstandingCount == 0)
            let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0)
            queue.associate(ticket, frame: frame)
            #expect(queue.enqueue(ticket, connection: nil, target: RecipientTestRig.target, { true }) == .expired)
            try await rig.pair.boundedBarrier(step: "release publishes no content")
        } catch { await endpoint.stop(); await rig.finish(); throw error }
        await endpoint.stop()
        await rig.finish()
    }
    private func release(_ ticket: LocalReplyAudioTicket, socket: URL) async throws {
        let response = try await exchange(.init(action: "release", ticket: ticket), socket: socket)
        #expect(response.error == nil && response.code == nil && response.delivered == 0)
        #expect(response.replyAudio == LocalReplyAudioReport())
    }
    private func exchange(_ request: LocalReplyAudioRequest, socket: URL) async throws -> LocalReplyResponse {
        try await submit(JSONEncoder().encode(request), socket: socket.path)
    }
}
extension LocalReplyEndpoint {
    fileprivate func fillReleaseTestBudget() {
        for _ in 0..<Self.maxFramesPerMinute { limiter.record("local-reply", at: clock.now) }
    }
}
#endif
