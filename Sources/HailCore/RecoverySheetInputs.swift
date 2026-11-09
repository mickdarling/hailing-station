/// What happened to the last request, as the talk owner knows it (#1115). The recovery sheet reads it; it never
/// retries, resends or clears anything.
///
/// Mapping rule for the adopting owner (Jarvis, PR 7 plan): `.notSent` is only for a request the owner knows never
/// left this device: the destination changed before it was sent, or the owner refused it before any input. A
/// transport failure after the request may have left the device is `.sentUnverified`, never `.notSent`.
public enum TurnOutcome: Equatable, Sendable {
    case sending
    case waitingForReply
    /// The owner's reply wait ended with no reply. Nothing was resent.
    case noReplyYet
    /// The request may have reached the Mac, but whether it was taken isn't known.
    case sentUnverified
    case replyReceived
    /// The request never left this device, with the owner's reason.
    case notSent(reason: String)
    /// The Mac refused the request before typing it (#608, #894), with its reason.
    case refused(reason: String)
}

/// What the recovery sheet can ask for (#1115): a look or a choice, never recovery itself, which #1002 owns.
public enum RecoveryIntent: Hashable, Sendable {
    case inspectConnection
    case chooseDestination
    case openListening
}

/// One observed step back to a working station (#1115).
public struct RecoveryStep: Equatable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case connection, destination, mode, capture
    }

    public enum State: Equatable, Sendable {
        case confirmed, waiting, failed, notApplicable
    }

    public let id: Kind
    public let state: State
    public let text: String

    public var title: String {
        switch id {
        case .connection: "Connection"
        case .destination: "Destination"
        case .mode: "Privacy mode"
        case .capture: "Listening"
        }
    }
}
