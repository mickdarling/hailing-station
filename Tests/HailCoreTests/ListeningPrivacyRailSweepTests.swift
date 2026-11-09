import Testing
@testable import HailCore

/// The rail's fail-safe properties over every combination of its inputs (#1115).
@Suite("Listening and privacy rail sweep (#1115)")
struct ListeningPrivacyRailSweepTests {
    private typealias Fixture = RailFixtures

    // Jarvis, PR 4 plan: whenever the microphone isn't off, the tone is alert or private, never neutral. Private
    // needs confirmed privacy on a ready station with no tap waiting.
    @Test func everyMicrophoneThatIsNotOffIsAlertOrPrivate() {
        for item in Fixture.everyCase {
            let state = item.state
            let micOff = item.mic == .off && item.listening?.isOn != true
            if !micOff {
                #expect(state.tone != .neutral, "\(item)")
                #expect(state.mic != .off, "\(item)")
                #expect(state.kind != .off, "\(item)")
            }
            if state.tone == .private, state.kind == .privateConfirmed {
                #expect(item.privacy == Fixture.confirmedPrivate, "\(item)")
                #expect(item.availability == .ready, "\(item)")
                #expect(item.privacy != Fixture.pending, "\(item)")
            }
            #expect(state.mic == item.mic || item.mic == nil || state.mic == .uncertain, "\(item)")
        }
    }

    // Stopping local capture doesn't prove the Mac or another device stopped.
    @Test func offSpeaksOnlyForThisDevice() {
        let state = Fixture.resolve(mic: .off, listening: .off, privacy: Fixture.notPrivate)
        #expect(state.kind == .off)
        #expect(state.summary == "Not listening on this device")
        #expect(state.detail.contains("doesn't show whether the Mac or another device is"))
        for item in Fixture.everyCase where item.state.kind == .off {
            #expect(!item.state.summary.localizedCaseInsensitiveContains("recording off"))
            #expect(!item.state.detail.localizedCaseInsensitiveContains("mic off"))
        }
    }
}
