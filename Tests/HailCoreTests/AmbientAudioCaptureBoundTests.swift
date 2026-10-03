import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct AmbientAudioCaptureBoundTests {
    /// The capture backlog holds about one second of source audio whatever the tap's buffer size or rate.
    @Test(arguments: [(4_800, 48_000.0, 40), (480, 48_000.0, 400), (4_096, 44_100.0, 40)])
    func boundsCaptureByDurationForASlowConverter(frames: Int, sampleRate: Double, count: Int) async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let converter = SentAudio(holding: true)
        let streamer = AmbientAudioStreamer(
            capture: capture, maxBacklogChunks: 1_000, makeStreamID: { UUID() },
            beforeEncode: { await converter.send(encodeMarker) }, send: { await sent.send($0) }
        )
        try streamer.start()
        for block in 0..<count {
            try capture.yield(sineBuffer(
                frames: AVAudioFrameCount(frames), sampleRate: sampleRate, offset: block * frames
            ))
        }
        let bufferSeconds = Double(frames) / sampleRate
        let kept = Int((AmbientAudioFormat.maxPendingCaptureSeconds / bufferSeconds).rounded(.down))
        // One buffer is stalled in the converter; about one second waits; the rest is dropped oldest-first.
        try await waitUntil { await streamer.droppedCaptureBufferCount >= count - 1 - kept - 1 }
        await converter.release()
        await streamer.stop()

        #expect(await streamer.droppedChunkCount == 0)
        let payloads = await sent.payloads
        let seconds = Double(payloads.reduce(0) { $0 + $1.bytes.count }) / 2 / 16_000
        #expect(seconds <= AmbientAudioFormat.maxPendingCaptureSeconds + bufferSeconds + 0.02)
        #expect(seconds >= AmbientAudioFormat.maxPendingCaptureSeconds - bufferSeconds - 0.02)
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
    }
}
