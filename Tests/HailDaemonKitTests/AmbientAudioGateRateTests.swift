import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The ambient rate (#330): a network stall's catch-up passes, a brief excess is dropped without ending the
/// stream, and only a sender that keeps exceeding the rate is ended.
@Suite struct AmbientAudioGateRateTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()
    let phone = UUID()
    let stream = UUID()

    @Test func overTheBurstASegmentIsDroppedSilentlyAndTheStreamGoesOn() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let segment = AmbientAudioGate.maxSegmentBytes
        let burstSegments = AmbientAudioGate.burstBytes / segment
        for sequence in 0..<burstSegments {
            #expect(await gate.admit(
                ambientSegment(stream: stream, sequence: sequence, bytes: segment), connection: phone
            ) == nil)
        }
        let forwarded = sink.events.count
        // Over the rate (#330): no reply, which the phone would take as a stop, and nothing forwarded.
        #expect(await gate.admit(
            ambientSegment(stream: stream, sequence: burstSegments, bytes: segment), connection: phone
        ) == nil)
        #expect(sink.events.count == forwarded)
        #expect(sink.endings.isEmpty)
        #expect(await gate.overRateDropped == 1)
        // Back under the rate, the stream carries on.
        clock.advance(.seconds(1))
        #expect(await gate.admit(
            ambientSegment(stream: stream, sequence: burstSegments + 1, bytes: segment), connection: phone
        ) == nil)
        #expect(sink.events.count == forwarded + 1)
        #expect(await gate.activeStream == stream)
    }

    @Test func aStreamThatStaysOverTheRateEndsAfterTheGrace() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let segment = AmbientAudioGate.maxSegmentBytes
        var sequence = 0
        // Twice the rate: two 8 KiB segments every 100 ms against a 4 KiB refill.
        var refused: ErrorCode?
        for _ in 0..<200 where refused == nil {
            clock.advance(.milliseconds(100))
            for _ in 0..<2 where refused == nil {
                refused = await gate.admit(ambientSegment(stream: stream, sequence: sequence, bytes: segment),
                                           connection: phone)
                sequence += 1
            }
        }
        #expect(refused == .rateLimited)
        #expect(sink.endings == [.rateLimited])
        // The bucket is daemon-wide: a fresh stream cannot reset it, but refill restores it.
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0, bytes: segment), connection: phone)
            == .rateLimited)
        clock.advance(.seconds(1))
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0, bytes: segment), connection: phone)
            == nil)
    }

    /// The live failure (#330): the network stalls, then several seconds of queued 100 ms segments land at once.
    @Test func aNetworkStallThatDeliversQueuedAudioAtOnceKeepsTheStream() async {
        let gate = ambientGate(sink: sink, clock: clock)
        var sequence = 0
        for _ in 0..<100 {
            clock.advance(.milliseconds(100))
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence), connection: phone) == nil)
            sequence += 1
        }
        clock.advance(.seconds(6))
        for _ in 0..<60 {
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence), connection: phone) == nil)
            sequence += 1
        }
        #expect(sink.endings.isEmpty)
        #expect(await gate.overRateDropped == 0)
    }
}
