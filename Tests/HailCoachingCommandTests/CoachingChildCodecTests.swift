import AVFAudio
import Foundation
import HailCore
import Testing
@testable import haild

@Suite @MainActor struct CoachingChildCodecTests {
    @Test func measuredPauseRequiresFreshActualPCMAndIndependentOwnerPlaybackFlags() throws {
        let meter = CoachingCaptureActivity(), now = ContinuousClock.now
        let idle = CoachingActivityFlags(ownerMidAnswer: false, playback: false)
        #expect(meter.measure(idle, at: now) == nil)
        meter.observe(Data([0x70, 0x17]), at: now)
        meter.observe(Data([0, 0]), at: now.advanced(by: .milliseconds(500)))
        let observed = try #require(meter.measure(idle, at: now.advanced(by: .milliseconds(600))))
        #expect(observed.pauseMilliseconds == 600 && !observed.ownerMidAnswer && !observed.playback)
        let busy = CoachingActivityFlags(ownerMidAnswer: true, playback: true)
        #expect(meter.measure(busy, at: now.advanced(by: .milliseconds(600)))?.ownerMidAnswer == true)
        #expect(meter.measure(idle, at: now.advanced(by: .milliseconds(750))) == nil)
        #expect(meter.measure(idle, at: now.advanced(by: .milliseconds(-1))) == nil)
    }

    @Test func originalControlDeadlineNeverRoundsUpOrExtends() {
        let now = ContinuousClock.now
        #expect(CoachingChildCodec.milliseconds(until: now, at: now) == 0)
        #expect(CoachingChildCodec.milliseconds(until: now.advanced(by: .microseconds(999)), at: now) == 0)
        #expect(CoachingChildCodec.milliseconds(until: now.advanced(by: .milliseconds(1_999)), at: now) == 1_999)
        #expect(CoachingChildCodec.milliseconds(until: now.advanced(by: .seconds(3)), at: now) == 2_000)
    }

    @Test func purePCMConversionProducesNonzeroMono16kWithoutAnyEngine() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<1_600 { samples[0][index] = 0.2 }
        let snapshot = try #require(AudioCaptureBuffer(copying: buffer))
        let data = try CoachingPCMEncoder().encode(snapshot)
        #expect(!data.isEmpty && data.count.isMultiple(of: 2) && data.contains { $0 != 0 })
    }

    @Test func emptyAndOversizedPCMFailClosed() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        let encoder = CoachingPCMEncoder()
        #expect(throws: CoachingChildError.invalidPCM) {
            try encoder.encode(#require(AudioCaptureBuffer(copying: buffer)))
        }
        buffer.frameLength = 8_000
        #expect(throws: CoachingChildError.invalidPCM) {
            try encoder.encode(#require(AudioCaptureBuffer(copying: buffer)))
        }
    }

    @Test func nonfiniteCapturedSamplesFailBeforeConversion() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try #require(buffer.floatChannelData)
        for channel in 0..<2 { for frame in 0..<4_800 { samples[channel][frame] = 0.2 } }
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            samples[1][100] = invalid
            #expect(throws: CoachingChildError.invalidPCM) {
                try CoachingPCMEncoder().encode(#require(AudioCaptureBuffer(copying: buffer)))
            }
        }
    }
}
