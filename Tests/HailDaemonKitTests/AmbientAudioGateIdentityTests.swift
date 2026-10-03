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

    @Test func reachingTheEndedIdBoundRefusesNewStreamsRatherThanForgetting() async {
        let gate = ambientGate(sink: sink, clock: clock, endedStreamCapacity: 2)
        let first = UUID()
        for id in [first, UUID()] {
            #expect(await gate.admit(ambientSegment(stream: id, sequence: 0, isFinal: true), connection: phone)
                == nil)
        }
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0), connection: phone) == .notAllowed)
        #expect(await gate.admit(ambientSegment(stream: first, sequence: 0), connection: phone) == .malformed)
        #expect(await gate.activeStream == nil)
        #expect(sink.endings.count == 2)
    }
}
