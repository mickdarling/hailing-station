/// What the listening/privacy rail shows (#1115). It is a reading of the owners' state: it never starts, stops or
/// changes listening, privacy, a target or a route.
///
/// The local microphone (`MicLiveState` from #1149) is the truth. A host claim that nothing is captured never clears
/// a microphone that isn't off, and every unknown input fails safe to "Recording may be on". The first matching row
/// wins (Jarvis, PR 4 plan):
///
/// | # | Microphone | Privacy, station and host                                      | Kind                 | Tone    |
/// |---|------------|----------------------------------------------------------------|----------------------|---------|
/// | 1 | not off,   | listening paused (another app has the microphone) and talk not | `paused`             | alert   |
/// |   | not live   | capturing                                                      |                      |         |
/// | 2 | not off    | privacy unknown, pending or unconfirmed; station not ready;    | `mayBeRecording`     | alert   |
/// |   |            | host claims not capturing (moved away, elsewhere, stopped,     |                      |         |
/// |   |            | private listening unavailable); or the run is reconnecting     |                      |         |
/// | 3 | not off    | confirmed private on a ready station, ambient listening on and | `privateConfirmed`   | private |
/// |   |            | talk known idle                                                |                      |         |
/// | 4 | live       | confirmed not private or unsupported; or confirmed private     | `recording`          | alert   |
/// |   |            | while talk is capturing: privacy covers ambient listening only |                      |         |
/// | 5 | not off    | any other: an uncertain microphone, or confirmed private with  | `mayBeRecording`     | alert   |
/// |   |            | talk unknown or ambient listening not on                       |                      |         |
/// | 6 | off        | confirmed private, then the host stopped listening             | `privateUnavailable` | private |
/// | 7 | off        | listening moved to another device                              | `elsewhere`          | neutral |
/// | 8 | off        | the run is reconnecting or stopped                             | `interrupted`        | neutral |
/// | 9 | off        | anything else                                                  | `off`                | neutral |
///
/// "Not off" is `.live`, `.uncertain` or unknown. A microphone reported off while the listening switch is on or talk
/// is capturing is a contradiction and reads as uncertain. Privacy covers ambient listening only: tap-to-talk sends
/// what it captures whatever the privacy switch says (Codex review of #1153). "Off" is about this device only: it
/// never says the Mac or another device stopped capturing.
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
    static let talkDetail = "Privacy covers ambient listening only, so what talk captures is sent."

    /// `mic`, `listening` and `talk` are this device's own truth; `host` holds what the host and station report.
    public static func resolve(
        mic: MicLiveState?, listening: StationMenuStatus.Listening?, talk: TalkCapturePhase?, host: RailHost
    ) -> Self {
        let facts = Facts(mic: mic, listening: listening, talk: talk, host: host)
        return facts.mic == .off ? micOff(facts) : micNotOff(facts)
    }

    /// The inputs reduced to what the table's rows test.
    private struct Facts {
        let mic: MicLiveState
        let listening: StationMenuStatus.Listening?
        let talk: TalkCapturePhase?
        let privacy: RailPrivacy?
        let status: PrivacySwitchStatus?
        let ready: Bool
        let connection: RailConnection?
        /// Set when listening moved to another device; its value is that device's class, if known.
        let movedTo: String??

        init(mic reported: MicLiveState?, listening: StationMenuStatus.Listening?, talk: TalkCapturePhase?,
             host: RailHost) {
            let talkCapturing = talk.map { $0 != .idle } ?? false
            mic = switch reported {
            case .off?: listening?.isOn == true || talkCapturing ? .uncertain : .off
            case let state?: state
            case nil: .uncertain
            }
            self.listening = listening
            self.talk = talk
            privacy = host.privacy
            status = if case .status(let value)? = host.privacy { value } else { nil }
            ready = host.availability == .ready
            connection = host.connection
            movedTo = switch (host.handoff, listening) {
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
        var confirmedPrivate: Bool { status?.shown == .confirmedPrivate }
        /// Talk is starting, recording or finishing. Unknown is not capturing here, and not idle either.
        var talkCapturing: Bool { talk.map { $0 != .idle } ?? false }
        var micWording: String { mic == .live ? "The microphone is on" : "The microphone may be on" }
    }

    /// Rows 1 to 3, then rows 4 and 5.
    private static func micNotOff(_ facts: Facts) -> Self {
        let mic = facts.mic
        // A live microphone or talk capture is never "another app has the microphone" (Codex review of #1153).
        if facts.listening == .paused, mic != .live, !facts.talkCapturing {
            return Self(kind: .paused, mic: mic, summary: "Listening paused · resumes by itself",
                        detail: "Another app has the microphone. Listening resumes when it lets go.")
        }
        if !facts.privacyKnown || !facts.ready || facts.hostClaimsNotCapturing {
            return Self(kind: .mayBeRecording, mic: mic, summary: "Recording may be on",
                        detail: "\(facts.micWording), and privacy isn't confirmed on a ready connection.")
        }
        if facts.confirmedPrivate, facts.talk == .idle, facts.listening == .listening {
            return Self(kind: .privateConfirmed, mic: mic,
                        summary: mic == .live ? "Private · mic on for its name" : "Private · mic may be on",
                        detail: "\(facts.micWording). The Mac confirmed privacy and is only listening for its name.")
        }
        return notCoveredByPrivacy(facts)
    }

    /// Rows 4 and 5: a known privacy state that doesn't cover this capture.
    private static func notCoveredByPrivacy(_ facts: Facts) -> Self {
        let mic = facts.mic
        let extra = switch (facts.privacy, facts.confirmedPrivate) {
        case (.unsupported?, _): " " + unsupportedDetail
        case (_, true): " " + talkDetail
        default: ""
        }
        if mic == .live, !facts.confirmedPrivate || facts.talkCapturing {
            // Recording is certain here, from ambient listening or from talk (Jarvis, PR 4 table review).
            let listeningRecords = !facts.confirmedPrivate && facts.listening == .listening
            return Self(kind: .recording, mic: mic, summary: listeningRecords ? "Listening · recording" : "Recording",
                        detail: (facts.confirmedPrivate ? "The microphone is on for talk." :
                            "The microphone is on and privacy is off, so what it hears is sent.") + extra)
        }
        return Self(kind: .mayBeRecording, mic: mic, summary: "Recording may be on",
                    detail: "\(facts.micWording)" + (facts.confirmedPrivate ? "." : ", and privacy is off.") + extra)
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
