import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// Synthetic constant-amplitude PCM has exactly the requested RMS dBFS; never uses a microphone.
func onsetPCM(_ dbfs: Double, seconds: Double = 0.1, rate: Double = 48_000) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let frames = AVAudioFrameCount((seconds * rate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    samples.initialize(repeating: Float(pow(10, dbfs / 20)), count: Int(frames))
    return buffer
}

final class OnsetFixture {
    let clock = EchoGuardClock()
    let guarder: AmbientReplyEchoGuard
    var window: Range<ContinuousClock.Instant>?
    var ambient = true
    var privacy = false
    var settings = ReplySegmentSettings()
    var gate: ReplySegmentOnsetGate { guarder.segmentOnsetGate }
    var input: ReplySegmentOnsetInput {
        .init(window: window, ambientListening: ambient, privacyOn: privacy, settings: settings)
    }

    init(tail: Duration = AmbientReplyEchoGuard.defaultTail, length: Double = 1.5) {
        let clock = clock
        guarder = AmbientReplyEchoGuard(tail: tail, now: { clock.now })
        open(length: length)
    }

    func open(length: Double = 1.5) {
        window = clock.now..<clock.now.advanced(by: .seconds(length))
    }

    @discardableResult
    func feed(_ dbfs: Double, seconds: Double = 0.1) throws -> Bool {
        let buffer = try onsetPCM(dbfs, seconds: seconds)
        clock.advance(by: .seconds(seconds))
        return gate.analyse(buffer, input: input)
    }

    func calibrate(floor: Double = -50) throws {
        #expect(try !feed(0, seconds: 0.4)) // Echo tail must never enter the floor.
        #expect(try !feed(floor, seconds: 0.2))
    }
}
