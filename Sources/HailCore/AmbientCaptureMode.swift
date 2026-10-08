#if os(iOS)
public import AVFAudio
#endif

/// How ambient listening captures the microphone (#343).
/// - `voiceProcessing`: Apple's voice-processing I/O, with replies played through the capture engine so its echo
///   canceller removes them (#269). It needs a duplex route, so with Bluetooth HFP off it holds the session on the
///   built-in mic and speaker: AirPods connected over A2DP got no audio at all while it ran.
/// - `plain`: engine capture without voice processing. Output stays on the headphones' A2DP route, replies play on
///   the player's own engine, and the echo guard silences the mic while a reply is audible (#227).
public enum AmbientCaptureMode: String, Sendable, Equatable, CaseIterable {
    case voiceProcessing = "vpio"
    case plain
}

/// The kind of an output port, as far as echo matters: can the microphone hear it?
public enum AudioOutputKind: Sendable, Equatable, CaseIterable {
    case builtInSpeaker, builtInReceiver
    case wiredHeadphones, bluetoothA2DP, bluetoothLE
    /// A duplex Bluetooth route. Car hands-free kits use it too, so it is not treated as headphones.
    case bluetoothHFP
    case airPlay, carAudio, hdmi, usb, lineOut, other

    /// Outputs that play into the listener's ears rather than the room.
    var isPrivateListening: Bool {
        switch self {
        case .wiredHeadphones, .bluetoothA2DP, .bluetoothLE: true
        default: false
        }
    }
}

public enum AmbientCaptureModeResolver {
    /// Plain capture only when every output plays into the listener's ears, so no reply can reach the mic through
    /// the room. Anything else, including an unknown or empty route, keeps voice processing, today's behaviour.
    /// An A2DP car stereo also resolves to plain; the echo guard still silences the mic while replies play.
    public static func mode(for outputs: [AudioOutputKind]) -> AmbientCaptureMode {
        guard !outputs.isEmpty, outputs.allSatisfy(\.isPrivateListening) else { return .voiceProcessing }
        return .plain
    }
}

#if os(iOS)
extension AudioOutputKind {
    init(_ port: AVAudioSession.Port) {
        let kinds: [AVAudioSession.Port: AudioOutputKind] = [
            .builtInSpeaker: .builtInSpeaker, .builtInReceiver: .builtInReceiver, .headphones: .wiredHeadphones,
            .bluetoothA2DP: .bluetoothA2DP, .bluetoothLE: .bluetoothLE, .bluetoothHFP: .bluetoothHFP,
            .airPlay: .airPlay, .carAudio: .carAudio, .HDMI: .hdmi, .usbAudio: .usb, .lineOut: .lineOut
        ]
        self = kinds[port] ?? .other
    }
}

extension AmbientCaptureModeResolver {
    /// The mode for the session's current output route. Read it after the session is active and before voice
    /// processing starts, because voice processing moves the route off A2DP (#343).
    @MainActor
    public static func currentMode(session: AVAudioSession = .sharedInstance()) -> AmbientCaptureMode {
        mode(for: session.currentRoute.outputs.map { AudioOutputKind($0.portType) })
    }
}
#endif
