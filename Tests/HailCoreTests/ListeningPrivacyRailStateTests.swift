import Foundation
import Testing
@testable import HailCore

@Suite("Listening and privacy rail (#1115)")
struct ListeningPrivacyRailStateTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let on = DuckModeStatus(on: true, reason: "device")
    private static let off = DuckModeStatus(on: false, reason: "device")

    private static let confirmedPrivate = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: nil, now: now))
    private static let privateUnavailable = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: nil, listeningStopped: true, now: now))
    private static let notPrivate = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: off, requested: nil, now: now))
    private static let unconfirmed = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: nil, requested: nil, now: now))
    /// A tap for privacy still waiting for the host, while the host's last notice said on.
    private static let pending = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: PrivacyRequest(on: true, at: now), now: now))

    private static let mics: [MicLiveState?] = [.live, .uncertain, .off, nil]
    private static let listenings: [StationMenuStatus.Listening?] = [
        nil, .off, .starting, .listening, .paused, .elsewhere
    ]
    private static let privacies: [RailPrivacy?] = [
        nil, .unsupported, confirmedPrivate, privateUnavailable, notPrivate, unconfirmed, pending
    ]
    private static let handoffs: [AmbientHandoff?] = [nil, .movedAway(to: "pad"), .movedHere(from: "phone")]
    private static let availabilities: [StationAvailability] = [
        .unconfigured, .connecting, .reconnecting, .waitingForTargets, .restoringSelection, .chooseTarget,
        .noAllowedTargets, .selectionFailed, .ready, .failed, .offline
    ]
    private static let connections: [RailConnection?] = [nil, .reconnecting, .stopped(reason: "Connection dropped")]

    private struct Case {
        let mic: MicLiveState?
        let listening: StationMenuStatus.Listening?
        let privacy: RailPrivacy?
        let handoff: AmbientHandoff?
        let availability: StationAvailability
        let connection: RailConnection?
        var state: ListeningPrivacyRailState {
            .resolve(mic: mic, listening: listening, privacy: privacy, handoff: handoff,
                     availability: availability, connection: connection)
        }
    }

    private static var everyCase: [Case] {
        var cases: [Case] = []
        for mic in mics {
            for listening in listenings {
                for privacy in privacies {
                    for handoff in handoffs {
                        for availability in availabilities {
                            for connection in connections {
                                cases.append(Case(mic: mic, listening: listening, privacy: privacy, handoff: handoff,
                                                  availability: availability, connection: connection))
                            }
                        }
                    }
                }
            }
        }
        return cases
    }

    private func resolve(
        mic: MicLiveState?, listening: StationMenuStatus.Listening? = .listening, privacy: RailPrivacy?,
        handoff: AmbientHandoff? = nil, availability: StationAvailability = .ready, connection: RailConnection? = nil
    ) -> ListeningPrivacyRailState {
        .resolve(mic: mic, listening: listening, privacy: privacy, handoff: handoff, availability: availability,
                 connection: connection)
    }

    // Jarvis, PR 4 plan: whenever the microphone isn't off, the tone is alert or private, never neutral. Private
    // needs confirmed privacy on a ready station with no tap waiting.
    @Test func everyMicrophoneThatIsNotOffIsAlertOrPrivate() {
        for item in Self.everyCase {
            let state = item.state
            let micOff = item.mic == .off && item.listening?.isOn != true
            if !micOff {
                #expect(state.tone != .neutral, "\(item)")
                #expect(state.mic != .off, "\(item)")
                #expect(state.kind != .off, "\(item)")
            }
            if state.tone == .private, state.kind == .privateConfirmed {
                #expect(item.privacy == Self.confirmedPrivate, "\(item)")
                #expect(item.availability == .ready, "\(item)")
                #expect(item.privacy != Self.pending, "\(item)")
            }
            #expect(state.mic == item.mic || item.mic == nil || state.mic == .uncertain, "\(item)")
        }
    }

    @Test func unknownInputsFailSafeToRecordingMayBeOn() {
        let state = ListeningPrivacyRailState.resolve(
            mic: nil, listening: nil, privacy: nil, handoff: nil, availability: .ready, connection: nil)
        #expect(state.kind == .mayBeRecording)
        #expect(state.summary == "Recording may be on")
        #expect(state.mic == .uncertain)
        #expect(resolve(mic: .live, privacy: nil).kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Self.unconfirmed).kind == .mayBeRecording)
    }

    @Test func aPendingPrivacyRequestIsNeverPrivate() {
        let state = resolve(mic: .live, privacy: Self.pending)
        #expect(state.kind == .mayBeRecording)
        #expect(state.tone == .alert)
    }

    @Test func confirmedPrivateWithALiveMicSaysTheMicIsOn() {
        let state = resolve(mic: .live, privacy: Self.confirmedPrivate)
        #expect(state.kind == .privateConfirmed)
        #expect(state.tone == .private)
        #expect(state.mic == .live)
        #expect(state.summary == "Private · mic on for its name")
        #expect(state.detail.hasPrefix("The microphone is on."))
        #expect(resolve(mic: .uncertain, privacy: Self.confirmedPrivate).summary == "Private · mic may be on")
    }

    @Test func privateOnAStationThatIsNotReadyMayBeRecording() {
        for availability in Self.availabilities where availability != .ready {
            let state = resolve(mic: .live, privacy: Self.confirmedPrivate, availability: availability)
            #expect(state.kind == .mayBeRecording, "\(availability)")
            #expect(!state.summary.contains("Connected"), "\(availability)")
        }
    }

    @Test func privateListeningUnavailableNeedsTheLocalMicOff() {
        let live = resolve(mic: .live, privacy: Self.privateUnavailable)
        #expect(live.kind == .mayBeRecording)
        let off = resolve(mic: .off, listening: .off, privacy: Self.privateUnavailable)
        #expect(off.kind == .privateUnavailable)
        #expect(off.summary == "Privacy on · listening unavailable")
        #expect(off.tone == .private)
    }

    @Test func aHostClaimNeverClearsALiveMic() {
        #expect(resolve(mic: .live, privacy: Self.notPrivate, handoff: .movedAway(to: "pad")).kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Self.notPrivate, connection: .reconnecting).kind == .mayBeRecording)
        #expect(resolve(mic: .live, privacy: Self.confirmedPrivate,
                        connection: .stopped(reason: "Connection dropped")).kind == .mayBeRecording)
    }

    @Test func aMicReportedOffWhileListeningIsOnIsUncertain() {
        let state = resolve(mic: .off, listening: .listening, privacy: Self.notPrivate)
        #expect(state.mic == .uncertain)
        #expect(state.kind == .mayBeRecording)
    }

    @Test func notPrivateListeningIsRecording() {
        let state = resolve(mic: .live, privacy: Self.notPrivate)
        #expect(state.kind == .recording)
        #expect(state.summary == "Listening · recording")
        #expect(state.tone == .alert)
        #expect(resolve(mic: .uncertain, listening: .starting, privacy: Self.notPrivate).kind == .mayBeRecording)
    }

    @Test func aHostWithoutPrivacySaysEverythingIsSent() {
        let state = resolve(mic: .live, privacy: .unsupported)
        #expect(state.kind == .recording)
        #expect(state.summary == "Listening · recording")
        #expect(state.detail.hasSuffix("This Mac has no privacy mode, so everything heard is sent."))
    }

    @Test func pausedIsAnAlertWithItsOwnWording() {
        for privacy in Self.privacies {
            let state = resolve(mic: .uncertain, listening: .paused, privacy: privacy)
            #expect(state.kind == .paused, "\(String(describing: privacy))")
            #expect(state.summary == "Listening paused · resumes by itself")
            #expect(state.tone == .alert)
        }
    }

    @Test func movedAwayWithTheMicOffNamesTheDevice() {
        let state = resolve(mic: .off, listening: .elsewhere, privacy: Self.notPrivate, handoff: .movedAway(to: "pad"))
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

    // Stopping local capture doesn't prove the Mac or another device stopped.
    @Test func offSpeaksOnlyForThisDevice() {
        let state = resolve(mic: .off, listening: .off, privacy: Self.notPrivate)
        #expect(state.kind == .off)
        #expect(state.summary == "Not listening on this device")
        #expect(state.detail.contains("doesn't show whether the Mac or another device is"))
        for item in Self.everyCase where item.state.kind == .off {
            #expect(!item.state.summary.localizedCaseInsensitiveContains("recording off"))
            #expect(!item.state.detail.localizedCaseInsensitiveContains("mic off"))
        }
    }

    @Test func voiceOverReadsTheFullDetail() {
        let state = resolve(mic: .live, privacy: Self.confirmedPrivate)
        #expect(state.accessibilityLabel == "\(state.summary). \(state.detail)")
    }

    @Test func onlyAKindChangeIsAnnounced() {
        let live = resolve(mic: .live, privacy: Self.confirmedPrivate)
        let uncertain = resolve(mic: .uncertain, privacy: Self.confirmedPrivate)
        #expect(live.summary != uncertain.summary)
        #expect(live.announcementKey == uncertain.announcementKey)
        #expect(live.announcementKey != resolve(mic: .live, privacy: Self.notPrivate).announcementKey)
    }
}
