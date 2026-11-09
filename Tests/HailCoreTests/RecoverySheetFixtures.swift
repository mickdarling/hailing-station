import Foundation
@testable import HailCore

/// Inputs shared by the recovery sheet's row tests and sweep (#1115).
enum RecoveryFixtures {
    static let build = DestinationLabel(hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    static let confirmed = DestinationControlState.confirmed(build)

    /// The host hasn't reported its privacy switch yet.
    static let unconfirmed = status(nil)

    static func privacy(on: Bool, requested: Bool = false, stopped: Bool = false) -> RailPrivacy {
        status(DuckModeStatus(on: on), requested: requested, stopped: stopped)
    }

    private static func status(_ duck: DuckModeStatus?, requested: Bool = false, stopped: Bool = false) -> RailPrivacy {
        let now = Date(timeIntervalSince1970: 0)
        return .status(PrivacySwitchStatus(
            ready: true, duck: duck, requested: requested ? PrivacyRequest(on: true, at: now) : nil,
            listeningStopped: stopped, now: now))
    }

    static func resolve(
        _ availability: StationAvailability = .ready, destination: DestinationControlState = confirmed,
        privacy: RailPrivacy? = .unsupported, listening: StationMenuStatus.Listening? = .listening,
        wasListening: Bool = true, turn: TurnOutcome? = nil
    ) -> RecoverySheetState {
        RecoverySheetState.resolve(availability: availability, destination: destination, privacy: privacy,
                                   listening: (current: listening, wasOn: wasListening), turn: turn)
    }
}
