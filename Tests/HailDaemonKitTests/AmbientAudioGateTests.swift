import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct AmbientAudioGateTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()
    let phone = UUID()
    let stream = UUID()

    @Test func admitsAStreamWithGapsAndEndsOnFinal() async {
        let gate = ambientGate(sink: sink, clock: clock)
        for sequence in [0, 1, 3, 7] {
            clock.advance(.milliseconds(100))
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence), connection: phone) == nil)
        }
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 8, isFinal: true), connection: phone) == nil)
        #expect(sink.events.first == .started(stream: stream, connection: phone))
        #expect(sink.segments == [0, 1, 3, 7, 8])
        #expect(sink.endings == [.final])
        #expect(await gate.activeStream == nil)
        // An ended stream id cannot be reopened.
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == .malformed)
    }

    @Test func refusesEveryShapeViolationAndEndsTheStream() async {
        let bad: [AudioPayload] = [
            ambientSegment(stream: stream, sequence: 1, codec: .opus),
            ambientSegment(stream: stream, sequence: 1, sampleRate: 48_000),
            ambientSegment(stream: stream, sequence: 1, channels: 2),
            ambientSegment(stream: nil, sequence: 1),
            ambientSegment(stream: stream, sequence: 1, bytes: AmbientAudioGate.maxSegmentBytes + 1),
            ambientSegment(stream: stream, sequence: 1, bytes: 0),
            ambientSegment(stream: stream, sequence: 1, bytes: 3_201),
            AudioPayload(
                codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: 1, streamID: stream, isFinal: false,
                bytes: Data(count: 2),
                reply: ReplyDescriptor(id: UUID(), hostID: "h", targetID: "tmux:a", audioStreamID: stream)
            )
        ]
        for payload in bad {
            let sink = RecordingAmbientSink()
            let gate = ambientGate(sink: sink, clock: clock)
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
            #expect(await gate.admit(payload, connection: phone) == .malformed)
            #expect(sink.endings == [.malformed])
            #expect(sink.segments == [0])
        }
    }

    @Test func sequenceMustStartAtZeroAndStrictlyIncrease() async {
        let gate = ambientGate(sink: sink, clock: clock)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 1), connection: phone) == .malformed)
        #expect(sink.events.isEmpty)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == .malformed)
        #expect(sink.endings == [.malformed])
    }

    @Test func targetMustBeTheAmbientTargetAndTheSelection() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let segment = ambientSegment(stream: stream, sequence: 0)
        #expect(await gate.admit(segment, connection: phone, target: "tmux:b") == .notAllowed)
        #expect(await gate.admit(
            segment, frameTarget: "tmux:a", selectedTarget: nil, connection: phone
        )?.0 == .notAllowed)
        #expect(await gate.admit(
            segment, frameTarget: nil, selectedTarget: "tmux:a", connection: phone
        )?.0 == .notAllowed)
        #expect(sink.events.isEmpty)
    }

    /// #366 replaced the "ambient busy" refusal: the second connection's valid start takes over, and the first
    /// connection's leftovers (more segments, its disconnect) cannot disturb the new owner.
    @Test func secondConnectionTakesOverAndTheFirstCannotDisturbIt() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let other = UUID(), next = UUID()
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
        #expect(await gate.admit(ambientSegment(stream: next, sequence: 0), connection: other) == nil)
        #expect(sink.endings == [.superseded])
        let refusal = await gate.admit(
            ambientSegment(stream: stream, sequence: 1), frameTarget: "tmux:a", selectedTarget: "tmux:a",
            connection: phone
        )
        #expect(refusal?.0 == .notAllowed)
        #expect(refusal?.1 == "ambient moved to another device")
        await gate.end(connection: phone)
        #expect(await gate.activeStream == next)
        #expect(await gate.admit(ambientSegment(stream: next, sequence: 1), connection: other) == nil)
        await gate.end(connection: other)
        #expect(sink.endings == [.superseded, .peerEnded])
    }

    @Test func idleStreamEndsAfterTheIdleTimeoutAndFreesTheDaemon() async {
        // 30 s since #282: a backgrounded phone paused sends for over 5 s and lost its stream.
        #expect(AmbientAudioGate.idleTimeout == .seconds(30))
        let gate = ambientGate(sink: sink, clock: clock)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
        clock.advance(AmbientAudioGate.idleTimeout - .milliseconds(100))
        await gate.expireIdle()
        #expect(await gate.activeStream == stream)
        clock.advance(.milliseconds(100))
        await gate.expireIdle()
        #expect(sink.endings == [.idle])
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 0), connection: UUID()) == nil)
    }

    @Test func steadyHundredMillisecondSegmentsStayUnderTheRate() async {
        let gate = ambientGate(sink: sink, clock: clock)
        for sequence in 0..<600 {
            clock.advance(.milliseconds(100))
            #expect(await gate.admit(ambientSegment(stream: stream, sequence: sequence), connection: phone) == nil)
        }
        #expect(sink.endings.isEmpty)
    }

    @Test func aNewStreamFromTheOwnerSupersedesTheOld() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let next = UUID()
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: phone) == nil)
        #expect(await gate.admit(ambientSegment(stream: next, sequence: 0), connection: phone) == nil)
        #expect(sink.endings == [.superseded])
        #expect(await gate.activeStream == next)
    }
}
