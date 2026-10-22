public import Foundation

/// A tap on the privacy switch (#735 S-6) still waiting for the host's `duck_mode` notice: the state asked for and when.
public struct PrivacyRequest: Equatable, Sendable {
    public let on: Bool
    public let at: Date

    public init(on: Bool, at: Date = Date()) {
        (self.on, self.at) = (on, at)
    }
}

/// What the station's privacy switch shows (#735 S-6, privacy is internally duck). Mick's rule: it shows PRIVATE
/// only while the host has positively confirmed privacy on a live connection. Every state that is not confirmed
/// (no notice yet, a connection that is not ready, a stale or lapsed notice, a tap still waiting for its notice) shows
/// NOT private, as "Recording may be on". The switch follows the host's notice, never the local tap.
public struct PrivacySwitchStatus: Equatable, Sendable {
    /// How long a tap waits for the host's notice before the switch stops waiting. It then shows the host's last
    /// confirmed state, or "Recording may be on" when there is none.
    public static let pendingTimeout: TimeInterval = 10

    public enum Shown: Equatable, Sendable {
        /// The host confirmed privacy on, on this live connection.
        case confirmedPrivate
        /// The host confirmed privacy off, on this live connection.
        case confirmedNotPrivate
        /// Anything else: unknown, connecting, stale, lapsed, or a tap waiting for its notice.
        case unconfirmed
    }

    public let shown: Shown
    /// A tap is waiting for the host's notice.
    public let pending: Bool

    /// The only state in which the switch and indicator say private.
    public var isPrivate: Bool { shown == .confirmedPrivate }

    /// `ready`: the host's connection is ready now. `duck`: the host's last `duck_mode` on this connection, if any.
    /// `requested`: a tap still waiting for its notice, if any.
    public init(ready: Bool, duck: DuckModeStatus?, requested: PrivacyRequest?, now: Date = Date()) {
        pending = ready && requested.map { now < $0.at.addingTimeInterval(Self.pendingTimeout) } == true
        guard ready, !pending, let duck else {
            shown = .unconfirmed
            return
        }
        // An on notice past its expiry is no longer a confirmation.
        shown = duck.isOn(now: now) ? .confirmedPrivate : .confirmedNotPrivate
    }

    public var title: String {
        switch shown {
        case .confirmedPrivate: "Private"
        case .confirmedNotPrivate: "Not private"
        case .unconfirmed: "Recording may be on"
        }
    }

    public var detail: String {
        if pending { return "Waiting for the Mac to confirm." }
        switch shown {
        case .confirmedPrivate: return "The Mac confirmed privacy. It is only listening for its name."
        case .confirmedNotPrivate: return "The Mac is recording and sending requests."
        case .unconfirmed: return "The Mac has not confirmed privacy."
        }
    }
}
