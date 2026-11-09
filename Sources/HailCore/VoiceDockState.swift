/// What the talk owner reports for the voice dock (#1115). The dock reads it and never re-derives it.
public struct TalkActivity: Equatable, Sendable {
    /// The owner's capture phase, or unknown when no talk owner has reported.
    public var phase: TalkCapturePhase?
    /// A request is sending or waiting for its reply (the owner's `pendingSendID`).
    public var sendPending: Bool
    /// An Escape is under way (the owner's `isInterrupting` or `interruptTask`). The owner is stopping any capture.
    public var interrupting: Bool

    public init(phase: TalkCapturePhase?, sendPending: Bool, interrupting: Bool) {
        (self.phase, self.sendPending, self.interrupting) = (phase, sendPending, interrupting)
    }
}

/// Which of the dock's other controls the owners offer (#1115). Offering one grants the dock nothing: each control
/// only asks its owner.
public struct DockAccessories: Equatable, Sendable {
    /// The talk owner can send Escape (its `onEscape`).
    public var escape: Bool
    /// The host has a privacy switch.
    public var privacy: Bool
    /// The talk owner takes pasted text with its next request.
    public var paste: Bool

    public init(escape: Bool, privacy: Bool, paste: Bool) {
        (self.escape, self.privacy, self.paste) = (escape, privacy, paste)
    }
}

/// What a dock control asks its owner to do (#1115). There is no pause: Escape is never reply pause.
public enum VoiceDockIntent: Equatable, Sendable {
    case talk, finish, paste, privacy, escape, audioRoutes, listeningControls
}

/// What the voice dock shows (#1115). It is a reading of the talk owner's state and the destination control's: it
/// never starts, finishes or discards a capture, sends anything, or changes a target, privacy or a route.
///
/// The primary button keeps one place. The first matching row wins (Jarvis, PR 5 plan):
///
/// | # | Talk                              | Destination   | Primary                              | Enabled |
/// |---|-----------------------------------|---------------|--------------------------------------|---------|
/// | 1 | unknown                           | any           | "Talk unavailable"                   | no      |
/// | 2 | recording, no Escape under way    | any           | "Finish & send"; "Finish" if not     | yes     |
/// |   |                                   |               | confirmed                            |         |
/// | 3 | an Escape is under way            | any           | "Interrupting…"                      | no      |
/// | 4 | starting                          | any           | "Starting…"                          | no      |
/// | 5 | finishing                         | any           | "Finishing…"                         | no      |
/// | 6 | idle, a request pending           | any           | "Tap to talk"                        | no      |
/// | 7 | idle                              | not confirmed | "Talk unavailable"                   | no      |
/// | 8 | idle                              | confirmed     | "Tap to talk"                        | yes     |
///
/// Recording never traps the microphone open: Finish stays enabled unless an Escape is under way, and that Escape
/// is already stopping the capture and discarding it. A Finish in that window would send what Escape discards, so
/// it stays disabled, as the owner's talk button does today. Rows 4 to 6 match that button too. Escape is offered
/// only by its owner, and is disabled only while finishing or while an Escape is under way; an unknown talk phase
/// keeps it. Paste is disabled while a request is pending, as the owner's paste button is.
public struct VoiceDockState: Equatable, Sendable {
    public enum Primary: Equatable, Sendable {
        case talk, finish, starting, finishing, interrupting, unavailable
    }

    /// Whether a secondary control shows, and whether it can be used.
    public enum Item: Equatable, Sendable {
        case hidden, disabled, enabled
    }

    public let primary: Primary
    public let label: String
    public let symbol: String
    public let isEnabled: Bool
    /// The accessibility value: the destination, or why the button can't be used.
    public let value: String
    public let hint: String
    /// The live caption shows only while a capture is active, so the dock grows only then.
    public let showsCaption: Bool
    public let escape: Item
    public let privacy: Item
    public let paste: Item

    /// What the primary button asks for, or nothing while it is disabled.
    public var primaryIntent: VoiceDockIntent? {
        guard isEnabled else { return nil }
        return primary == .finish ? .finish : .talk
    }

    public static func resolve(
        talk: TalkActivity, destination: DestinationControlState, accessories: DockAccessories
    ) -> Self {
        let phase = talk.phase
        let escapeBusy = phase == .finishing || talk.interrupting
        return Self(
            button: primaryButton(talk: talk, destination: destination),
            showsCaption: phase.map { $0 != .idle } ?? false,
            escape: item(offered: accessories.escape, usable: !escapeBusy),
            privacy: item(offered: accessories.privacy, usable: true),
            paste: item(offered: accessories.paste, usable: !talk.sendPending))
    }

    private static func item(offered: Bool, usable: Bool) -> Item {
        guard offered else { return .hidden }
        return usable ? .enabled : .disabled
    }

    private struct PrimaryButton {
        let primary: Primary
        let label: String
        let symbol: String
        let isEnabled: Bool
        let value: String
        var hint = ""
    }

    private init(button: PrimaryButton, showsCaption: Bool, escape: Item, privacy: Item, paste: Item) {
        (primary, label, symbol, isEnabled) = (button.primary, button.label, button.symbol, button.isEnabled)
        (value, hint) = (button.value, button.hint)
        (self.showsCaption, self.escape, self.privacy, self.paste) = (showsCaption, escape, privacy, paste)
    }

    /// Rows 1 to 5, then rows 6 to 8.
    private static func primaryButton(talk: TalkActivity, destination: DestinationControlState) -> PrimaryButton {
        let place = destination.accessibilityValue
        guard let phase = talk.phase else {
            return PrimaryButton(primary: .unavailable, label: "Talk unavailable", symbol: "mic.slash",
                                 isEnabled: false, value: "The talk state isn't known.")
        }
        if phase == .recording, !talk.interrupting {
            let sends = destination.talkReady
            return PrimaryButton(primary: .finish, label: sends ? "Finish & send" : "Finish", symbol: "stop.fill",
                                 isEnabled: true, value: place,
                                 hint: sends ? "Stops listening and sends the request."
                                     : "Stops listening. The destination isn't confirmed.")
        }
        if talk.interrupting {
            return PrimaryButton(primary: .interrupting, label: "Interrupting…", symbol: "xmark.octagon",
                                 isEnabled: false, value: "Escape is discarding any capture.")
        }
        switch phase {
        case .starting:
            return PrimaryButton(primary: .starting, label: "Starting…", symbol: "mic.fill", isEnabled: false,
                                 value: place)
        case .finishing, .recording: // Recording reaches here only with an Escape under way, handled above.
            return PrimaryButton(primary: .finishing, label: "Finishing…", symbol: "stop.fill", isEnabled: false,
                                 value: place)
        case .idle:
            return idleButton(talk: talk, destination: destination)
        }
    }

    /// Rows 6 to 8.
    private static func idleButton(talk: TalkActivity, destination: DestinationControlState) -> PrimaryButton {
        if talk.sendPending {
            return PrimaryButton(primary: .talk, label: "Tap to talk", symbol: "mic.fill", isEnabled: false,
                                 value: "The last request is still pending.")
        }
        guard destination.talkReady else {
            return PrimaryButton(primary: .unavailable, label: "Talk unavailable", symbol: "mic.slash",
                                 isEnabled: false, value: destination.accessibilityValue)
        }
        return PrimaryButton(primary: .talk, label: "Tap to talk", symbol: "mic.fill", isEnabled: true,
                             value: destination.accessibilityValue,
                             hint: "Starts listening. Tap again to finish and send.")
    }
}
