#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioEndpointTests {
    @Test func socketTicketCheckAndPublicationPreserveTextOnStop() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-q-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            try await rig.start()
            let descriptor = uncorrelatedDescriptor(audio: true)
            let text = recipientText(descriptor), audio = recipientAudio(descriptor, sequence: 0)
            #expect(try await submit(FrameCoding.encode(text), socket: socket.path).delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "socket text") == text)
            let issued = try await exchange(.init(action: "enqueue"), socket: socket)
            let ticket = try #require(issued.replyAudio?.ticket)
            #expect(issued.delivered == 0 && issued.error == nil)
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "socket stop").payload == .control(.stopPlayback))
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            let decision = try await exchange(.init(action: "check", ticket: ticket, frame: audio), socket: socket)
            #expect(decision.replyAudio == LocalReplyAudioReport(skipped: true))
            #expect(decision.delivered == 0 && decision.error == nil && decision.code == nil)
            #expect(rig.details("reply_audio_skipped") == ["reason=stopped request=none ticket=\(ticket.position)"])
            let later = try #require(await exchange(.init(action: "enqueue"), socket: socket).replyAudio?.ticket)
            #expect(later.position > ticket.position)
            let played = try await exchange(.init(action: "publish", ticket: later, frame: audio), socket: socket)
            #expect(played.replyAudio == LocalReplyAudioReport() && played.delivered == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "socket later audio") == audio)
            try await barrier(on: rig.socket, step: "socket queue complete")
        } catch {
            await endpoint.stop()
            await rig.finish()
            throw error
        }
        await endpoint.stop()
        await rig.finish()
    }

    @Test(arguments: [
        #"{"kind":"reply-audio","action":"enqueue","extra":true}"#,
        #"{"kind":"reply-audio","action":"enqueue","ticket":null}"#,
        #"{"kind":"reply-audio","action":"check"}"#
    ])
    func socketRejectsMalformedQueueRequests(line: String) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-qs-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        try await endpoint.start()
        do {
            let refused = try await submit(Data(line.utf8), socket: socket.path)
            #expect(refused.code == .decodeFailure && refused.delivered == 0 && refused.replyAudio == nil)
            try await barrier(on: rig.socket, step: "invalid queue shape sends nothing")
        } catch {
            await endpoint.stop()
            await rig.finish()
            throw error
        }
        await endpoint.stop()
        await rig.finish()
    }

    @Test func refusedQueuedPublishCountsForDoctorAndMissingTargetIsNotPushed() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-qa-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config/reply.sock")
        let auditDirectory = scratch.appendingPathComponent("audit")
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.env.listener,
            audit: AuditLog(directory: auditDirectory))
        try await endpoint.start()
        do {
            let ticket = try await queuedAudioTicket(rig.env.listener)
            var frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            frame.target = nil
            let missing = try await exchange(.init(action: "publish", ticket: ticket, frame: frame), socket: socket)
            #expect(missing.code == .replyTargetMissing && missing.delivered == 0)
            let history = try AuditHistory(directory: auditDirectory).today()
            #expect(history.allSatisfy { !$0.contains("\"kind\":\"pushed\"") })
            let summary = try RefusalSummary.read(from: AuditHistory(directory: auditDirectory))
            #expect(summary.counts == [.init(reason: "replyTargetMissing", last15Minutes: 1, lastHour: 1)])
            try await barrier(on: rig.socket, step: "refused queued publish sends nothing")
        } catch {
            await endpoint.stop()
            await rig.finish()
            throw error
        }
        await endpoint.stop()
        await rig.finish()
    }

    private func exchange(_ request: LocalReplyAudioRequest, socket: URL) async throws -> LocalReplyResponse {
        try await submit(JSONEncoder().encode(request), socket: socket.path)
    }
}
#endif
