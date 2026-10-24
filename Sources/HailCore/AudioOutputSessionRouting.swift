#if os(iOS)
import AVFoundation
import Foundation

/// AVFoundation translation and effects only; the shared pure policy owns the decisions (#852).
@MainActor
enum AudioOutputSessionRouting {
    struct Snapshot: Sendable {
        let reasonRaw: UInt
        let previousInputs: [AudioOutputRoutePolicy.Port]
        let previousOutputs: [AudioOutputRoutePolicy.Port]
    }

    nonisolated static func snapshot(_ notification: Notification) -> Snapshot {
        let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        return Snapshot(
            reasonRaw: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0,
            previousInputs: portTypes(previous?.inputs ?? []), previousOutputs: portTypes(previous?.outputs ?? [])
        )
    }

    static func configure(_ session: AVAudioSession, allowsBluetoothHFP: Bool) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if allowsBluetoothHFP { options.insert(.allowBluetoothHFP) }
        let desired = AudioOutputRoutePolicy.configurationOptions(
            outputs: portTypes(session.currentRoute.outputs), options: policyOptions(options)
        )
        try session.setCategory(.playAndRecord, mode: .default, options: applying(desired, to: options))
    }

    static func route(_ session: AVAudioSession, snapshot: Snapshot) -> AudioOutputRoutePolicy.Route {
        let current = session.currentRoute
        let category: AudioOutputRoutePolicy.Category = session.category == .playAndRecord ? .playAndRecord
            : (session.category == .playback ? .playback : .other)
        return AudioOutputRoutePolicy.Route(
            category: category, options: policyOptions(session.categoryOptions),
            outputs: portTypes(current.outputs), inputs: portTypes(current.inputs),
            previousOutputs: snapshot.previousOutputs,
            previousInputs: snapshot.previousInputs, reason: reason(snapshot.reasonRaw)
        )
    }

    static func apply(_ effect: AudioOutputRouteDriver.Effect, to session: AVAudioSession) throws {
        switch effect {
        case .setCategory(let desired):
            try session.setCategory(
                session.category, mode: session.mode, options: applying(desired, to: session.categoryOptions)
            )
        case .clearOverride:
            try session.overrideOutputAudioPort(.none)
        }
    }

    nonisolated private static func portTypes(
        _ descriptions: [AVAudioSessionPortDescription]
    ) -> [AudioOutputRoutePolicy.Port] {
        let ports: [AVAudioSession.Port: AudioOutputRoutePolicy.Port] = [
            .builtInSpeaker: .speaker, .builtInReceiver: .receiver, .builtInMic: .builtInMic,
            .bluetoothA2DP: .bluetoothA2DP, .bluetoothLE: .bluetoothLE, .bluetoothHFP: .bluetoothHFP,
            .headphones: .headphones, .usbAudio: .usbAudio, .lineOut: .lineOut,
            .airPlay: .airPlay, .carAudio: .carAudio
        ]
        return descriptions.map { ports[$0.portType] ?? .other }
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
