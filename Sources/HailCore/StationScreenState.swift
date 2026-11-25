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
        if finishing {
            self = .finishing
        } else if recording {
            self = .recording
        } else {
            self = starting ? .starting : .idle
        }
    }
}
