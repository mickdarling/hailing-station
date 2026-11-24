import AVFAudio
import Foundation
import Testing
@testable import HailCore

@MainActor
struct StationRailObservationTests {
    @Test func aPrivacyRequestNeedsAnAcknowledgementForTheDisplayedStream() async throws {
        let rig = try AmbientReconnectRig()
        do {
            try await rig.start()
            try await assertAcknowledgement(in: rig)
        } catch {
            await rig.close()
            throw error
        }
        await rig.close()
    }

    private func assertAcknowledgement(in rig: AmbientReconnectRig) async throws {
        let binding = try rig.currentBinding()
        func rail(_ displayed: AmbientAudioBinding?) -> ListeningPrivacyRailState {
            let host = RailHost(store: rig.store, confirmedHost: rig.endpoint.id, binding: displayed,
                                availability: .ready, now: .now)
            return .resolve(mic: .live, listening: .listening, talk: .idle, host: host)
        }
        try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        #expect(rail(binding).kind == .mayBeRecording)
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.isOn() == true } }
        #expect(rail(binding).kind == .privateConfirmed)
        #expect(rail(nil).kind == .mayBeRecording)
    }

    @Test func engineObservationTracksTheInputTapWithoutStartingIt() throws {
        let fake = FakeEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        let before = AVAudioEngineCapture.microphoneState
        #expect(!fake.running && fake.tap == nil)
        let stream = try capture.start()
        #expect(AVAudioEngineCapture.microphoneState == .running)
        capture.stop()
        #expect(AVAudioEngineCapture.microphoneState == before)
        withExtendedLifetime(stream) {}
    }
}
