import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Codex review of #205: empty/unaligned segments and reuse of any ended stream id.
@Suite struct AmbientAudioGateIdentityTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()
    let phone = UUID()
    let stream = UUID()

    @Test func emptyOrUnalignedSegmentsNeverStartAStream() async {
        let gate = ambientGate(sink: sink, clock: clock)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0, bytes: 0), connection: phone)
            == .malformed)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0, bytes: 1), connection: phone)
            == .malformed)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0, bytes: 2), connection: phone) == nil)
        #expect(sink.segments == [0])
    }

    @Test func noPreviouslyEndedStreamIdCanBeReopened() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let streams = [UUID(), UUID(), UUID()]
        for id in streams {
            #expect(await gate.admit(ambientSegment(stream: id, sequence: 0, isFinal: true), connection: phone)
                == nil)
        }
        for id in streams {
            #expect(await gate.admit(ambientSegment(stream: id, sequence: 0), connection: phone) == .malformed)
        }
        #expect(await gate.admit(ambientSegment(stream: streams[0], sequence: 0), connection: UUID()) == .malformed)
        #expect(sink.endings == [.final, .final, .final])
    }

    @Test func atTheBoundTheOldestEndedIdIsEvictedAndAmbientStaysUsable() async {
        let gate = ambientGate(sink: sink, clock: clock, endedStreamCapacity: 2)
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            #expect(await gate.admit(ambientSegment(stream: id, sequence: 0, isFinal: true), connection: phone)
                == nil)
        }
        // New streams keep working past the bound, from any device.
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0, isFinal: true), connection: UUID())
            == nil)
        // The most recently ended ids are still refused; only the oldest was forgotten.
        #expect(await gate.admit(ambientSegment(stream: ids[2], sequence: 0), connection: phone) == .malformed)
        #expect(await gate.admit(ambientSegment(stream: ids[0], sequence: 0, isFinal: true), connection: phone)
            == nil)
    }

    @Test func refusedStartsAnnounceNothingAndConsumeNoIds() async {
        let gate = ambientGate(sink: sink, clock: clock, endedStreamCapacity: 2)
        let recent = UUID()
        #expect(await gate.admit(ambientSegment(stream: recent, sequence: 0, isFinal: true), connection: phone)
            == nil)
        clock.advance(.seconds(2))
        let size = AmbientAudioGate.maxSegmentBytes
        for sequence in 0..<(AmbientAudioGate.burstBytes / size) {
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence, bytes: size), connection: phone)
                == nil)
        }
        await gate.end(connection: phone)
        let before = sink.events.count
        for _ in 0..<50 {
            #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0, bytes: size), connection: UUID())
                == .rateLimited)
        }
        #expect(sink.events.count == before)
        clock.advance(.seconds(60))
        // The refused starts burned no slots: `recent` is still remembered at capacity 2.
        #expect(await gate.admit(ambientSegment(stream: recent, sequence: 0), connection: UUID()) == .malformed)
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0), connection: UUID()) == nil)
    }

    @Test func aRefusedReplacementLeavesTheCurrentStreamUntouched() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let old = UUID()
        #expect(await gate.admit(ambientSegment(stream: old, sequence: 0, isFinal: true), connection: phone) == nil)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
        let before = sink.events
        // A late segment from the ended stream, a fresh id not at sequence 0, and a retried start all refuse.
        #expect(await gate.admit(ambientSegment(stream: old, sequence: 0), connection: phone) == .malformed)
        #expect(await gate.admit(ambientSegment(stream: old, sequence: 5), connection: phone) == .malformed)
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 3), connection: phone) == .malformed)
        #expect(sink.events == before)
        #expect(await gate.activeStream == stream)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 1), connection: phone) == nil)
        #expect(sink.endings == [.final])
    }

    @Test func aRateLimitedReplacementLeavesTheCurrentStreamUntouched() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let size = AmbientAudioGate.maxSegmentBytes
        for sequence in 0..<(AmbientAudioGate.burstBytes / size) {
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence, bytes: size), connection: phone)
                == nil)
        }
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0, bytes: size), connection: phone)
            == .rateLimited)
        #expect(await gate.activeStream == stream)
        #expect(sink.endings.isEmpty)
    }
}
