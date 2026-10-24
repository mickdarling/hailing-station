/// Route decisions independent of AVFoundation so fallback and recovery are testable on macOS (#852).
struct AudioOutputRoutePolicy: Sendable {
    enum Port: CaseIterable, Sendable {
        case speaker, receiver, builtInMic, bluetoothA2DP, bluetoothLE, bluetoothHFP
        case headphones, usbAudio, lineOut, airPlay, carAudio, other

        var isBuiltInOutput: Bool { self == .speaker || self == .receiver }
        var isExternalOutput: Bool {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones,
             .usbAudio, .lineOut, .airPlay, .carAudio].contains(self)
        }
    }

    enum Category: CaseIterable, Sendable { case playAndRecord, playback, other }
    enum Reason: CaseIterable, Sendable {
        case newDeviceAvailable, oldDeviceUnavailable, override, categoryChange, routeConfigurationChange, other

        var permitsRecovery: Bool {
            [.newDeviceAvailable, .override, .categoryChange, .routeConfigurationChange].contains(self)
        }
    }

    /// Only the flags this policy changes or guards; the iOS adapter preserves every other option (#852).
    struct Options: Equatable, Sendable {
        var defaultToSpeaker = false
        var mixWithOthers = false
    }

    struct Route: Sendable {
        var category: Category = .playAndRecord
        var options = Options()
        var outputs: [Port]
        var inputs: [Port]
        var previousOutputs: [Port] = []
        var previousInputs: [Port] = []
        var reason: Reason
    }

    struct State: Equatable, Sendable {
        var externalOutputSeen = false
        // Success and the per-episode attempt guard are separate so a throwing effect cannot claim success (#852).
        var restoreAttempted = false
        var attemptedInEpisode = false
        var inputLossPending = false
        var lastInputs: [Port]?
        var lastOutputs: [Port]?
    }

    struct Decision: Sendable {
        var options: Options
        var clearOverride = false
        var state: State
    }

    static func configurationOptions(outputs: [Port], options: Options) -> Options {
        var result = options
        // Empty/inactive routes also need the audible iPhone fallback on activation (#852).
        // Unknown ports are deliberately not treated as built-in. A USB *input* is not a USB output.
        result.defaultToSpeaker = outputs.allSatisfy(\.isBuiltInOutput)
        return result
    }

    static func routeChange(_ route: Route, state: State) -> Decision {
        var result = Decision(options: route.options, state: state)
        // The background keepalive owns playback/mixWithOthers; never reconfigure it (#282, #352, #852).
        guard route.category == .playAndRecord else { return result }
        updateEpisode(route, state: &result.state)
        let lostUSBInput = route.previousInputs.contains(.usbAudio) && !route.inputs.contains(.usbAudio)
            && !route.previousOutputs.contains(.usbAudio)
        if route.outputs.contains(where: \.isExternalOutput) {
            result.state.externalOutputSeen = true
            result.options.defaultToSpeaker = false
            return result
        } else if route.reason == .oldDeviceUnavailable, !lostUSBInput {
            // A USB-input-only loss retains even evidence remembered before the speaker fallback (#852).
            result.state.externalOutputSeen = false
            result.options = configurationOptions(outputs: route.outputs, options: route.options)
            return result
        }
        result.state.externalOutputSeen = result.state.externalOutputSeen
            || route.previousOutputs.contains(where: \.isExternalOutput)
        guard route.reason.permitsRecovery, result.state.externalOutputSeen,
              !result.state.attemptedInEpisode, !result.state.restoreAttempted else { return result }
        result.options.defaultToSpeaker = false
        guard !route.inputs.isEmpty, !route.outputs.isEmpty,
              route.outputs.allSatisfy(\.isBuiltInOutput) else { return result }
        result.clearOverride = true
        result.state.attemptedInEpisode = true
        return result
    }

    private static func updateEpisode(_ route: Route, state: inout State) {
        let previousInputs = state.lastInputs ?? route.previousInputs
        let inputChanged = previousInputs != route.inputs
        if inputChanged, previousInputs.contains(where: { !route.inputs.contains($0) }) {
            state.inputLossPending = true
        }
        let newDevice = route.reason == .newDeviceAvailable
            && (inputChanged || route.outputs != (state.lastOutputs ?? route.previousOutputs)
                || (state.inputLossPending && !route.inputs.isEmpty))
        let inputReturned = state.inputLossPending && inputChanged && !route.inputs.isEmpty
            && ![Reason.override, .categoryChange, .oldDeviceUnavailable].contains(route.reason)
        if newDevice || inputReturned {
            state.restoreAttempted = false
            state.attemptedInEpisode = false
            state.inputLossPending = false
        }
        // No initiator distinguishes Control Center from a system override (#852). The first choice after
        // a genuine hardware/input episode may be undone once. External output alone must not re-arm it;
        // an override with unchanged inputs after repair is the user's choice, including after external return.
        state.lastInputs = route.inputs
        state.lastOutputs = route.outputs
    }
}

/// Shared decision → effects → result loop used by the iOS backend and macOS scripted tests (#852).
enum AudioOutputRouteDriver {
    enum Effect: Equatable, Sendable {
        case setCategory(AudioOutputRoutePolicy.Options)
        case clearOverride
    }

    @discardableResult
    static func process(
        _ route: AudioOutputRoutePolicy.Route, state: inout AudioOutputRoutePolicy.State,
        perform: (Effect) throws -> Void
    ) -> Bool {
        let decision = AudioOutputRoutePolicy.routeChange(route, state: state)
        state = decision.state
        do {
            try apply(decision, currentOptions: route.options, perform: perform)
            if decision.clearOverride { state.restoreAttempted = true }
            return true
        } catch {
            // Failed effects never latch success; the episode guard still absorbs their queued echoes (#852).
            if decision.clearOverride { state.restoreAttempted = false }
            return false
        }
    }

    private static func apply(
        _ decision: AudioOutputRoutePolicy.Decision, currentOptions: AudioOutputRoutePolicy.Options,
        perform: (Effect) throws -> Void
    ) throws {
        if decision.options != currentOptions || decision.clearOverride {
            try perform(.setCategory(decision.options))
        }
        if decision.clearOverride { try perform(.clearOverride) }
    }
}
