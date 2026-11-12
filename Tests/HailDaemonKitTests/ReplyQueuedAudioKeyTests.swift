#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioKeyTests {
    @Test(arguments: ["malformed", "check", "publish", "release"], [false, true])
    func forgedClientRequestCannotRetireNeighbour(action: String, wrongKey: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hs-key-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            try await rig.start()
            let neighbour = try #require(await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket)
            let attacker = try #require(await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket)
            let forged = LocalReplyAudioTicket(epoch: attacker.epoch, position: neighbour.position,
                                               releaseKey: wrongKey ? attacker.releaseKey : nil)
            let unrouted = recipientAudio(ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "absent",
                audioStreamID: UUID()), sequence: 0)
            let refused = try await exchange(.init(action: action, ticket: forged,
                frame: action == "release" ? nil : unrouted), socket: socket)
            #expect(refused.code == .invalidReplyPayload)
            #expect(refused.error == LocalReplyRefusal.invalidReplyPayload.message && refused.delivered == 0)
            #expect(refused.replyAudio == LocalReplyAudioReport())
            #expect(rig.env.listener.replyAudioQueue.valid(neighbour))
            #expect(rig.env.listener.replyAudioQueue.outstandingCount == 2)
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let played = try await exchange(.init(action: "publish", ticket: neighbour, frame: audio), socket: socket)
            #expect(played.delivered == 1 && played.error == nil && played.code == nil)
            #expect(played.replyAudio == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "neighbour survives forged retirement") == audio)
            #expect(rig.details("reply_audio_skipped").isEmpty)
            try await rig.pair.boundedBarrier(step: "exactly one neighbour publication")
        } catch { await endpoint.stop(); await rig.finish(); throw error }
        await endpoint.stop()
        await rig.finish()
    }
    @Test func releaseHasTwentyIndependentRequestsPerMinute() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hs-kr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            try await rig.start()
            let queue = rig.env.listener.replyAudioQueue
            let released = try queue.ticket(), neighbour = try queue.ticket()
            await endpoint.fillKeyTestPublicationBudget()
            for _ in 0..<20 {
                let response = try await exchange(.init(action: "release", ticket: released), socket: socket)
                #expect(response.delivered == 0 && response.error == nil && response.code == nil)
                #expect(response.replyAudio == LocalReplyAudioReport())
            }
            let limited = try await exchange(.init(action: "release", ticket: neighbour), socket: socket)
            #expect(limited == LocalReplyResponse(delivered: 0, error: "rate limited"))
            #expect(queue.valid(neighbour) && queue.outstandingCount == 1)
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            #expect(try await rig.env.listener.replyAudio(.init(action: "publish", ticket: neighbour, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "release rate limit preserves neighbour") == audio)
            try await rig.pair.boundedBarrier(step: "release publishes no audio")
        } catch { await endpoint.stop(); await rig.finish(); throw error }
        await endpoint.stop()
        await rig.finish()
    }
    private func exchange(_ request: LocalReplyAudioRequest, socket: URL) async throws -> LocalReplyResponse {
        try await submit(JSONEncoder().encode(request), socket: socket.path)
    }
}
extension LocalReplyEndpoint {
    fileprivate func fillKeyTestPublicationBudget() {
        for _ in 0..<Self.maxFramesPerMinute { limiter.record("local-reply", at: clock.now) }
    }
}
#endif
