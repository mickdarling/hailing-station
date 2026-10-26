import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct ReplySegmentsDeviceSessionTests {
    @MainActor @Test func deviceSchedulesAcrossSegmentEndWithoutPausing() throws {
        let player = SegmentsReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let stream = UUID()
        let reply = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target", audioStreamID: stream)
        for sequence in 0...1 {
            let audio = AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                                     streamID: stream, isFinal: sequence == 1, bytes: Data([1, 0]), reply: reply,
                                     isSegmentEnd: sequence == 0)
            let frame = Frame(timestamp: Int64(sequence), target: "target", source: "host", payload: .audio(audio))
            let decoded = try FrameCoding.decode(FrameCoding.encode(frame))
            controller.ingest(HostReplyEvent(endpointID: "synthetic", frame: decoded))
        }
        #expect(player.scheduled.map(\.sequence) == [0, 1])
        #expect(player.completions == 1) // Only final completes a reply; a segment marker schedules no pause.
        #expect(player.pauses == 0)
        #expect(!controller.isPaused)
    }

    @Test func deviceRefusesReplyYieldFromHostWithoutAdvertisingSegments() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector)
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        guard case .control(.hello(let hello))? = try await socket.sentFrames().first?.payload else {
            Issue.record("expected device hello")
            return
        }
        #expect(!hello.capabilities.contains(ReplySegments.capability))
        try await socket.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        try await socket.push(.replyYield(reply: UUID(), segment: 1))
        try await waitUntil {
            if case .failed = await connection.currentSnapshot().state { return true }
            return false
        }
        #expect(await connection.currentSnapshot().state
            == .failed(reason: "unexpected control frame"))
        #expect(await socket.closeCount == 1)
        await connection.disconnect()
    }
}

@MainActor private final class SegmentsReplyPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var completions = 0
    var pauses = 0
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if onPlayed != nil { completions += 1 }
    }
    func cancel() {}
    func pause() { pauses += 1 }
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
