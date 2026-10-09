import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #366 at the gate: the most recent device to start ambient listening takes it over. Synthetic only.
@Suite struct AmbientTakeOverGateTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()
    let phone = UUID()
    let pad = UUID()

    private func admission(
        _ gate: AmbientAudioGate, _ stream: UUID, _ sequence: Int, from connection: UUID, device: String?,
        selected: String? = "tmux:a", isFinal: Bool = false
    ) async -> AmbientAdmission {
        await gate.admission(
            ambientSegment(stream: stream, sequence: sequence, isFinal: isFinal), frameTarget: "tmux:a",
            selectedTarget: selected, connection: connection, device: device
        )
    }

    private var starts: [UUID] {
        sink.events.compactMap { if case .started(_, let connection) = $0 { connection } else { nil } }
    }

    @Test func aNewStreamFromAnotherDeviceEndsTheFirstAsSupersededAndStartsTheSecond() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let first = UUID(), second = UUID()
        #expect(await admission(gate, first, 0, from: phone, device: "phone") == .admitted)
        #expect(await admission(gate, second, 0, from: pad, device: "pad") == .tookOver(from: "phone"))
        #expect(sink.endings == [.superseded])
        #expect(starts == [phone, pad])
        #expect(await gate.activeStream == second)
        // The new owner continues normally; the previous owner is told where listening went, every time, and its
        // refusals never disturb the new stream.
        #expect(await admission(gate, second, 1, from: pad, device: "pad") == .admitted)
        for sequence in 1...3 {
            #expect(await admission(gate, first, sequence, from: phone, device: "phone")
                == .refused(.notAllowed, "ambient moved to pad"))
        }
        #expect(await gate.activeStream == second)
        #expect(sink.endings == [.superseded])
    }

    @Test func aDeviceThatGaveNoClassIsNamedAsAnotherDevice() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let first = UUID()
        #expect(await admission(gate, first, 0, from: phone, device: nil) == .admitted)
        #expect(await admission(gate, UUID(), 0, from: pad, device: "Mick's iPad") == .tookOver(from: nil))
        #expect(await admission(gate, first, 1, from: phone, device: nil)
            == .refused(.notAllowed, "ambient moved to another device"))
    }

    @Test func noTakeOverWithoutASelectedTargetAValidStartOrRateBudget() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let owned = UUID()
        #expect(await admission(gate, owned, 0, from: phone, device: "phone") == .admitted)
        // Not selected, the wrong target, a malformed shape, a continuation, a reused id: all refused, none ends A.
        #expect(await admission(gate, UUID(), 0, from: pad, device: "pad", selected: nil)
            == .refused(.notAllowed, "ambient target is not selected"))
        #expect(await admission(gate, UUID(), 0, from: pad, device: "pad", selected: "tmux:b")
            == .refused(.notAllowed, "ambient target is not selected"))
        #expect(await gate.admission(
            ambientSegment(stream: UUID(), sequence: 0, codec: .opus), frameTarget: "tmux:a",
            selectedTarget: "tmux:a", connection: pad, device: "pad"
        ) == .refused(.malformed, "ambient segment shape"))
        #expect(await admission(gate, UUID(), 4, from: pad, device: "pad")
            == .refused(.malformed, "ambient stream must be new and start at sequence 0"))
        // Another device can neither continue nor restart the owner's own stream id.
        #expect(await admission(gate, owned, 0, from: pad, device: "pad")
            == .refused(.notAllowed, "ambient stream is not this device's"))
        #expect(await admission(gate, owned, 9, from: pad, device: "pad")
            == .refused(.notAllowed, "ambient stream is not this device's"))
        #expect(await gate.activeStream == owned)
        #expect(sink.endings.isEmpty)
        #expect(starts == [phone])
        #expect(await admission(gate, owned, 1, from: phone, device: "phone") == .admitted)
    }

    @Test func aRateLimitedTakeOverLeavesTheOwnerStreaming() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let owned = UUID()
        let segment = AmbientAudioGate.maxSegmentBytes
        #expect(await gate.admit(ambientSegment(stream: owned, sequence: 0, bytes: segment), connection: phone) == nil)
        for sequence in 1..<(AmbientAudioGate.burstBytes / segment) {
            _ = await gate.admit(ambientSegment(stream: owned, sequence: sequence, bytes: segment), connection: phone)
        }
        #expect(await gate.admission(
            ambientSegment(stream: UUID(), sequence: 0, bytes: segment), frameTarget: "tmux:a",
            selectedTarget: "tmux:a", connection: pad, device: "pad"
        ) == .refused(.rateLimited, "ambient rate exceeded"))
        #expect(await gate.activeStream == owned)
        #expect(sink.endings.isEmpty)
    }

    @Test func repeatedPingPongAlwaysLeavesTheLatestStartInControl() async {
        let gate = ambientGate(sink: sink, clock: clock)
        var previous: (stream: UUID, connection: UUID)?
        for round in 0..<40 {
            clock.advance(.seconds(1))
            let (connection, device) = round.isMultiple(of: 2) ? (phone, "phone") : (pad, "pad")
            let stream = UUID()
            let expected: AmbientAdmission = round == 0 ? .admitted : .tookOver(from: device == "pad" ? "phone" : "pad")
            #expect(await admission(gate, stream, 0, from: connection, device: device) == expected)
            if let previous {
                #expect(await admission(gate, previous.stream, 1, from: previous.connection, device: nil)
                    == .refused(.notAllowed, "ambient moved to \(device)"))
            }
            #expect(await gate.activeStream == stream)
            previous = (stream, connection)
        }
        #expect(sink.endings == Array(repeating: .superseded, count: 39))
        #expect(starts.count == 40)
    }

    @Test func rememberedMovesAreBoundedAndAForgottenOneStillCannotReopenItsStream() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let first = UUID()
        #expect(await admission(gate, first, 0, from: phone, device: "phone") == .admitted)
        for _ in 0...AmbientAudioGate.movedStreamCapacity {
            clock.advance(.seconds(1))
            _ = await admission(gate, UUID(), 0, from: UUID(), device: "pad")
        }
        #expect(await admission(gate, first, 1, from: phone, device: "phone")
            == .refused(.malformed, "ambient stream must be new and start at sequence 0"))
    }

    @Test func theOwnerRestartingItsOwnStreamIsNotATakeOver() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let first = UUID()
        #expect(await admission(gate, first, 0, from: phone, device: "phone") == .admitted)
        #expect(await admission(gate, UUID(), 0, from: phone, device: "phone") == .admitted)
        #expect(sink.endings == [.superseded])
        // A superseded stream of the same device is not a move: it is refused as an ended id, as before #366.
        #expect(await admission(gate, first, 1, from: phone, device: "phone")
            == .refused(.malformed, "ambient stream must be new and start at sequence 0"))
    }

    @Test func aGoneDeviceIsForgottenAndAnIdleStreamIsNotTakenOver() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let first = UUID()
        #expect(await admission(gate, first, 0, from: phone, device: "phone") == .admitted)
        #expect(await admission(gate, UUID(), 0, from: pad, device: "pad") == .tookOver(from: "phone"))
        await gate.end(connection: phone)
        #expect(await admission(gate, first, 1, from: phone, device: "phone")
            == .refused(.malformed, "ambient stream must be new and start at sequence 0"))
        // Once the pad's stream idles out, the next start owns a free gate: nothing is taken over.
        clock.advance(AmbientAudioGate.idleTimeout)
        #expect(await admission(gate, UUID(), 0, from: phone, device: "phone") == .admitted)
        #expect(sink.endings == [.superseded, .idle])
    }
}
