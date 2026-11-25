import HailCore

/// The Talk owner's current status. Display copy and evidence about the request travel together.
enum StationTalkStatus: Equatable, Sendable {
    case ready
    case message(String)
    case turn(TurnOutcome, text: String)
    case sendFailed(String)
    case notSent(TalkSendRefusal)

    static let destinationChanged = Self.notSent(.destinationChanged)

    var text: String {
        switch self {
        case .ready: "Ready"
        case .notSent(let reason): reason.message
        case .message(let text), .turn(_, let text), .sendFailed(let text): text
        }
    }

    func outcome(pasteFailure: TurnOutcome? = nil) -> TurnOutcome? {
        switch self {
        case .ready:
            if case .refused = pasteFailure { pasteFailure } else { nil }
        case .message: nil
        case .turn(let outcome, _): outcome
        case .notSent(.destinationChanged): .notSent(reason: "the destination changed")
        // A transport failure by itself cannot prove that the request never left this device.
        case .sendFailed: pasteFailure ?? .sentUnverified
        }
    }
}

@MainActor
extension TranscriptionLabView {
    func refuseRecording(_ reason: TalkSendRefusal) {
        talkStatus = .notSent(reason)
        if isForcedTeardown || route?.selected() == nil { route?.reportRemoval(reason) }
    }
}
