import Foundation

/// Placeholder consent wording for the private coaching card (#645). Mick decides the final text; until then
/// every string here is a placeholder and must not be read as settled policy.
public enum PrivateCoachingConsentText {
    /// PLACEHOLDER (Mick's call): participant awareness, confirmed on every Start.
    public static let participantAwareness = "Everyone nearby knows this Mac is listening for coaching."
    /// PLACEHOLDER (Mick's call): shown only when the hosted provider is chosen, confirmed on every Start.
    public static let hostedProvider = "A hosted provider will receive the text of what this Mac hears."
    /// PLACEHOLDER (Mick's call): shown when the setup declares hosted speech recognition or synthesis, which the
    /// advice-provider consent above does not cover. Confirmed on every Start.
    public static let hostedSpeech = "Hosted speech services will receive this Mac's audio or the spoken cues."
    /// PLACEHOLDER (Mick's call): the one-tap check for a Bluetooth or USB output (#604).
    public static let headphoneCheck = "I'm wearing these headphones."
    /// Shown after every sentence above, on screen and to VoiceOver, until Mick settles the wording.
    public static let marker = "(placeholder wording)"

    /// The sentences as the card displays them: each carries the visible placeholder marker.
    public enum Shown {
        public static let participantAwareness = marked(PrivateCoachingConsentText.participantAwareness)
        public static let hostedProvider = marked(PrivateCoachingConsentText.hostedProvider)
        public static let hostedSpeech = marked(PrivateCoachingConsentText.hostedSpeech)
        public static let headphoneCheck = marked(PrivateCoachingConsentText.headphoneCheck)
    }

    static func marked(_ sentence: String) -> String { "\(sentence) \(marker)" }
}

/// Why a coaching run ended, without any of its content. haild prints it after `coaching ended:`.
public enum PrivateCoachingEndReason: String, Sendable, Equatable, CaseIterable {
    case route, stopped, expired, failed

    public init(_ suspension: CoachingSuspension) {
        switch suspension {
        case .routeInvalidated: self = .route
        case .stopped: self = .stopped
        case .qualificationExpired, .adviceExpired: self = .expired
        case .captureEnded, .captureFailed, .playbackFailed: self = .failed
        }
    }
}

/// A content-free line from `haild coaching`. Anything else on the control channel is ignored, never shown.
public enum PrivateCoachingStatusLine: Sendable, Equatable {
    case status(ForegroundCoachingStatus)
    case ended(PrivateCoachingEndReason)

    public init?(_ line: String) {
        if let word = line.droppingPrefix("coaching: ") {
            switch word {
            case "off": self = .status(.off)
            case "starting": self = .status(.starting)
            case "active": self = .status(.active)
            case "retiring": self = .status(.retiring)
            default: return nil
            }
        } else if let word = line.droppingPrefix("coaching ended: "),
                  let reason = PrivateCoachingEndReason(rawValue: word) {
            self = .ended(reason)
        } else {
            return nil
        }
    }
}

private extension String {
    func droppingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// The card's state for one run. A suspension never resumes by itself: the next Start begins a fresh run.
public enum PrivateCoachingCardState: Sendable, Equatable {
    case idle, starting, live, suspendedOnRouteChange, stopped, error

    /// True while a run may hold the microphone or the private output, so ambient capture stays off.
    public var holdsAudio: Bool { self == .starting || self == .live }
    public var canStart: Bool { !holdsAudio }
}

/// Folds the child's status lines and exit into one card state. Pure, so the card and its tests share it.
public struct PrivateCoachingCardModel: Sendable, Equatable {
    public private(set) var state = PrivateCoachingCardState.idle
    private var stopping = false
    private var ended: PrivateCoachingEndReason?

    public init() {}

    public mutating func startRequested() {
        guard state.canStart else { return }
        state = .starting; stopping = false; ended = nil
    }

    public mutating func stopRequested() {
        guard state.holdsAudio else { return }
        stopping = true
    }

    public mutating func received(_ line: PrivateCoachingStatusLine) {
        guard state.holdsAudio else { return }
        switch line {
        case .status(.active): if state == .starting, !stopping { state = .live }
        case .status(.starting), .status(.retiring), .status(.off): break
        case .ended(let reason): ended = reason
        }
    }

    /// The child has exited. Its last end reason decides the state; an unexplained exit while starting or live,
    /// without a Stop, is an error.
    public mutating func childExited() {
        guard state.holdsAudio else { return }
        switch ended {
        case .route: state = .suspendedOnRouteChange
        case .stopped, .expired: state = .stopped // Includes the 15-minute run cap: a normal end, not an error.
        case .failed: state = stopping ? .stopped : .error
        case nil: state = stopping ? .stopped : .error
        }
    }
}

/// How the chosen private output connects. Only the transport class is used, never the device's name.
public enum PrivateCoachingOutputTransport: Sendable, Equatable {
    case builtIn, wired, bluetooth, usb, other

    /// Bluetooth and USB outputs may be speakers that the OS still reports as headphones, so they get the one-tap
    /// check (#604). It is remembered for that device until the user picks another one.
    public func needsHeadphoneCheck(outputKey: String, lastConfirmedKey: String?) -> Bool {
        switch self {
        case .bluetooth, .usb: outputKey != lastConfirmedKey
        case .builtIn, .wired, .other: false
        }
    }
}

/// Everything Start depends on. `blocker` names the first missing thing, in the order the card shows it.
public struct PrivateCoachingStartGate: Sendable, Equatable {
    public enum Blocker: Sendable, Equatable {
        case notIdle, setupMissing, ambientListening, captureActive, noMicrophone, noOutput
        case headphoneCheck, awareness, hostedConsent, hostedSpeechConsent
    }

    public var state: PrivateCoachingCardState
    public var setupReady: Bool
    public var ambientListening: Bool
    public var captureActive: Bool
    public var microphoneChosen: Bool
    public var outputChosen: Bool
    public var headphoneCheckNeeded: Bool
    public var headphonesConfirmed: Bool
    public var awarenessConfirmed: Bool
    public var hostedChosen: Bool
    public var hostedConsentConfirmed: Bool
    public var hostedSpeech: Bool
    public var hostedSpeechConsentConfirmed: Bool

    public init(state: PrivateCoachingCardState, setupReady: Bool, ambientListening: Bool, captureActive: Bool,
                microphoneChosen: Bool, outputChosen: Bool, headphoneCheckNeeded: Bool, headphonesConfirmed: Bool,
                awarenessConfirmed: Bool, hostedChosen: Bool, hostedConsentConfirmed: Bool,
                hostedSpeech: Bool, hostedSpeechConsentConfirmed: Bool) {
        self.state = state; self.setupReady = setupReady
        self.ambientListening = ambientListening; self.captureActive = captureActive
        self.microphoneChosen = microphoneChosen; self.outputChosen = outputChosen
        self.headphoneCheckNeeded = headphoneCheckNeeded; self.headphonesConfirmed = headphonesConfirmed
        self.awarenessConfirmed = awarenessConfirmed
        self.hostedChosen = hostedChosen; self.hostedConsentConfirmed = hostedConsentConfirmed
        self.hostedSpeech = hostedSpeech; self.hostedSpeechConsentConfirmed = hostedSpeechConsentConfirmed
    }

    public var blocker: Blocker? {
        if !state.canStart { return .notIdle }
        if !setupReady { return .setupMissing }
        if ambientListening { return .ambientListening }
        if captureActive { return .captureActive }
        if !microphoneChosen { return .noMicrophone }
        if !outputChosen { return .noOutput }
        if headphoneCheckNeeded, !headphonesConfirmed { return .headphoneCheck }
        if !awarenessConfirmed { return .awareness }
        if hostedChosen, !hostedConsentConfirmed { return .hostedConsent }
        if hostedSpeech, !hostedSpeechConsentConfirmed { return .hostedSpeechConsent }
        return nil
    }
}
