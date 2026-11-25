#if os(macOS)
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
        let owner = PrivacySettingsFixture(connections: rig.store, host: rig.endpoint.id)
        func rail(_ displayed: AmbientAudioBinding?) -> ListeningPrivacyRailState {
            let observation = StationScreenPrivacy(displayedHost: rig.endpoint.id, binding: displayed,
                liveBinding: rig.controller.binding, settings: owner.privacySettingsState())
            let host = RailHost(store: rig.store, privacy: observation.privacy, availability: .ready)
            return .resolve(mic: .live, listening: .listening, talk: .idle, host: host)
        }
        try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        #expect(rail(binding).kind == .mayBeRecording)
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.isOn() == true } }
        #expect(rail(binding).kind == .privateConfirmed)
        #expect(rail(nil).kind == .mayBeRecording)
    }
}
#endif
