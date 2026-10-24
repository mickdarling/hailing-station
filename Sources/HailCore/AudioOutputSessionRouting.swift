#if os(iOS)
import AVFoundation
import Foundation

/// AVFoundation translation and effects only; the shared pure policy owns the decisions (#852).
@MainActor
enum AudioOutputSessionRouting {
    private static let ports: [AVAudioSession.Port: AudioOutputRoutePolicy.Port] = [
        .builtInSpeaker: .speaker, .builtInReceiver: .receiver, .builtInMic: .builtInMic,
        .bluetoothA2DP: .bluetoothA2DP, .bluetoothLE: .bluetoothLE, .bluetoothHFP: .bluetoothHFP,
        .headphones: .headphones, .usbAudio: .usbAudio, .lineOut: .lineOut,
        .airPlay: .airPlay, .carAudio: .carAudio
    ]

    static func configure(_ session: AVAudioSession, allowsBluetoothHFP: Bool) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if allowsBluetoothHFP { options.insert(.allowBluetoothHFP) }
        let desired = AudioOutputRoutePolicy.configurationOptions(
            outputs: portTypes(session.currentRoute.outputs), options: policyOptions(options)
        )
        try session.setCategory(.playAndRecord, mode: .default, options: applying(desired, to: options))
    }

    static func route(_ session: AVAudioSession, notification: Notification) -> AudioOutputRoutePolicy.Route {
        let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let current = session.currentRoute
        let category: AudioOutputRoutePolicy.Category = session.category == .playAndRecord ? .playAndRecord
            : (session.category == .playback ? .playback : .other)
        return AudioOutputRoutePolicy.Route(
            category: category, options: policyOptions(session.categoryOptions),
            outputs: portTypes(current.outputs), inputs: portTypes(current.inputs),
            previousOutputs: portTypes(previous?.outputs ?? []),
            previousInputs: portTypes(previous?.inputs ?? []), reason: reason(raw)
        )
    }

    static func apply(_ decision: AudioOutputRoutePolicy.Decision, to session: AVAudioSession) throws {
        let options = applying(decision.options, to: session.categoryOptions)
        // Clearing a speaker override lets iOS choose its normal external route; it cannot select an arbitrary
        // output port. Reapply without defaultToSpeaker even if the category already matches (#852).
        if options != session.categoryOptions || decision.clearOverride {
            try session.setCategory(session.category, mode: session.mode, options: options)
        }
        if decision.clearOverride { try session.overrideOutputAudioPort(.none) }
    }

    private static func portTypes(_ descriptions: [AVAudioSessionPortDescription]) -> [AudioOutputRoutePolicy.Port] {
        descriptions.map { ports[$0.portType] ?? .other }
    }

    private static func policyOptions(_ options: AVAudioSession.CategoryOptions) -> AudioOutputRoutePolicy.Options {
        .init(defaultToSpeaker: options.contains(.defaultToSpeaker), mixWithOthers: options.contains(.mixWithOthers))
    }

    private static func applying(
        _ desired: AudioOutputRoutePolicy.Options, to options: AVAudioSession.CategoryOptions
    ) -> AVAudioSession.CategoryOptions {
        var result = options
        if desired.defaultToSpeaker { result.insert(.defaultToSpeaker) } else { result.remove(.defaultToSpeaker) }
        return result
    }

    private static func reason(_ raw: UInt) -> AudioOutputRoutePolicy.Reason {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: .newDeviceAvailable
        case .oldDeviceUnavailable: .oldDeviceUnavailable
        case .override: .override
        case .categoryChange: .categoryChange
        case .routeConfigurationChange: .routeConfigurationChange
        default: .other
        }
    }
}
#endif
