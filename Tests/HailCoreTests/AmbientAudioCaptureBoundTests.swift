import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct AmbientAudioCaptureBoundTests {
    @Test func boundsCaptureBuffersWaitingForASlowConverter() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let converter = SentAudio(holding: true)
        let streamer = AmbientAudioStreamer(
            capture: capture, maxBacklogChunks: AmbientAudioFormat.maxBacklogChunks, makeStreamID: { UUID() },
            beforeEncode: { await converter.send(encodeMarker) }, send: { await sent.send($0) }
        )
        try streamer.start()
        for block in 0..<40 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        // One buffer is held in the stalled converter, twelve wait, the other 27 are dropped oldest-first.
        try await waitUntil { await streamer.droppedCaptureBufferCount >= 27 }
        await converter.release()
        await streamer.stop()

        #expect(await streamer.droppedChunkCount == 0)
        let payloads = await sent.payloads
        let waiting = 1 + AmbientAudioFormat.maxPendingCaptureBuffers
        #expect(payloads.count <= waiting * 3 + 2)
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
    }
}
