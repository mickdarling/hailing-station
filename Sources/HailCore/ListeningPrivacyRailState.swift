/// The privacy state the rail reads (#1115): the host has no privacy switch, or the switch's own status.
public enum RailPrivacy: Equatable, Sendable {
    /// The host takes no privacy switch, so everything heard is sent.
    case unsupported
    case status(PrivacySwitchStatus)
}

/// The listening run's own connection trouble (#904), from `AmbientListeningReconnect`.
public enum RailConnection: Equatable, Sendable {
    /// The run is reconnecting (`isPending`).
    case reconnecting
    /// The run stopped. `reason` is the notice's own text.
    case stopped(reason: String)
}

/// What the listening/privacy rail shows (#1115). It is a reading of the owners' state: it never starts, stops or
/// changes listening, privacy, a target or a route.
///
/// The local microphone (`MicLiveState` from #1149) is the truth. A host claim that nothing is captured never clears
/// a microphone that isn't off, and every unknown input fails safe to "Recording may be on". The first matching row
/// wins (Jarvis, PR 4 plan):
///
/// | # | Microphone | Privacy, station and host                                      | Kind                 | Tone    |
/// |---|------------|----------------------------------------------------------------|----------------------|---------|
/// | 1 | not off    | listening paused (another app has the microphone)              | `paused`             | alert   |
/// | 2 | not off    | privacy unknown, pending or unconfirmed; station not ready;    | `mayBeRecording`     | alert   |
/// |   |            | host claims not capturing (moved away, elsewhere, stopped,     |                      |         |
/// |   |            | private listening unavailable); or the run is reconnecting     |                      |         |
/// | 3 | not off    | confirmed private on a ready station                           | `privateConfirmed`   | private |
/// | 4 | live       | confirmed not private or unsupported, ready, and listening     | `recording`          | alert   |
/// | 5 | not off    | any other confirmed not private or unsupported                 | `mayBeRecording`     | alert   |
/// | 6 | off        | confirmed private, then the host stopped listening             | `privateUnavailable` | private |
/// | 7 | off        | listening moved to another device                              | `elsewhere`          | neutral |
/// | 8 | off        | the run is reconnecting or stopped                             | `interrupted`        | neutral |
/// | 9 | off        | anything else                                                  | `off`                | neutral |
///
/// "Not off" is `.live`, `.uncertain` or unknown. A microphone reported off while the listening switch is on is a
/// contradiction and reads as uncertain. "Off" is about this device only: it never says the Mac or another device
/// stopped capturing.
public struct ListeningPrivacyRailState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paused, mayBeRecording, privateConfirmed, recording, privateUnavailable, elsewhere, interrupted, off
    }

    public enum Tone: Equatable, Sendable {
        case alert, `private`, neutral
    }

    public let kind: Kind
    /// The microphone as the rail's glyph shows it. Privacy never hides the red.
    public let mic: MicLiveState
    public let summary: String
    public let detail: String

    public var tone: Tone {
        switch kind {
        case .paused, .mayBeRecording, .recording: .alert
        case .privateConfirmed, .privateUnavailable: .private
        case .elsewhere, .interrupted, .off: .neutral
        }
    }

    /// VoiceOver reads the full detail, not just the compact summary.
    public var accessibilityLabel: String { "\(summary). \(detail)" }

    /// What a change must alter to be announced: the kind alone, so a wording change within a kind stays quiet.
    public var announcementKey: Kind { kind }

    static let offDetail = "This device isn't capturing audio. That doesn't show whether the Mac or another "
        + "device is."
    static let unsupportedDetail = "This Mac has no privacy mode, so everything heard is sent."

    public static func resolve(
        mic reported: MicLiveState?, listening: StationMenuStatus.Listening?, privacy: RailPrivacy?,
        handoff: AmbientHandoff?, availability: StationAvailability, connection: RailConnection?
    ) -> Self {
        let facts = Facts(mic: reported, listening: listening, privacy: privacy, handoff: handoff,
                          ready: availability == .ready, connection: connection)
        return facts.mic == .off ? micOff(facts) : micNotOff(facts)
    }

    /// The inputs reduced to what the table's rows test.
    private struct Facts {
        let mic: MicLiveState
        let listening: StationMenuStatus.Listening?
        let privacy: RailPrivacy?
        let status: PrivacySwitchStatus?
        let ready: Bool
        let connection: RailConnection?
        /// Set when listening moved to another device; its value is that device's class, if known.
        let movedTo: String??

        init(mic reported: MicLiveState?, listening: StationMenuStatus.Listening?, privacy: RailPrivacy?,
             handoff: AmbientHandoff?, ready: Bool, connection: RailConnection?) {
            mic = switch reported {
            case .off?: listening?.isOn == true ? .uncertain : .off
            case let state?: state
            case nil: .uncertain
            }
            self.listening = listening
            self.privacy = privacy
            status = if case .status(let value)? = privacy { value } else { nil }
            self.ready = ready
            self.connection = connection
            movedTo = switch (handoff, listening) {
            case (.movedAway(let kind)?, _): .some(kind)
            case (_, .elsewhere?): .some(nil)
            default: nil
            }
        }

        var privateListeningUnavailable: Bool { status?.shown == .privateListeningUnavailable }
        var hostClaimsNotCapturing: Bool { movedTo != nil || privateListeningUnavailable || connection != nil }
        /// The host has no switch, or the switch shows a confirmed state with no tap waiting.
        var privacyKnown: Bool {
            if privacy == .unsupported { return true }
            guard let status, !status.pending else { return false }
            return status.shown == .confirmedPrivate || status.shown == .confirmedNotPrivate
        }
        var micWording: String { mic == .live ? "The microphone is on" : "The microphone may be on" }
    }

    /// Rows 1 to 5.
    private static func micNotOff(_ facts: Facts) -> Self {
        let mic = facts.mic
        if facts.listening == .paused {
            return Self(kind: .paused, mic: mic, summary: "Listening paused · resumes by itself",
                        detail: "Another app has the microphone. Listening resumes when it lets go.")
        }
        if !facts.privacyKnown || !facts.ready || facts.hostClaimsNotCapturing {
            return Self(kind: .mayBeRecording, mic: mic, summary: "Recording may be on",
                        detail: "\(facts.micWording), and privacy isn't confirmed on a ready connection.")
        }
        if facts.status?.shown == .confirmedPrivate {
            return Self(kind: .privateConfirmed, mic: mic,
                        summary: mic == .live ? "Private · mic on for its name" : "Private · mic may be on",
                        detail: "\(facts.micWording). The Mac confirmed privacy and is only listening for its name.")
        }
        let extra = facts.privacy == .unsupported ? " " + unsupportedDetail : ""
        if mic == .live, facts.listening == .listening {
            return Self(kind: .recording, mic: mic, summary: "Listening · recording",
                        detail: "The microphone is on and the Mac is recording and sending requests." + extra)
        }
        return Self(kind: .mayBeRecording, mic: mic, summary: "Recording may be on",
                    detail: "\(facts.micWording), and privacy is off." + extra)
    }

    /// Rows 6 to 9.
    private static func micOff(_ facts: Facts) -> Self {
        if facts.privateListeningUnavailable {
            return Self(kind: .privateUnavailable, mic: .off, summary: "Privacy on · listening unavailable",
                        detail: facts.status?.detail ?? offDetail)
        }
        if let movedTo = facts.movedTo {
            let place = AmbientHandoff.deviceName(movedTo) ?? "another device"
            return Self(kind: .elsewhere, mic: .off, summary: "Listening on \(place)",
                        detail: "Listening moved to \(place). " + offDetail)
        }
        switch facts.connection {
        case .reconnecting?:
            return Self(kind: .interrupted, mic: .off, summary: "Reconnecting…",
                        detail: "The connection dropped and listening is reconnecting. " + offDetail)
        case .stopped(let reason)?:
            let sentence = reason.hasSuffix(".") ? reason : reason + "."
            return Self(kind: .interrupted, mic: .off, summary: "Listening stopped", detail: "\(sentence) " + offDetail)
        case nil:
            return Self(kind: .off, mic: .off, summary: "Not listening on this device", detail: offDetail)
        }
    }
}
