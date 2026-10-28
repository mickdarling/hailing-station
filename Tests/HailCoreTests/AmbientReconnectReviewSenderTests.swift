import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewSenderTests {
    @Test func senderAlreadyInFlightMustNotRebindPreDropPCMToReplacementConnection() async throws {
        let rig = try AmbientReconnectRig()
        let senderAdmission = SleepGate()
        installDelayedSender(rig, gate: senderAdmission)
        try await rig.start()
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        for _ in 0..<4 { try rig.capture.yield(sineBuffer()) }
        try await waitUntil { await senderAdmission.isWaiting() }
        let droppedStream = rig.controller.binding
        try await rig.drop()
        let host = try await rig.privateReconnect()
        try await rig.expectNoRestoredPCM()
        let oldBinding = rig.controller.binding
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != oldBinding } }
        await senderAdmission.fire()
        try await rig.feed()
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let audio = try #require(try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let payload) = frame.payload { return payload }; return nil
        }.first)
        #expect(audio.sequence == 0 && audio.isResume,
                "Old queued PCM must never open a normal start on a replacement connection")
        #expect(rig.controller.binding != droppedStream)
        await rig.close()
    }
    private func installDelayedSender(_ rig: AmbientReconnectRig, gate: SleepGate) {
        rig.controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { send in
                AmbientAudioStreamer(capture: rig.capture, send: { payload in
                    // Model a queue sender awaiting its hop onto the controller's main actor.
                    if payload.sequence == 0 && !payload.isResume { try await gate.sleep(.zero) }
                    try await send(payload)
                })
            }, releaseSession: { rig.released += 1 },
            send: { payload, binding in try await rig.store.sendAudio(payload, to: binding) }
        )
    }
}
