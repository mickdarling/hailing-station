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

    /// An over-rate final segment is dropped but still ends the stream (#331 review): otherwise the child's input
    /// stays open and other connections are refused "ambient busy" until the idle expiry.
    @Test func anOverRateFinalSegmentStillEndsTheStream() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let segment = AmbientAudioGate.maxSegmentBytes
        let burstSegments = AmbientAudioGate.burstBytes / segment
        for sequence in 0..<burstSegments {
            _ = await gate.admit(ambientSegment(stream: stream, sequence: sequence, bytes: segment), connection: phone)
        }
        #expect(await gate.admit(
            ambientSegment(stream: stream, sequence: burstSegments, bytes: segment, isFinal: true), connection: phone
        ) == nil)
        #expect(sink.endings == [.final])
        #expect(await gate.activeStream == nil)
    }

    /// Four times the rate (160 KiB/s against a 40 KiB/s refill) drains the 400 KiB burst in about 3.3 s, then drops
    /// for the 5 s grace: the end comes at about 8.3 s, so the grace is measured. A quiet second resets an episode.
    @Test func theGraceRunsFromTheEpisodeStartAndAQuietSecondResetsIt() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let segment = AmbientAudioGate.maxSegmentBytes
        var sequence = 0, elapsed = Duration.zero, refused: ErrorCode?
        while refused == nil, elapsed < .seconds(30) {
            clock.advance(.milliseconds(100))
            elapsed += .milliseconds(100)
            for _ in 0..<2 where refused == nil {
                refused = await gate.admit(ambientSegment(stream: stream, sequence: sequence, bytes: segment),
                                           connection: phone)
                sequence += 1
            }
        }
        #expect(refused == .rateLimited)
        #expect(elapsed > .seconds(8) && elapsed < .milliseconds(8_700))

        // A fresh stream after refill: drops 1.2 s apart never join one episode, so 12 s of them never end it.
        let next = UUID()
        clock.advance(.seconds(20))
        var seq = 0
        for _ in 0..<AmbientAudioGate.burstBytes / segment + 1 {
            _ = await gate.admit(ambientSegment(stream: next, sequence: seq, bytes: segment), connection: phone)
            seq += 1
        }
        for _ in 0..<10 {
            clock.advance(.milliseconds(1_200))
            for _ in 0..<8 {
                #expect(await gate.admit(ambientSegment(stream: next, sequence: seq, bytes: segment),
                                         connection: phone) == nil)
                seq += 1
            }
        }
        #expect(sink.endings == [.rateLimited])
        #expect(await gate.activeStream == next)
    }
}
