import HailProtocol
#if os(iOS)
import AVFoundation
import Foundation
#endif

// The scripted driver and iOS adapter share the same synchronous observation boundary.
// swiftlint:disable file_length
struct AudioRoutePorts: Sendable {
    let input: DiagnosticRoutePort
    let output: DiagnosticRoutePort
    let inputCount: UInt8
    let outputCount: UInt8
}

struct AudioRouteSettings: Sendable {
    let category: AudioOutputRoutePolicy.Category
    let defaultToSpeaker: Bool
    let allowA2DP: Bool
    let allowHFP: Bool
    let mixWithOthers: Bool
}

struct AudioRouteSnapshot: Sendable {
    let ports: AudioRoutePorts
    let settings: AudioRouteSettings
}

struct AudioRouteChange: Sendable {
    let reasonRaw: UInt
    let current: AudioRouteSnapshot
    let previous: AudioRoutePorts
}

struct RouteObservationStamp {
    let sequence: Int64
    let timestamp: Int64
    let generation: UInt64
    let hfpPreference: Bool
}

enum AudioRouteObservation {
    case configure(before: AudioRoutePorts, result: AudioRouteSettings, policyApply: Bool, succeeded: Bool)
    case decision(AudioRouteChange, AudioOutputRoutePolicy.DecisionReason, choseBuiltIn: Bool, appAttributed: Bool)
}

@MainActor
protocol AudioRouteObservationSink: AnyObject {
    func beginRouteObservation() -> RouteObservationStamp?
    func observe(_ observation: AudioRouteObservation, at stamp: RouteObservationStamp)
}

/// Each station window has its own opt-in log. All windows share the process audio session.
@MainActor
final class AudioRouteObservations {
    static let shared = AudioRouteObservations()
    private struct Listener {
        weak var sink: (any AudioRouteObservationSink)?
    }
    private var listeners: [Listener] = []
    var isObserved: Bool { listeners.contains { $0.sink != nil } }

    func setObserving(_ sink: any AudioRouteObservationSink, enabled: Bool) {
        listeners.removeAll { $0.sink == nil || $0.sink === sink }
        if enabled { listeners.append(Listener(sink: sink)) }
    }

    /// Reserve each log's order before the write, which can synchronously deliver another notification.
    func categoryWrite(
        before: @autoclosure () -> AudioRoutePorts, result: @autoclosure () -> AudioRouteSettings,
        policyApply: Bool, write: () throws -> Void
    ) rethrows {
        guard isObserved else { return try write() }
        let pending = listeners.compactMap { listener -> (any AudioRouteObservationSink, RouteObservationStamp)? in
            guard let sink = listener.sink, let stamp = sink.beginRouteObservation() else { return nil }
            return (sink, stamp)
        }
        let ports = before()
        var succeeded = false
        defer {
            let observation = AudioRouteObservation.configure(
                before: ports, result: result(), policyApply: policyApply, succeeded: succeeded
            )
            for (sink, stamp) in pending { sink.observe(observation, at: stamp) }
        }
        try write()
        succeeded = true
    }

    func publish(_ observation: AudioRouteObservation) {
        for listener in listeners {
            if let sink = listener.sink, let stamp = sink.beginRouteObservation() {
                sink.observe(observation, at: stamp)
            }
        }
    }
}

/// Keeps the original AV reason and diagnostic port vocabulary alongside the narrower policy translation.
struct ObservedPolicyRoute {
    var policy: AudioOutputRoutePolicy.Route
    let change: AudioRouteChange?
    var reason: AudioOutputRoutePolicy.Reason { policy.reason }
    var appInitiatedReconfigure: Bool {
        get { policy.appInitiatedReconfigure }
        set { policy.appInitiatedReconfigure = newValue }
    }
}

#if os(iOS)
extension AudioRoutePorts {
    init(_ route: AVAudioSessionRouteDescription?) {
        self.init(inputs: route?.inputs ?? [], outputs: route?.outputs ?? [])
    }

    init(inputs: [AVAudioSessionPortDescription], outputs: [AVAudioSessionPortDescription]) {
        self.init(input: Self.port(inputs.first?.portType), output: Self.port(outputs.first?.portType),
                  inputCount: UInt8(clamping: inputs.count), outputCount: UInt8(clamping: outputs.count))
    }

    static func port(_ port: AVAudioSession.Port?) -> DiagnosticRoutePort {
        guard let port else { return .none }
        return portKinds[port] ?? .other
    }

    private static let portKinds: [AVAudioSession.Port: DiagnosticRoutePort] = [
        .builtInMic: .builtInMic, .builtInSpeaker: .builtInSpeaker, .builtInReceiver: .builtInReceiver,
        .headphones: .headphones, .headsetMic: .headsetMic, .lineIn: .lineIn, .lineOut: .lineOut,
        .bluetoothA2DP: .bluetoothA2DP, .bluetoothHFP: .bluetoothHFP, .bluetoothLE: .bluetoothLE,
        .airPlay: .airPlay, .HDMI: .hdmi, .carAudio: .carAudio, .usbAudio: .usbAudio
    ]
}

extension AudioRouteSettings {
    @MainActor init(_ session: AVAudioSession) {
        let category = session.category, options = session.categoryOptions
        self.init(category: category == .playAndRecord ? .playAndRecord : (category == .playback ? .playback : .other),
                  defaultToSpeaker: options.contains(.defaultToSpeaker),
                  allowA2DP: options.contains(.allowBluetoothA2DP), allowHFP: options.contains(.allowBluetoothHFP),
                  mixWithOthers: options.contains(.mixWithOthers))
    }
}

/// AVFoundation translation and effects only; the shared pure policy owns the decisions (#852).
@MainActor
enum AudioOutputSessionRouting {
    struct Snapshot: Sendable {
        let reasonRaw: UInt
        let previous: AudioRoutePorts
        let previousInputs: [AudioOutputRoutePolicy.Port]
        let previousOutputs: [AudioOutputRoutePolicy.Port]
    }

    nonisolated static func snapshot(_ notification: Notification) -> Snapshot {
        let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        let inputs = previous?.inputs ?? [], outputs = previous?.outputs ?? []
        return Snapshot(
            reasonRaw: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0,
            previous: AudioRoutePorts(inputs: inputs, outputs: outputs),
            previousInputs: portTypes(inputs), previousOutputs: portTypes(outputs)
        )
    }

    static func configure(_ session: AVAudioSession, allowsBluetoothHFP: Bool) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if allowsBluetoothHFP { options.insert(.allowBluetoothHFP) }
        let current = session.currentRoute
        let desired = AudioOutputRoutePolicy.configurationOptions(
            outputs: portTypes(current.outputs), options: policyOptions(options)
        )
        try AudioRouteObservations.shared.categoryWrite(
            before: AudioRoutePorts(current), result: AudioRouteSettings(session), policyApply: false
        ) {
            try session.setCategory(.playAndRecord, mode: .default, options: applying(desired, to: options))
        }
    }

    static func route(_ session: AVAudioSession, snapshot: Snapshot) -> ObservedPolicyRoute {
        let current = session.currentRoute
        let settings = AudioRouteSettings(session)
        let policy = AudioOutputRoutePolicy.Route(
            category: settings.category,
            options: .init(defaultToSpeaker: settings.defaultToSpeaker, mixWithOthers: settings.mixWithOthers),
            outputs: portTypes(current.outputs), inputs: portTypes(current.inputs),
            availableInputs: portTypes(session.availableInputs ?? []),
            previousOutputs: snapshot.previousOutputs,
            previousInputs: snapshot.previousInputs, reason: reason(snapshot.reasonRaw)
        )
        let change = AudioRouteObservations.shared.isObserved ? AudioRouteChange(
            reasonRaw: snapshot.reasonRaw, current: .init(ports: AudioRoutePorts(current), settings: settings),
            previous: snapshot.previous
        ) : nil
        return ObservedPolicyRoute(policy: policy, change: change)
    }

    static func apply(_ effect: AudioOutputRouteDriver.Effect, to session: AVAudioSession) throws {
        switch effect {
        case .setCategory(let desired):
            try AudioRouteObservations.shared.categoryWrite(
                before: AudioRoutePorts(session.currentRoute), result: AudioRouteSettings(session), policyApply: true
            ) {
                try session.setCategory(
                    session.category, mode: session.mode, options: applying(desired, to: session.categoryOptions)
                )
            }
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

/// Session-scoped attribution for the whole category/configuration burst from our reconfigure (#914).
/// A missing notification cannot leave a stale marker: it expires after one second, and hardware events cancel it.
struct AudioOutputReconfigureMarker {
    private var deadline: ContinuousClock.Instant?

    mutating func arm(now: ContinuousClock.Instant = .now) {
        deadline = now.advanced(by: .seconds(1))
    }

    mutating func cancel() {
        deadline = nil
    }

    mutating func attributes(
        _ reason: AudioOutputRoutePolicy.Reason, now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard let deadline else { return false }
        if now >= deadline || reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
            cancel()
            return false
        }
        // A genuine category-only change from another source inside this window is attributed to us too.
        // The fixed one-second deadline bounds that ambiguity; notifications never extend it.
        return reason == .categoryChange || reason == .routeConfigurationChange
    }
}

/// Shared decision → effects → result loop used by the iOS backend and macOS scripted tests (#852).
enum AudioOutputRouteDriver {
    enum Effect: Equatable, Sendable {
        case setCategory(AudioOutputRoutePolicy.Options)
        case clearOverride
    }

    @MainActor
    @discardableResult
    static func process(
        _ route: ObservedPolicyRoute, state: inout AudioOutputRoutePolicy.State,
        observations: AudioRouteObservations = .shared,
        observeDecision: (AudioOutputRoutePolicy.Decision) -> Void,
        perform: (Effect) throws -> Void
    ) -> Bool {
        process(route.policy, state: &state, observeDecision: { decision in
            if let change = route.change {
                observations.publish(.decision(change, decision.reason, choseBuiltIn: decision.state.userChoseBuiltIn,
                                               appAttributed: route.appInitiatedReconfigure))
            }
            observeDecision(decision)
        }, perform: perform)
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
            try apply(decision, route: route, perform: perform)
            return true
        } catch {
            // A later genuine episode can retry; a built-in override still conservatively latches a choice (#852).
            return false
        }
    }

    private static func apply(
        _ decision: AudioOutputRoutePolicy.Decision, route: AudioOutputRoutePolicy.Route,
        perform: (Effect) throws -> Void
    ) throws {
        if decision.options != route.options || decision.clearOverride {
            try perform(.setCategory(decision.options))
        }
        if decision.clearOverride {
            try perform(.clearOverride)
        }
    }
}
