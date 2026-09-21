import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct PCM16AudioPlayerTests {
    @Test func convertsLittleEndianPCM16IntoTheExplicitPlayerFormat() throws {
        let buffer = try PCM16AudioPlayer().buffer(payload(
            bytes: Data([0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0xff, 0x7f])
        ))
        let samples = try #require(buffer.floatChannelData?.pointee)

        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 4)
        #expect(samples[0] == -1)
        #expect(abs(samples[1] - (-1.0 / 32_768.0)) < 0.000_001)
        #expect(samples[2] == 0)
        #expect(abs(samples[3] - (32_767.0 / 32_768.0)) < 0.000_001)
    }

    @Test func resamplesAcceptedPCMRateIntoTheExplicitPlayerFormat() throws {
        let sourceFrames = 960
        let bytes = Data((0..<sourceFrames).flatMap { frame -> [UInt8] in
            let sample = Int16(frame.isMultiple(of: 2) ? 8_192 : -8_192)
            return [UInt8(truncatingIfNeeded: sample), UInt8(truncatingIfNeeded: sample >> 8)]
        })
        let buffer = try PCM16AudioPlayer().buffer(payload(sampleRate: 48_000, bytes: bytes))

        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength > 0)
        #expect(buffer.frameLength <= 481)
    }

    @Test func rejectsMalformedPayloads() {
        #expect(throws: ReplyAudioPlayerError.unsupportedFormat) {
            try PCM16AudioPlayer().buffer(payload(bytes: Data()))
        }
        #expect(throws: ReplyAudioPlayerError.unsupportedFormat) {
            try PCM16AudioPlayer().buffer(payload(bytes: Data([0])))
        }
    }
}

private func payload(sampleRate: Int = 24_000, bytes: Data) -> AudioPayload {
    AudioPayload(
        codec: .pcm16, sampleRate: sampleRate, channels: 1, sequence: 0,
        streamID: UUID(), isFinal: true, bytes: bytes
    )
}
