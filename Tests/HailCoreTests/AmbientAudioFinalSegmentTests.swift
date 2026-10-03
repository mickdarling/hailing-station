import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// 16 kHz mono PCM16 in, so conversion is exact and a stream can end precisely on a segment boundary.
private func wireFormatBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AmbientAudioFormat.outputFormat())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.int16ChannelData?[0])
    for index in 0..<Int(frames) { samples[index] = Int16(truncatingIfNeeded: index % 2_000 - 1_000) }
    return buffer
}

/// The host gate (#205) refuses empty or odd-length pcm16 segments, so `final: true` must ride on audio.
private func gateAccepts(_ payload: AudioPayload) -> Bool {
    !payload.bytes.isEmpty && payload.bytes.count <= AmbientAudioFormat.maxSegmentBytes
        && payload.bytes.count.isMultiple(of: 2)
}

@Suite struct AmbientAudioFinalSegmentTests {
    @Test func aStreamEndingOnASegmentBoundaryMarksItsLastAudioFinal() throws {
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        var payloads = try encoder.encode(wireFormatBuffer(frames: 3_200))
        #expect(payloads.count == 1)
        payloads += try encoder.finish()

        let total = payloads.reduce(0) { $0 + $1.bytes.count }
        try #require(total == 6_400, "conversion must be exact for the boundary case")
        #expect(payloads.count == 2)
        #expect(payloads.allSatisfy(gateAccepts))
        #expect(payloads.map(\.isFinal) == [false, true])
        #expect(payloads.map(\.sequence) == [0, 1])
    }

    @Test func aPartialTailIsTheFinalSegment() throws {
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        var payloads = try encoder.encode(wireFormatBuffer(frames: 2_000))
        payloads += try encoder.finish()
        #expect(payloads.allSatisfy(gateAccepts))
        #expect(payloads.map(\.bytes.count).reduce(0, +) == 4_000)
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.count { $0.isFinal } == 1)
    }

    @Test func abandoningAStreamFinalisesTheHeldAudioAndNeverSendsAnEmptySegment() throws {
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        let sent = try encoder.encode(wireFormatBuffer(frames: 3_200))
        let closing = encoder.abandon()
        #expect(sent.count == 1)
        #expect(closing.count == 1)
        #expect(closing.allSatisfy(gateAccepts))
        #expect(closing.first?.isFinal == true)
        #expect(closing.first?.sequence == 1)
    }

    @Test func aStreamWithoutAudioSendsNothing() throws {
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        #expect(try encoder.finish().isEmpty)
        var abandoned = try AmbientAudioEncoder(streamID: UUID())
        #expect(abandoned.abandon().isEmpty)
    }
}
