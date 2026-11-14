import Foundation
import HailDaemonKit
import HailProtocol
import Testing
@testable import haild

struct QueuedAudioEncodingTests {
    private let ticket = LocalReplyAudioTicket(epoch: UUID(), position: UInt64.max, releaseKey: UUID())

    private func frame(_ bytes: Data, sequence: Int = 2, wide: Bool = false) -> Frame {
        let host = wide ? String(repeating: "\u{0001}", count: 256) : "mac-test"
        let target = wide ? String(repeating: "\u{0002}", count: 256) : "tmux:test"
        let stream = UUID()
        let reply = ReplyDescriptor(id: UUID(), hostID: host, targetID: target, audioStreamID: stream,
                                    requestID: UUID())
        return Frame(timestamp: Int64.max, target: target, source: host, payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence, streamID: stream,
            isFinal: false, bytes: bytes, reply: reply, isSegmentEnd: true)))
    }

    @Test func slashHeavyAndNearCapMixAreAcceptedWhilePlainEncoderExceedsCap() throws {
        // Quiet PCM (-1 samples) followed by deterministic varied samples: no captured speech.
        let mixed = Data(repeating: 255, count: 10_000) + Data((0..<50_000).map { UInt8($0 % 251) })
        for bytes in [Data(repeating: 255, count: 60_000), mixed] {
            let frame = self.frame(bytes)
            let request = LocalReplyAudioRequest(action: "publish", ticket: ticket, frame: frame)
            let old = try JSONEncoder().encode(request)
            #expect(old.count > PayloadLimits.defaultMaxFrameBytes)
            let encoded = try QueuedAudioEncoding.encode(frame, ticket: ticket)
            #expect(encoded.count <= PayloadLimits.defaultMaxFrameBytes)
            let accepted = try JSONDecoder().decode(LocalReplyAudioRequest.self, from: encoded)
            #expect(accepted.frame == frame)
            #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
        }
    }

    @Test func capacityFitsWorstEnvelopeAndContentAcrossRampedAndRandomSizes() throws {
        var random: UInt64 = 1241
        for queued in [false, true] {
            for wide in [false, true] {
                let ticket = queued ? self.ticket : nil
                let probe = frame(Data(), wide: wide)
                let capacity = try QueuedAudioEncoding.pcmCapacity(frame: probe, ticket: ticket)
                #expect(capacity > 0 && capacity.isMultiple(of: 2))
                #expect(capacity <= PayloadLimits.maxAudioBytes)
                for sequence in [0, 1, 2, Int.max] {
                    let size = StreamedReplyFrames.bytes(sequence: sequence, maximum: capacity)
                    #expect(size <= capacity)
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    let randomSize = 2 * (1 + Int(random % UInt64(capacity / 2)))
                    for count in [size, capacity, randomSize] {
                        let varied = Data((0..<count).map { _ in
                            random = random &* 6_364_136_223_846_793_005 &+ 1
                            return UInt8(truncatingIfNeeded: random >> 32)
                        })
                        for bytes in [Data(repeating: 255, count: count), varied] {
                            let frame = self.frame(bytes, sequence: sequence, wide: wide)
                            let encoded = try QueuedAudioEncoding.encode(frame, ticket: ticket)
                            #expect(encoded.count <= PayloadLimits.defaultMaxFrameBytes)
                            #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
                        }
                    }
                }
            }
        }
    }
}
