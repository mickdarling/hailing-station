import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

struct ReplyJobEndTests {
    @Test func contentFreeEndLinesAndInvalidReports() throws {
        for reason in LocalReplyJobEnd.Reason.allCases {
            let report = LocalReplyJobEnd(reason: reason, frames: 3, audioMS: 500)
            let decoded = try JSONDecoder().decode(LocalReplyJobEnd.self, from: FrameCoding.encoder().encode(report))
            #expect(decoded.line == "reply_job_ended reason=\(reason.rawValue) frames=3 audio_ms=500")
        }
        #expect(LocalReplyJobEnd(reason: .done, frames: -1, audioMS: 0).line == nil)
        #expect(LocalReplyJobEnd(reason: .done, frames: 1, audioMS: -1).line == nil)
        let invalid = Data(#"{"kind":"reply-job-ended","reason":"private words","frames":0,"audioMS":0}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LocalReplyJobEnd.self, from: invalid) }
    }
}

#if os(macOS)
@Suite(.serialized, .frozenGuardBudget) struct ReplyJobEndEndpointTests {
    @Test func daemonAcceptsSlashHeavyQueuedAudioAndEndReportWithoutPublishingTelemetry() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-end-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            var frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0)
            if case .audio(var audio) = frame.payload {
                audio.bytes = Data(repeating: 255, count: 60_000)
                frame.payload = .audio(audio)
            }
            let encoder = FrameCoding.encoder()
            let queued = try await submit(encoder.encode(LocalReplyAudioRequest(action: "enqueue", frame: frame)),
                                          socket: socket.path)
            let ticket = try #require(queued.replyAudio?.ticket)
            let bytes = try encoder.encode(LocalReplyAudioRequest(action: "publish", ticket: ticket, frame: frame))
            #expect(bytes.count <= PayloadLimits.defaultMaxFrameBytes)
            #expect(try await submit(bytes, socket: socket.path).delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "slash-heavy queued audio") == frame)
            let ended = LocalReplyJobEnd(reason: .publicationFailed, frames: 1, audioMS: 1250)
            let response = try await submit(encoder.encode(ended), socket: socket.path)
            #expect(response.delivered == 0 && response.error == nil)
            try await barrier(on: rig.socket, step: "job end is host-only")
        } catch {
            await endpoint.stop()
            await rig.finish()
            throw error
        }
        await endpoint.stop()
        await rig.finish()
    }
}
#endif
