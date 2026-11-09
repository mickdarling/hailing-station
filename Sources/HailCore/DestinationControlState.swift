/// A destination as the control displays it (#1115). The display names and the target ID stay distinct: the label
/// is something to read, never authority to send. Selection stays with the station's own owner and its browser.
public struct DestinationLabel: Equatable, Sendable {
    public let hostName: String
    public let targetName: String
    public let targetKind: String
    public let targetID: String

    public init(hostName: String, targetName: String, targetKind: String, targetID: String) {
        self.hostName = hostName
        self.targetName = targetName
        self.targetKind = targetKind
        self.targetID = targetID
    }

    public var role: String { targetKind == "tmux" ? "Terminal" : "\(targetKind.capitalized) target" }
    public var summary: String { "Mac \(hostName), \(role) \(targetName)" }
}

/// Why no destination is current, worded only from the station's own availability. The host reports a target as
/// alive or not; the control never invents a policy cause beyond that.
public enum DestinationUnavailableReason: Equatable, Sendable {
    case offline
    case failed
    case noAllowedTargets
    case waitingForTargets
    case selectionFailed
    /// Connected and ready, but the owner confirmed no destination for this connection.
    case unconfirmed

    public var text: String {
        switch self {
        case .offline: "offline"
        case .failed: "connection failed"
        case .noAllowedTargets: "no allowed targets"
        case .waitingForTargets: "waiting for targets"
        case .selectionFailed: "selection not restored"
        case .unconfirmed: "not confirmed"
        }
    }
}

/// What the destination control shows (#1115). It is a reading of the owner's state and has no authority: it
/// never selects, clears or changes a target, recipient or route.
public enum DestinationControlState: Equatable, Sendable {
    /// The owner confirmed this destination for the current connection, and the station is ready.
    case confirmed(DestinationLabel)
    /// Connecting, reconnecting or restoring. A saved destination, if any, is not current.
    case confirming(saved: DestinationLabel?)
    case unavailable(DestinationUnavailableReason, saved: DestinationLabel?)
    /// No Mac set up, or none chosen yet.
    case none

    /// `confirmed` is the owner's confirmed-current destination and `remembered` its saved selection. A confirmed
    /// label passed while the station is not ready is stale, so it is shown only as saved, never as current.
    public static func resolve(
        availability: StationAvailability, confirmed: DestinationLabel?, remembered: DestinationLabel?
    ) -> Self {
        let saved = remembered ?? confirmed
        switch availability {
        case .ready:
            guard let confirmed else { return .unavailable(.unconfirmed, saved: saved) }
            return .confirmed(confirmed)
        case .connecting, .reconnecting, .restoringSelection: return .confirming(saved: saved)
        case .offline: return .unavailable(.offline, saved: saved)
        case .failed: return .unavailable(.failed, saved: saved)
        case .noAllowedTargets: return .unavailable(.noAllowedTargets, saved: saved)
        case .waitingForTargets: return .unavailable(.waitingForTargets, saved: saved)
        case .selectionFailed: return .unavailable(.selectionFailed, saved: saved)
        case .unconfigured, .chooseTarget: return .none
        }
    }

    /// Whether talk may address a destination. Only a confirmed destination is; the dock reads this, it is not a
    /// switch.
    public var talkReady: Bool {
        if case .confirmed = self { return true }
        return false
    }

    /// The state first: the confirmed target, or what is happening instead.
    public var primaryText: String {
        switch self {
        case .confirmed(let label): "\(label.role) · \(label.targetName)"
        case .confirming: "Confirming…"
        case .unavailable(let reason, _): "Unavailable: \(reason.text)"
        case .none: "Choose a destination"
        }
    }

    /// Secondary: the confirmed Mac, or a saved destination marked as not confirmed.
    public var secondaryText: String? {
        switch self {
        case .confirmed(let label): "Mac · \(label.hostName)"
        case .confirming(let saved), .unavailable(_, let saved): saved.map { "Saved · not confirmed: \($0.summary)" }
        case .none: "Mac and target"
        }
    }

    public var accessibilityValue: String {
        switch self {
        case .confirmed(let label): "Destination: \(label.summary)."
        case .confirming(let saved): "Confirming destination." + Self.savedSuffix(saved)
        case .unavailable(let reason, let saved): "Destination unavailable: \(reason.text)." + Self.savedSuffix(saved)
        case .none: "No destination. Choose a destination."
        }
    }

    private static func savedSuffix(_ saved: DestinationLabel?) -> String {
        saved.map { " Saved, not confirmed: \($0.summary)." } ?? ""
    }
}
