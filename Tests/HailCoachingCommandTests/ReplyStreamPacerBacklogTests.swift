import Foundation
import HailDaemonKit
import HailProtocol
import Testing
@testable import haild

/// #904 ask 4(b): deterministic host-send to client-read backlog, not device/transport completion proof.
@Suite struct ReplyStreamPacerBacklogTests {
    @Test func fortyFiveSecondsAtTwoPointFiveTimesRenderingHasASmallBacklog() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        var now = start
        var audio = 0.0
        var firstSend: ContinuousClock.Instant?
        var unread: [(readAt: ContinuousClock.Instant, pcm: Int, json: Int)] = []
        var maxFrames = 0, maxPCM = 0, maxJSON = 0
        var maxLead = 0.0
        let descriptor = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:reply",
                                         audioStreamID: UUID(), requestID: UUID())
        for sequence in 0..<37 {
            let size = StreamedReplyFrames.bytes(sequence: sequence)
            let duration = ReplyStreamPacer.seconds(pcm16Bytes: size, sampleRate: 24_000)
            // Renderer output is ready at 2.5x; serial submission may already have waited for the pacer.
            now = max(now, start.advanced(by: .seconds((audio + duration) / 2.5)))
            now = try pacer.admit(audio: duration, at: now)
            let first = firstSend ?? now
            firstSend = first
            // The client reads at each frame's playback start, then consumes it at 1x. No startup hold or jitter.
            let readAt = first.advanced(by: .seconds(audio))
            #expect(now <= readAt) // No underrun in this steady 2.5x renderer / 1x client model.
            unread.removeAll { $0.readAt <= now }
            if readAt > now { unread.append((readAt, size, try encodedBytes(descriptor, sequence: sequence))) }
            audio += duration
            let elapsed = first.duration(to: now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            maxLead = max(maxLead, audio - seconds)
            maxFrames = max(maxFrames, unread.count)
            maxPCM = max(maxPCM, unread.reduce(0) { $0 + $1.pcm })
            maxJSON = max(maxJSON, unread.reduce(0) { $0 + $1.json })
        }
        print("#904 simulation: frames=\(maxFrames) pcmBytes=\(maxPCM) jsonBytes=\(maxJSON) leadSeconds=\(maxLead)")
        #expect(audio == 45)
        // Fixed bounds deliberately fail with the former 20 s setting, rather than moving with that constant.
        #expect(ReplyStreamPacer.leadSeconds == 3)
        #expect(maxLead <= 4.25) // 3 s plus one full 1.25 s frame
        #expect(maxFrames <= 3)
        #expect(maxPCM <= 180_000)
    }

    private func encodedBytes(_ descriptor: ReplyDescriptor, sequence: Int) throws -> Int {
        let frame = Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
            payload: .audio(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
                streamID: descriptor.audioStreamID, isFinal: false,
                bytes: Data(count: StreamedReplyFrames.bytes(sequence: sequence)), reply: descriptor)))
        return try FrameCoding.encode(frame).count
    }
}
