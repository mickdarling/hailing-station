import AVFAudio
import Foundation
import HailCore
import Testing
@testable import HailCoaching

// Match verify.sh's existing CoachingTransportRegression serial lane: this uses a real child and wall-clock lease.
@Suite(.serialized) @MainActor struct CoachingTransportRegressionReentryTests {
    @Test func activityCallbackWritingNewVoiceCannotForwardPreviouslyEligibleAdvice() async throws {
        let tail = CoachingTransportRig.final + "\n" + """
        printf '{"schema_version":1,"type":"coaching_advice"}\\n'
        """
        let rig = try CoachingTransportRig(tail: tail)
        rig.duringFlags = {
            guard rig.flagsCalls == 2 else { return }
            rig.duringFlags = nil
            do {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
                buffer.frameLength = 1_600
                let samples = try #require(buffer.floatChannelData)
                for index in 0..<1_600 { samples[0][index] = 0.2 }
                #expect(rig.transport?.write(try #require(AudioCaptureBuffer(copying: buffer))) == true)
            } catch { Issue.record(error) }
        }
        try await rig.run()
        #expect(rig.contextRevocations == 3 && rig.transport?.adviceCount == 1)
        #expect(rig.driver.status == .active && rig.capture.stops == 0 && rig.player.played == 0)
        try await rig.join()
    }
}
