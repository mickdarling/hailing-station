/// What the recovery sheet shows (#1115): the observed status first, then the last request, then a targeted next
/// step. It is a reading of the owners' state and has no recovery authority: it never retries, resends, flushes,
/// interrupts, restarts or clears text. #1002 owns recovery.
///
/// - Each step is confirmed, waiting, failed or not applicable, from what the station observes. Privacy that is
///   unknown, pending, unconfirmed or unavailable is never confirmed, and a confirmed mode always names itself.
/// - "Restored" needs every applicable step confirmed and no request in doubt. With the steps confirmed but the last
///   request unanswered, unverified, unsent or refused, it reads "Connection restored" and the request stays
///   prominent (Jarvis, PR 7 plan).
/// - Only a request the owner knows never left this device says nothing was sent (see `TurnOutcome`).
public struct RecoverySheetState: Equatable, Sendable {
    public let header: String
    public let steps: [RecoveryStep]
    /// The last request, or nil when there is none to report.
    public let request: String?
    /// Whether the last request needs a look on the Mac, so the sheet shows it prominently.
    public let requestNeedsAttention: Bool
    public let nextStep: String?
    public let intents: [RecoveryIntent]

    static let promptLine = "Hailing Station didn't change any text already in the Mac's prompt."
    static let unsupportedMode = "This Mac has no privacy mode, so everything heard is sent."

    public var isRestored: Bool { header == "Restored" }

    /// `wasListening` says whether ambient listening was on before the trouble, so its return matters.
    public static func resolve(
        availability: StationAvailability, destination: DestinationControlState, privacy: RailPrivacy?,
        listening: (current: StationMenuStatus.Listening?, wasOn: Bool), turn: TurnOutcome?
    ) -> Self {
        let chosen = destinationStep(destination)
        let capture = captureStep(listening.current, wasOn: listening.wasOn)
        let steps = [connectionStep(availability), chosen, modeStep(privacy), capture]
        let attention = turn.map(needsAttention) ?? false
        let applicable = steps.filter { $0.state != .notApplicable }
        let header = if applicable.contains(where: { $0.state == .failed }) {
            "Needs attention"
        } else if applicable.allSatisfy({ $0.state == .confirmed }) {
            attention || !settled(turn) ? "Connection restored" : "Restored"
        } else {
            "Restoring…"
        }
        var intents: [RecoveryIntent] = [.inspectConnection]
        if chosen.state != .confirmed { intents.append(.chooseDestination) }
        if capture.state == .waiting || capture.state == .failed { intents.append(.openListening) }
        return Self(header: header, steps: steps, request: turn.map(requestText), requestNeedsAttention: attention,
                    nextStep: turn.flatMap(nextStepText), intents: intents)
    }

    private static func needsAttention(_ turn: TurnOutcome) -> Bool {
        switch turn {
        case .noReplyYet, .sentUnverified, .notSent, .refused: true
        case .sending, .waitingForReply, .replyReceived: false
        }
    }

    /// No request, or one that was answered: only then can the station read as restored.
    private static func settled(_ turn: TurnOutcome?) -> Bool { turn == nil || turn == .replyReceived }

    private static func connectionStep(_ availability: StationAvailability) -> RecoveryStep {
        let (state, text): (RecoveryStep.State, String) = switch availability {
        case .ready, .chooseTarget, .waitingForTargets, .noAllowedTargets, .selectionFailed, .restoringSelection:
            (.confirmed, "Connected to the Mac.")
        case .connecting: (.waiting, "Connecting…")
        case .reconnecting: (.waiting, "Reconnecting…")
        case .offline: (.failed, "The Mac is offline.")
        case .failed: (.failed, "The connection failed.")
        case .unconfigured: (.failed, "No Mac is set up.")
        }
        return RecoveryStep(id: .connection, state: state, text: text)
    }

    private static func destinationStep(_ destination: DestinationControlState) -> RecoveryStep {
        let state: RecoveryStep.State = switch destination {
        case .confirmed: .confirmed
        case .confirming, .unavailable(.waitingForTargets, _): .waiting
        case .unavailable, .none: .failed
        }
        return RecoveryStep(id: .destination, state: state, text: destination.primaryText)
    }

    private static func modeStep(_ privacy: RailPrivacy?) -> RecoveryStep {
        guard let privacy else { return RecoveryStep(id: .mode, state: .waiting, text: "Not reported yet.") }
        guard case .status(let status) = privacy else {
            return RecoveryStep(id: .mode, state: .confirmed, text: unsupportedMode)
        }
        if status.pending { return RecoveryStep(id: .mode, state: .waiting, text: "A privacy change is pending.") }
        let (state, text): (RecoveryStep.State, String) = switch status.shown {
        case .confirmedPrivate: (.confirmed, "Private: the Mac confirmed privacy.")
        case .confirmedNotPrivate: (.confirmed, "Privacy is off, so what's heard is sent.")
        case .unconfirmed: (.waiting, "Privacy isn't confirmed.")
        case .privateListeningUnavailable: (.failed, "Privacy is on, but listening is unavailable.")
        }
        return RecoveryStep(id: .mode, state: state, text: text)
    }

    private static func captureStep(_ listening: StationMenuStatus.Listening?, wasOn: Bool) -> RecoveryStep {
        guard wasOn else { return RecoveryStep(id: .capture, state: .notApplicable, text: "Listening was off.") }
        let (state, text): (RecoveryStep.State, String) = switch listening {
        case .listening?: (.confirmed, "Listening again.")
        case .starting?: (.waiting, "Starting to listen…")
        case .paused?: (.waiting, "Paused: another app has the microphone.")
        case .elsewhere?: (.failed, "Listening moved to another device.")
        case .off?: (.failed, "Listening stopped.")
        case nil: (.waiting, "Not reported yet.")
        }
        return RecoveryStep(id: .capture, state: state, text: text)
    }

    private static func requestText(_ turn: TurnOutcome) -> String {
        switch turn {
        case .sending: "Sending the last request…"
        case .waitingForReply: "The last request was sent. Waiting for its reply."
        case .noReplyYet: "The last request was sent. No reply has arrived, and nothing was resent."
        case .sentUnverified: "The last request may have reached the Mac. Whether it was taken isn't confirmed."
        case .replyReceived: "A reply arrived for the last request."
        case .notSent(let reason): "Nothing was sent: \(sentence(reason)) \(promptLine)"
        case .refused(let reason): "The Mac refused the last request: \(sentence(reason)) \(promptLine)"
        }
    }

    private static func nextStepText(_ turn: TurnOutcome) -> String? {
        switch turn {
        case .noReplyYet, .sentUnverified: "Check the session on the Mac before talking again."
        case .notSent, .refused: "Check the Mac before talking again."
        case .sending, .waitingForReply, .replyReceived: nil
        }
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}
