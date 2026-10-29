import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectResumeFlagTests {
    @Test func transportResumeDuringBackoffDoesNotAuthorizeAnUnrelatedFailure() async throws {
        let capture = FakeAudioCapture()
        let backoff = SleepGate()
        let offered = SentAudio()
        var decisions = 0
        let streamer = AmbientAudioStreamer(capture: capture) { audio in
            await offered.send(audio)
            throw HostConnectionFailure.remote("not_allowed: ambient stopped: listener exited")
        }
        streamer.recovery = { _ in
            decisions += 1
            guard decisions == 1 else { return false }
            try? await backoff.sleep(.zero)
            return true
        }
        try streamer.start()
        for index in 0..<6 { try capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await backoff.isWaiting() }
        // Let the pump join the same held recovery decision before the transport supersedes it.
        for _ in 0..<6 { try capture.yield(sineBuffer()) }
        await settle()
        streamer.suspendTransport()
        streamer.resumeTransport()
        await backoff.fire()
        try await waitUntil {
            try await MainActor.run {
                for _ in 0..<6 { try capture.yield(sineBuffer()) }
                return !streamer.isStreaming
            }
        }
        let streams = Set(await offered.payloads.compactMap(\.streamID))
        #expect(streams.count == 2, "A consumed transport resume authorized an unrelated third stream")
        #expect(decisions == 2)
        await streamer.stop()
    }
}
