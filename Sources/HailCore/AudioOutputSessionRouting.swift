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

/// Shared decision → effects → result loop used by the iOS backend and macOS scripted tests (#852).
enum AudioOutputRouteDriver {
    enum Effect: Equatable, Sendable {
        case setCategory(AudioOutputRoutePolicy.Options)
        case clearOverride
    }

    @discardableResult
    static func process(
        _ route: AudioOutputRoutePolicy.Route, state: inout AudioOutputRoutePolicy.State,
        observeDecision: (AudioOutputRoutePolicy.Decision) -> Void = { _ in },
        perform: (Effect) throws -> Void
    ) -> Bool {
        let decision = AudioOutputRoutePolicy.routeChange(route, state: state)
        state = decision.state
        observeDecision(decision)
        do {
            try apply(decision, route: route, state: &state, perform: perform)
            if decision.clearOverride { state.restoreAttempted = true }
            return true
        } catch {
            // Failed effects never latch success; the episode guard still absorbs their queued echoes (#852).
            if decision.clearOverride { state.restoreAttempted = false }
            return false
        }
    }

    private static func apply(
        _ decision: AudioOutputRoutePolicy.Decision, route: AudioOutputRoutePolicy.Route,
        state: inout AudioOutputRoutePolicy.State,
        perform: (Effect) throws -> Void
    ) throws {
        if decision.options != route.options || decision.clearOverride {
            state.pendingEchoes.append(.init(reason: .categoryChange, inputs: route.inputs, outputs: route.outputs))
            try perform(.setCategory(decision.options))
        }
        if decision.clearOverride {
            state.pendingEchoes.append(.init(reason: .override, inputs: route.inputs, outputs: route.outputs))
            try perform(.clearOverride)
        }
    }
}

/// Correlates effect notifications with their previous route; each token lives for at most three events (#852).
struct AudioOutputRouteEcho: Equatable, Sendable {
    typealias Policy = AudioOutputRoutePolicy
    var reason: Policy.Reason
    var inputs: [Policy.Port]
    var outputs: [Policy.Port]
    var remaining = 3

    static func consume(_ route: Policy.Route, pending: inout [Self]) -> Bool {
        let match = pending.firstIndex {
            $0.reason == route.reason && $0.inputs == route.previousInputs && $0.outputs == route.previousOutputs
                && (route.reason != .override || route.inputs == $0.inputs)
        }
        if let match { pending.remove(at: match) }
        // Age on every notification, even unrelated ones; missing echoes must never exempt a later choice.
        for index in pending.indices { pending[index].remaining -= 1 }
        pending.removeAll { $0.remaining == 0 }
        return match != nil
    }
}
