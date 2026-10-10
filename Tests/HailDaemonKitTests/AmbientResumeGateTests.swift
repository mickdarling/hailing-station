import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #373 at the gate: a device's automatic restart (`resume`) never takes listening over. Synthetic only.
@Suite struct AmbientResumeGateTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()
    let phone = UUID()
    let pad = UUID()

    private func admission(
        _ gate: AmbientAudioGate, _ stream: UUID, _ sequence: Int, from connection: UUID, device: String?,
        resume: Bool = false, isFinal: Bool = false
    ) async -> AmbientAdmission {
        var audio = ambientSegment(stream: stream, sequence: sequence, isFinal: isFinal)
        audio.isResume = resume
        return await gate.admission(
            audio, frameTarget: "tmux:a", selectedTarget: "tmux:a", connection: connection, device: device
        )
    }

    @Test func aRetryAfterAnotherDeviceStartedIsToldListeningMovedAndTakesNothing() async {
        let gate = ambientGate(sink: sink, clock: clock)
        // The phone's stream ends without a take-over (here it idles out), so the gate records no move for it.
        #expect(await admission(gate, UUID(), 0, from: phone, device: "phone") == .admitted)
        clock.advance(AmbientAudioGate.idleTimeout)
        await gate.expireIdle()
        // The pad starts while the phone waits to retry: nothing to take over.
        let padStream = UUID()
        #expect(await admission(gate, padStream, 0, from: pad, device: "pad") == .admitted)
        // The phone's automatic retry is refused as moved, and the pad keeps listening.
        let retry = UUID()
        #expect(await admission(gate, retry, 0, from: phone, device: "phone", resume: true)
            == .refused(.notAllowed, "ambient moved to pad"))
        #expect(await gate.activeStream == padStream)
        #expect(sink.endings == [.idle])
        #expect(await admission(gate, padStream, 1, from: pad, device: "pad") == .admitted)
        // The refused retry burned nothing: once the pad is done, the same id resumes.
        #expect(await admission(gate, padStream, 2, from: pad, device: "pad", isFinal: true) == .admitted)
        #expect(await admission(gate, retry, 0, from: phone, device: "phone", resume: true) == .admitted)
        #expect(await gate.activeStream == retry)
    }

    @Test func aRetryResumesWhenNobodyElseIsListening() async {
        let gate = ambientGate(sink: sink, clock: clock)
        let retry = UUID()
        #expect(await admission(gate, retry, 0, from: phone, device: "phone", resume: true) == .admitted)
        #expect(await gate.activeStream == retry)
        // Its own stream still replaces itself, as any new stream from the owner does.
        let next = UUID()
        #expect(await admission(gate, next, 0, from: phone, device: "phone", resume: true) == .admitted)
        #expect(await gate.activeStream == next)
        #expect(sink.endings == [.superseded])
    }

    @Test func aStartSomeoneAskedForStillTakesOver() async {
        let gate = ambientGate(sink: sink, clock: clock)
        #expect(await admission(gate, UUID(), 0, from: pad, device: "pad") == .admitted)
        #expect(await admission(gate, UUID(), 0, from: phone, device: "phone") == .tookOver(from: "pad"))
    }

    @Test func aRefusedRetryNamesAnUnknownDeviceAsAnotherDevice() async {
        let gate = ambientGate(sink: sink, clock: clock)
        #expect(await admission(gate, UUID(), 0, from: pad, device: nil) == .admitted)
        #expect(await admission(gate, UUID(), 0, from: phone, device: "phone", resume: true)
            == .refused(.notAllowed, "ambient moved to another device"))
    }
}
