import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct PCM16AudioPlayerTests {
    @Test func convertsLittleEndianPCM16IntoTheExplicitPlayerFormat() throws {
        let buffer = try PCM16BufferConverter.buffer(payload(
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
        let buffer = try PCM16BufferConverter.buffer(payload(sampleRate: 48_000, bytes: bytes))

        #expect(buffer.format.sampleRate == 24_000)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength > 0)
        #expect(buffer.frameLength <= 481)
    }

    @Test func rejectsMalformedPayloads() {
        #expect(throws: ReplyAudioPlayerError.unsupportedFormat) {
            try PCM16BufferConverter.buffer(payload(bytes: Data()))
        }
        #expect(throws: ReplyAudioPlayerError.unsupportedFormat) {
            try PCM16BufferConverter.buffer(payload(bytes: Data([0])))
        }
    }

    @Test func aSingleChunkHasQuietLeadAndTailWithoutChangingSpeech() throws {
        let buffers = try PCM16PlaybackBuffers.forPayload(payload(bytes: Data([0x00, 0x20, 0x00, 0x40])))

        #expect(buffers.count == 3)
        #expect(try isBoundarySilence(buffers[0]))
        #expect(try isBoundarySilence(buffers[2]))
        let speech = try #require(buffers[1].floatChannelData?.pointee)
        #expect(buffers[1].frameLength == 2)
        #expect(speech[0] == 0.25)
        #expect(speech[1] == 0.5)
    }

    @Test func streamedChunksArePaddedOnlyAtUtteranceBoundaries() throws {
        let bytes = Data([0x00, 0x20])
        let first = try PCM16PlaybackBuffers.forPayload(payload(sequence: 0, isFinal: false, bytes: bytes))
        let middle = try PCM16PlaybackBuffers.forPayload(payload(sequence: 1, isFinal: false, bytes: bytes))
        let last = try PCM16PlaybackBuffers.forPayload(payload(sequence: 2, isFinal: true, bytes: bytes))

        #expect(first.count == 2)
        #expect(try isBoundarySilence(first[0]))
        #expect(middle.count == 1)
        #expect(last.count == 2)
        #expect(try isBoundarySilence(last[1]))
        #expect(first[1].frameLength == 1 && middle[0].frameLength == 1 && last[0].frameLength == 1)
    }

    private func isBoundarySilence(_ buffer: AVAudioPCMBuffer) throws -> Bool {
        guard buffer.frameLength == PCM16PlaybackBuffers.boundaryFrames,
              buffer.format.sampleRate == 24_000 else { return false }
        let samples = try #require(buffer.floatChannelData?.pointee)
        return UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).allSatisfy { $0 == 0 }
    }
}

private func payload(
    sampleRate: Int = 24_000, sequence: Int = 0, isFinal: Bool = true, bytes: Data
) -> AudioPayload {
    AudioPayload(
        codec: .pcm16, sampleRate: sampleRate, channels: 1, sequence: sequence,
        streamID: UUID(), isFinal: isFinal, bytes: bytes
    )
}
