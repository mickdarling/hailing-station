/// Whether this device's microphone may be capturing for Hailing Station (#334, #1115). The indicator shows it red
/// while recording and also while the state is uncertain; it is clear only when every capture owner positively
/// reports that it is off. It is a reading of the owners' state, never a control: nothing here starts, stops or
/// pauses capture.
public enum MicLiveState: Equatable, Sendable {
    /// A capture owner reports microphone audio flowing now.
    case live
    /// The microphone may be on: an owner is starting, finishing, paused with an automatic resume, or not reporting.
    case uncertain
    /// Every owner reports that it is not capturing.
    case off

    /// Red whenever the microphone may be on, so an uncertain state is never shown as off.
    public var showsRed: Bool { self != .off }

    public var label: String {
        switch self {
        case .live: "Microphone on"
        case .uncertain: "Microphone may be on"
        case .off: "Microphone off"
        }
    }
}

/// The tap-to-talk capture phase, as its owner reports it.
public enum TalkCapturePhase: Equatable, Sendable {
    case idle
    /// Permission, audio session or recognizer start-up: the microphone may already be open.
    case starting
    case recording
    /// The last audio is being finalized; the microphone may still be open.
    case finishing
}

/// This device's own audio engine, read locally: whether microphone input is running in this process.
public enum MicEngineState: Equatable, Sendable {
    case running
    case stopped
    /// The engine can't say (not yet observed, or between owners). Never read as stopped.
    case unknown
}

/// The inputs, one per source. `nil` means the source has not reported, which is never read as off.
///
/// The phases come from this device's capture owners, and some of them reflect what a host said: `elsewhere` is
/// set when the host refuses a segment because another device took listening over (#366). A host report alone
/// must never clear the red, so the local engine is its own input. While it is running or unknown, it wins over
/// any ambient or talk phase: a host saying `elsewhere` or `off` can't turn the indicator off while this device's
/// engine might still be capturing. The indicator is clear only when the engine is stopped and every phase is off.
public struct MicLiveInputs: Equatable, Sendable {
    public var engine: MicEngineState?
    public var ambient: StationMenuStatus.Listening?
    public var talk: TalkCapturePhase?

    public init(engine: MicEngineState?, ambient: StationMenuStatus.Listening?, talk: TalkCapturePhase?) {
        self.engine = engine
        self.ambient = ambient
        self.talk = talk
    }

    /// The most alarming source wins: live over uncertain over off. A source that hasn't reported is uncertain.
    public var state: MicLiveState {
        let states = [engine.map(Self.state(of:)), ambient.map(Self.state(of:)), talk.map(Self.state(of:))]
            .map { $0 ?? .uncertain }
        if states.contains(.live) { return .live }
        if states.contains(.uncertain) { return .uncertain }
        return .off
    }

    private static func state(of engine: MicEngineState) -> MicLiveState {
        switch engine {
        case .running: .live
        case .unknown: .uncertain
        case .stopped: .off
        }
    }

    private static func state(of ambient: StationMenuStatus.Listening) -> MicLiveState {
        switch ambient {
        case .listening: .live
        // A pause (#445) resumes by itself, and start-up may already hold the microphone.
        case .starting, .paused: .uncertain
        // Listening moved to another device (#366), or is off. Clear only if the engine agrees.
        case .elsewhere, .off: .off
        }
    }

    private static func state(of talk: TalkCapturePhase) -> MicLiveState {
        switch talk {
        case .recording: .live
        case .starting, .finishing: .uncertain
        case .idle: .off
        }
    }
}
