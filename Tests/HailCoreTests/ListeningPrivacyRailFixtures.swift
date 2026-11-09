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

    struct Case {
        let mic: MicLiveState?
        let listening: StationMenuStatus.Listening?
        let privacy: RailPrivacy?
        let handoff: AmbientHandoff?
        let availability: StationAvailability
        let connection: RailConnection?
        var state: ListeningPrivacyRailState {
            .resolve(mic: mic, listening: listening, host: RailHost(
                privacy: privacy, handoff: handoff, availability: availability, connection: connection))
        }
    }

    static var everyCase: [Case] {
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

    static func resolve(
        mic: MicLiveState?, listening: StationMenuStatus.Listening? = .listening, privacy: RailPrivacy?,
        handoff: AmbientHandoff? = nil, availability: StationAvailability = .ready, connection: RailConnection? = nil
    ) -> ListeningPrivacyRailState {
        .resolve(mic: mic, listening: listening, host: RailHost(
            privacy: privacy, handoff: handoff, availability: availability, connection: connection))
    }
}
