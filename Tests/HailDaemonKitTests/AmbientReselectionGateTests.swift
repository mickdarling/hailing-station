#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// A stream opened before the owner selected away and back (#636, second-key reviews on #695) ends at its next
/// segment, with the transient "ambient stopped:" refusal the device answers by opening a fresh stream, so RightyO
/// never acknowledges a turn the host would refuse. Synthetic only.
@Suite struct AmbientReselectionGateTests {
    let connection = UUID()

    func admit(
        _ gate: AmbientAudioGate, _ stream: UUID, _ sequence: Int, generation: UUID?, from: UUID? = nil,
        bytes: Int = 3_200
    ) async -> AmbientAdmission {
        await gate.admission(
            ambientSegment(stream: stream, sequence: sequence, bytes: bytes), frameTarget: "tmux:a",
            selection: AmbientSelection(target: "tmux:a", generation: generation), connection: from ?? connection,
            device: nil
        )
    }

    @Test func aSegmentUnderANewerSelectionEndsTheStream() async throws {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let (stream, opened, reselected) = (UUID(), UUID(), UUID())
        #expect(await admit(gate, stream, 0, generation: opened) == .admitted)
        #expect(await admit(gate, stream, 1, generation: opened) == .admitted)
        #expect(await admit(gate, stream, 2, generation: reselected)
            == .refused(.notAllowed, AmbientAudioGate.reselectedMessage))
        #expect(sink.endings == [.notAllowed] && sink.segments == [0, 1])
        #expect(await gate.activeStream == nil)
        // The device's fresh stream opens on the new selection and is admitted.
        let fresh = UUID()
        #expect(await admit(gate, fresh, 0, generation: reselected) == .admitted)
        #expect(sink.events.last == .segment(stream: fresh, sequence: 0, bytes: Data(repeating: 0, count: 3_200)))
    }

    /// A caller that tracks no selection (the older `selectedTarget:` entry) is unchanged.
    @Test func aStreamWithoutASelectionIsNotEnded() async throws {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let stream = UUID()
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: connection) == nil)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 1), connection: connection) == nil)
        #expect(sink.endings.isEmpty)
    }

    /// Another connection's segment on this stream id is refused as not its own, before any selection check, and
    /// leaves the stream running.
    @Test func anotherConnectionsSegmentIsNotTakenForAReselection() async throws {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let (stream, opened) = (UUID(), UUID())
        #expect(await admit(gate, stream, 0, generation: opened) == .admitted)
        #expect(await admit(gate, stream, 1, generation: UUID(), from: UUID())
            == .refused(.notAllowed, "ambient stream is not this device's"))
        #expect(sink.endings.isEmpty)
        #expect(await gate.activeStream == stream)
    }

    /// Over its rate budget, a stale stream's segment is still refused and ended, not dropped silently.
    @Test func aReselectionIsRefusedAheadOfTheRateBudget() async throws {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let (stream, opened) = (UUID(), UUID())
        let max = AmbientAudioGate.maxSegmentBytes
        for sequence in 0..<(AmbientAudioGate.burstBytes / max) {
            #expect(await admit(gate, stream, sequence, generation: opened, bytes: max) == .admitted)
        }
        let next = AmbientAudioGate.burstBytes / max
        #expect(await admit(gate, stream, next, generation: UUID(), bytes: max)
            == .refused(.notAllowed, AmbientAudioGate.reselectedMessage))
        #expect(sink.endings == [.notAllowed])
    }

    /// A stream opened with no generation that later carries one is refused: it fails closed.
    @Test func aGenerationAppearingMidStreamEndsIt() async throws {
        let gate = ambientGate(sink: RecordingAmbientSink(), clock: AmbientTestClock())
        let stream = UUID()
        #expect(await admit(gate, stream, 0, generation: nil) == .admitted)
        #expect(await admit(gate, stream, 1, generation: UUID())
            == .refused(.notAllowed, AmbientAudioGate.reselectedMessage))
    }

    /// A stream opened with a generation that later carries none is refused and ended too: a generation vanishing
    /// mid-stream fails closed.
    @Test func aGenerationVanishingMidStreamEndsIt() async throws {
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let stream = UUID()
        #expect(await admit(gate, stream, 0, generation: UUID()) == .admitted)
        #expect(await admit(gate, stream, 1, generation: nil)
            == .refused(.notAllowed, AmbientAudioGate.reselectedMessage))
        #expect(sink.endings == [.notAllowed] && sink.segments == [0])
        #expect(await gate.activeStream == nil)
    }

    /// End to end on the session: away and back with no segment between, then the stream's next segment.
    @Test func theDeviceIsToldWhyAndStaysConnected() async throws {
        let rig = try await VoiceRouteRig.make()
        let sink = RecordingAmbientSink()
        let gate = ambientGate(target: VoiceRouteRig.scratch, sink: sink, clock: AmbientTestClock())
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate),
                                  hostName: "mac-test")
        _ = await session.receive(helloFrame())
        let select = { (target: String) in
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        }
        let audio = { (stream: UUID, sequence: Int) in
            sessionFrame(target: VoiceRouteRig.scratch, payload: .audio(ambientSegment(stream: stream,
                                                                                        sequence: sequence)))
        }
        await select(VoiceRouteRig.scratch)
        let stream = UUID()
        #expect(await session.receive(audio(stream, 0)).frames.isEmpty)
        await select(VoiceRouteRig.other)
        await select(VoiceRouteRig.scratch)
        let ended = await session.receive(audio(stream, 1))
        #expect(try onlyControl(ended) == .error(code: .notAllowed, message: AmbientAudioGate.reselectedMessage))
        #expect(ended.disposition == .keepOpen)
        #expect(await session.receive(audio(UUID(), 0)).frames.isEmpty)
    }
}
#endif
