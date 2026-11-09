import Foundation
@testable import HailCore

/// Shared inputs for the rail's row tests and its exhaustive sweep (#1115).
enum RailFixtures {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let on = DuckModeStatus(on: true, reason: "device")
    static let off = DuckModeStatus(on: false, reason: "device")

    static let confirmedPrivate = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: nil, now: now))
    static let privateUnavailable = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: nil, listeningStopped: true, now: now))
    static let notPrivate = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: off, requested: nil, now: now))
    static let unconfirmed = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: nil, requested: nil, now: now))
    /// A tap for privacy still waiting for the host, while the host's last notice said on.
    static let pending = RailPrivacy.status(PrivacySwitchStatus(
        ready: true, duck: on, requested: PrivacyRequest(on: true, at: now), now: now))

    static let mics: [MicLiveState?] = [.live, .uncertain, .off, nil]
    static let listenings: [StationMenuStatus.Listening?] = [
        nil, .off, .starting, .listening, .paused, .elsewhere
    ]
    static let privacies: [RailPrivacy?] = [
        nil, .unsupported, confirmedPrivate, privateUnavailable, notPrivate, unconfirmed, pending
    ]
    static let handoffs: [AmbientHandoff?] = [nil, .movedAway(to: "pad"), .movedHere(from: "phone")]
    static let availabilities: [StationAvailability] = [
        .unconfigured, .connecting, .reconnecting, .waitingForTargets, .restoringSelection, .chooseTarget,
        .noAllowedTargets, .selectionFailed, .ready, .failed, .offline
    ]
    static let connections: [RailConnection?] = [nil, .reconnecting, .stopped(reason: "Connection dropped")]

    static let talks: [TalkCapturePhase?] = [nil, .idle, .starting, .recording, .finishing]

    struct Case: Sendable, CustomStringConvertible {
        let mic: MicLiveState?
        let listening: StationMenuStatus.Listening?
        let talk: TalkCapturePhase?
        let host: RailHost
        var state: ListeningPrivacyRailState { .resolve(mic: mic, listening: listening, talk: talk, host: host) }
        var description: String { "mic \(String(describing: mic)), listening \(String(describing: listening)), "
            + "talk \(String(describing: talk)), \(host)" }
    }

    /// Every combination of the inputs above.
    static let everyCase: [Case] = {
        let hosts = privacies.flatMap { privacy in
            handoffs.flatMap { handoff in
                availabilities.flatMap { availability in
                    connections.map { RailHost(privacy: privacy, handoff: handoff, availability: availability,
                                               connection: $0) }
                }
            }
        }
        return mics.flatMap { mic in
            listenings.flatMap { listening in
                talks.flatMap { talk in hosts.map { Case(mic: mic, listening: listening, talk: talk, host: $0) } }
            }
        }
    }()

    static func resolve(
        mic: MicLiveState?, listening: StationMenuStatus.Listening? = .listening, talk: TalkCapturePhase? = .idle,
        privacy: RailPrivacy?, handoff: AmbientHandoff? = nil, availability: StationAvailability = .ready,
        connection: RailConnection? = nil
    ) -> ListeningPrivacyRailState {
        .resolve(mic: mic, listening: listening, talk: talk, host: RailHost(
            privacy: privacy, handoff: handoff, availability: availability, connection: connection))
    }
}
