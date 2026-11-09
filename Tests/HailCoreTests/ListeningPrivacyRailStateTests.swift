import Testing
@testable import HailCore

@Suite("Listening and privacy rail (#1115)")
struct ListeningPrivacyRailStateTests {
    private typealias Fixture = RailFixtures

    private func resolve(
        mic: MicLiveState?, listening: StationMenuStatus.Listening? = .listening, privacy: RailPrivacy?,
        handoff: AmbientHandoff? = nil, availability: StationAvailability = .ready, connection: RailConnection? = nil
    ) -> ListeningPrivacyRailState {
        RailFixtures.resolve(mic: mic, listening: listening, privacy: privacy, handoff: handoff,
                             availability: availability, connection: connection)
    }

    @Test func unknownInputsFailSafeToRecordingMayBeOn() {
        let state = ListeningPrivacyRailState.resolve(
            mic: nil, listening: nil, host: RailHost(privacy: nil, handoff: nil, availability: .ready, connection: nil))
        #expect(state.kind == .mayBeRecording)
        #expect(state.summary == "Recording may be on")
        #expect(state.mic == .uncertain)
        #expect(resolve(mic: .live, privacy: nil).kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Fixture.unconfirmed).kind == .mayBeRecording)
    }

    @Test func aPendingPrivacyRequestIsNeverPrivate() {
        let state = resolve(mic: .live, privacy: Fixture.pending)
        #expect(state.kind == .mayBeRecording)
        #expect(state.tone == .alert)
    }

    @Test func confirmedPrivateWithALiveMicSaysTheMicIsOn() {
        let state = resolve(mic: .live, privacy: Fixture.confirmedPrivate)
        #expect(state.kind == .privateConfirmed)
        #expect(state.tone == .private)
        #expect(state.mic == .live)
        #expect(state.summary == "Private · mic on for its name")
        #expect(state.detail.hasPrefix("The microphone is on."))
        #expect(resolve(mic: .uncertain, privacy: Fixture.confirmedPrivate).summary == "Private · mic may be on")
    }

    @Test func privateOnAStationThatIsNotReadyMayBeRecording() {
        for availability in Fixture.availabilities where availability != .ready {
            let state = resolve(mic: .live, privacy: Fixture.confirmedPrivate, availability: availability)
            #expect(state.kind == .mayBeRecording, "\(availability)")
            #expect(!state.summary.contains("Connected"), "\(availability)")
        }
    }

    @Test func privateListeningUnavailableNeedsTheLocalMicOff() {
        let live = resolve(mic: .live, privacy: Fixture.privateUnavailable)
        #expect(live.kind == .mayBeRecording)
        let off = resolve(mic: .off, listening: .off, privacy: Fixture.privateUnavailable)
        #expect(off.kind == .privateUnavailable)
        #expect(off.summary == "Privacy on · listening unavailable")
        #expect(off.tone == .private)
    }

    @Test func aHostClaimNeverClearsALiveMic() {
        let moved = resolve(mic: .live, privacy: Fixture.notPrivate, handoff: .movedAway(to: "pad"))
        #expect(moved.kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Fixture.notPrivate, connection: .reconnecting).kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Fixture.confirmedPrivate,
                        connection: .stopped(reason: "Connection dropped")).kind == .mayBeRecording)
    }

    @Test func aMicReportedOffWhileListeningIsOnIsUncertain() {
        let state = resolve(mic: .off, listening: .listening, privacy: Fixture.notPrivate)
        #expect(state.mic == .uncertain)
        #expect(state.kind == .mayBeRecording)
    }

    @Test func notPrivateListeningIsRecording() {
        let state = resolve(mic: .live, privacy: Fixture.notPrivate)
        #expect(state.kind == .recording)
        #expect(state.summary == "Listening · recording")
        #expect(state.tone == .alert)
        #expect(resolve(mic: .uncertain, listening: .starting, privacy: Fixture.notPrivate).kind == .mayBeRecording)
    }

    // Jarvis, PR 4 table review: talk alone with a live mic and privacy off is certain recording.
    @Test func talkAloneWithPrivacyOffIsRecording() {
        let state = resolve(mic: .live, listening: .off, privacy: Fixture.notPrivate)
        #expect(state.kind == .recording)
        #expect(state.summary == "Recording")
        #expect(state.tone == .alert)
    }

    @Test func aHostWithoutPrivacySaysEverythingIsSent() {
        let state = resolve(mic: .live, privacy: .unsupported)
        #expect(state.kind == .recording)
        #expect(state.summary == "Listening · recording")
        #expect(state.detail.hasSuffix("This Mac has no privacy mode, so everything heard is sent."))
    }

    @Test func pausedIsAnAlertWithItsOwnWording() {
        for privacy in Fixture.privacies {
            let state = resolve(mic: .uncertain, listening: .paused, privacy: privacy)
            #expect(state.kind == .paused, "\(String(describing: privacy))")
            #expect(state.summary == "Listening paused · resumes by itself")
            #expect(state.tone == .alert)
        }
    }

    @Test func movedAwayWithTheMicOffNamesTheDevice() {
        let state = resolve(mic: .off, listening: .elsewhere, privacy: Fixture.notPrivate,
                            handoff: .movedAway(to: "pad"))
        #expect(state.kind == .elsewhere)
        #expect(state.summary == "Listening on iPad")
        #expect(resolve(mic: .off, listening: .elsewhere, privacy: nil).summary == "Listening on another device")
    }

    @Test func aDroppedRunWithTheMicOffIsInterrupted() {
        let reconnecting = resolve(mic: .off, listening: .off, privacy: nil, connection: .reconnecting)
        #expect(reconnecting.kind == .interrupted)
        #expect(reconnecting.summary == "Reconnecting…")
        let stopped = resolve(mic: .off, listening: .off, privacy: nil,
                              connection: .stopped(reason: "Listening stopped; re-authorization needed."))
        #expect(stopped.summary == "Listening stopped")
        #expect(stopped.detail.hasPrefix("Listening stopped; re-authorization needed. This device"))
    }

    @Test func voiceOverReadsTheFullDetail() {
        let state = resolve(mic: .live, privacy: Fixture.confirmedPrivate)
        #expect(state.accessibilityLabel == "\(state.summary). \(state.detail)")
    }

    @Test func onlyAKindChangeIsAnnounced() {
        let live = resolve(mic: .live, privacy: Fixture.confirmedPrivate)
        let uncertain = resolve(mic: .uncertain, privacy: Fixture.confirmedPrivate)
        #expect(live.summary != uncertain.summary)
        #expect(live.announcementKey == uncertain.announcementKey)
        #expect(live.announcementKey != resolve(mic: .live, privacy: Fixture.notPrivate).announcementKey)
    }
}
