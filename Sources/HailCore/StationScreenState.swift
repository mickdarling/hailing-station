/// Read-only projections shared by the Station header, microphone rail, dock and recovery sheet.
extension StationAvailability {
    public var connectionLabel: String {
        switch self {
        case .ready, .chooseTarget, .noAllowedTargets, .waitingForTargets, .restoringSelection, .selectionFailed:
            "Connected"
        case .unconfigured: "No Mac configured"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection failed"
        case .offline: "Offline"
        }
    }
}

extension TalkCapturePhase {
    public init(starting: Bool, recording: Bool, finishing: Bool) {
        if finishing { self = .finishing } else if recording { self = .recording } else if starting {
            self = .starting
        } else { self = .idle }
    }
}

extension TurnOutcome {
    /// Only owner-reported outcomes. An error writing to the transport may follow partial delivery.
    public static func observed(status: String) -> Self? {
        switch status {
        case "Sending…": .sending
        case "Waiting for reply…": .waitingForReply
        case "No reply yet — tap to talk again": .noReplyYet
        case "Reply received": .replyReceived
        case "Reply received — turn unverified", "Sent — reply turn unverified": .sentUnverified
        case "Destination changed — request not sent": .notSent(reason: status)
        default: status.hasPrefix("Send failed:") ? .sentUnverified : nil
        }
    }
}
