import AVFAudio
import Testing
@testable import HailCore

@Suite struct ProactiveCaptureContinuityTests {
    @Test func sparseSilentBuffersCannotProveAContiguousPause() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = 0 }
        for _ in 0..<100 {
            activity.observe(buffer, capturedAt: clock.now(), capture: token)
            clock.advance(by: .milliseconds(149))
        }
        #expect(!activity.isQuiet)
    }
}
