import Testing
@testable import HailCore

/// The rail's fail-safe properties over every combination of its inputs (#1115).
@Suite("Listening and privacy rail sweep (#1115)")
struct ListeningPrivacyRailSweepTests {
    private typealias Fixture = RailFixtures

    // Jarvis, PR 4 plan: whenever the microphone isn't off, the tone is alert or private, never neutral. Private
    // needs confirmed privacy on a ready station with no tap waiting.
    @Test func everyMicrophoneThatIsNotOffIsAlertOrPrivate() {
        // 4 mics × 6 listening × 5 talk × 7 privacy × 3 handoffs × 11 availabilities × 3 connections.
        #expect(Fixture.everyCase.count == 83_160)
        for item in Fixture.everyCase {
            let state = item.state
            let talkCapturing = item.talk.map { $0 != .idle } ?? false
            let micOff = item.mic == .off && item.listening?.isOn != true && !talkCapturing
            if !micOff {
                #expect(state.tone != .neutral, "\(item)")
                #expect(state.mic != .off, "\(item)")
                #expect(state.kind != .off, "\(item)")
            }
            if state.kind == .privateConfirmed {
                #expect(item.host.privacy == Fixture.confirmedPrivate, "\(item)")
                #expect(item.host.availability == .ready, "\(item)")
                #expect(item.host.privacy != Fixture.pending, "\(item)")
                // Codex review of #1153: privacy covers ambient listening only, never talk.
                #expect(item.talk == .idle, "\(item)")
                #expect(item.listening == .listening, "\(item)")
            }
            // Codex review of #1153: a live microphone or talk capture is never blamed on another app.
            if state.kind == .paused {
                #expect(item.mic != .live, "\(item)")
                #expect(!talkCapturing, "\(item)")
            }
            #expect(state.mic == item.mic || item.mic == nil || state.mic == .uncertain, "\(item)")
        }
    }

    // Codex review of #1153: paused claims another app has the microphone, so active capture outranks it.
    @Test func pausedNeverHidesActiveCapture() {
        let live = Fixture.resolve(mic: .live, listening: .paused, privacy: Fixture.notPrivate)
        #expect(live.kind == .recording)
        #expect(live.summary == "Recording")
        #expect(!live.accessibilityLabel.contains("Another app"))
        for talk: TalkCapturePhase in [.starting, .recording, .finishing] {
            for privacy in Fixture.privacies {
                let state = Fixture.resolve(mic: .uncertain, listening: .paused, talk: talk, privacy: privacy)
                #expect(state.kind != .paused, "\(talk) \(String(describing: privacy))")
                #expect(state.tone == .alert, "\(talk) \(String(describing: privacy))")
            }
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
