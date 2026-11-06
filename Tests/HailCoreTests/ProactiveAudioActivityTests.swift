import AVFAudio
import Foundation
import Testing
@testable import HailCore

@Suite struct ProactiveAudioActivityTests {
    private func buffer(_ value: Float = 0, frames: AVAudioFrameCount = 480) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = value }
        return buffer
    }

    @Test func onlyMeasuredContiguousQuietCanAdmitAndMissingBuffersExpireIt() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        #expect(!activity.isQuiet)
        let token = activity.beginCapture()
        clock.advance(by: .seconds(60))
        #expect(!activity.isQuiet)
        for _ in 0..<60 {
            activity.observe(try buffer(), capturedAt: clock.now(), capture: token)
            clock.advance(by: .milliseconds(10))
        }
        #expect(activity.isQuiet)
        clock.advance(by: ProactiveAudioActivity.freshness)
        #expect(!activity.isQuiet)
        activity.observe(try buffer(), capturedAt: clock.now(), capture: token)
        #expect(!activity.isQuiet)
    }

    @Test func soundInvalidatesImmediatelyAndQuietMustBeMeasuredAgain() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        for _ in 0..<60 {
            activity.observe(try buffer(), capturedAt: clock.now(), capture: token)
            clock.advance(by: .milliseconds(10))
        }
        #expect(activity.isQuiet)
        activity.observe(try buffer(0.1), capturedAt: clock.now(), capture: token)
        #expect(!activity.isQuiet)
        activity.observe(try buffer(), capturedAt: clock.now(), capture: token)
        #expect(!activity.isQuiet)
    }

    @Test func staleCaptureCannotContributeAndStoppingRevokesMeasuredQuiet() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let old = activity.beginCapture()
        let current = activity.beginCapture()
        for _ in 0..<60 {
            activity.observe(try buffer(), capturedAt: clock.now(), capture: old)
            clock.advance(by: .milliseconds(10))
        }
        #expect(!activity.isQuiet)
        activity.endCapture(old)
        for _ in 0..<60 {
            activity.observe(try buffer(), capturedAt: clock.now(), capture: current)
            clock.advance(by: .milliseconds(10))
        }
        #expect(activity.isQuiet)
        activity.endCapture(current)
        #expect(!activity.isQuiet)
    }

    @Test func duplicateOrBackloggedSamplesDoNotManufactureElapsedQuiet() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        for _ in 0..<100 { activity.observe(try buffer(), capturedAt: clock.now(), capture: token) }
        #expect(!activity.isQuiet)
    }

    @Test func oldOrFutureCaptureTimesCannotProveCurrentQuiet() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        let old = clock.now()
        clock.advance(by: .seconds(1))
        for _ in 0..<100 { activity.observe(try buffer(), capturedAt: old, capture: token) }
        #expect(!activity.isQuiet)
        activity.observe(try buffer(), capturedAt: clock.now().advanced(by: .seconds(1)), capture: token)
        #expect(!activity.isQuiet)
    }

    @Test func nonfiniteAndOversizedBuffersNeverProveQuiet() throws {
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        for value in [Float.nan, .infinity, 0] {
            activity.observe(try buffer(value, frames: 48_000), capturedAt: clock.now(), capture: token)
            clock.advance(by: .seconds(1))
            #expect(!activity.isQuiet)
        }
    }
}
