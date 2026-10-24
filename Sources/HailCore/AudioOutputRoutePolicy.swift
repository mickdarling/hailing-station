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
    }
    enum DecisionReason: Sendable {
        // A request precedes effects, which can still fail; it is not proof of a repaired hardware route (#852).
        case repairRequested, userChoiceAssumed, noHardwareEpisode, keepalive, unsupportedCategory
        case noExternalEvidence, externalOutputActive, awaitingRoute
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
        var userChoseBuiltIn = false
        var inputLossPending = false
        var lastInputs: [Port]?
        var lastOutputs: [Port]?
    }

    struct Decision: Sendable {
        var options: Options
        var clearOverride = false
        var reason: DecisionReason = .noHardwareEpisode
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
        let externalOutput = route.outputs.contains(where: \.isExternalOutput)
        if externalOutput { result.state.userChoseBuiltIn = false }
        // The background keepalive owns playback/mixWithOthers; never reconfigure it (#282, #352, #852).
        guard route.category == .playAndRecord else {
            result.reason = route.category == .playback ? .keepalive : .unsupportedCategory
            return result
        }
        let episode = updateEpisode(route, state: &result.state)
        result.state.externalOutputSeen = externalOutput || result.state.externalOutputSeen
            || route.previousOutputs.contains(where: \.isExternalOutput)
        // Category/configuration notifications can cache evidence, but never cause effects or latch a choice.
        guard route.reason != .categoryChange, route.reason != .routeConfigurationChange else { return result }
        if externalOutput {
            result.options.defaultToSpeaker = false
            result.reason = .externalOutputActive
            return result
        }
        return builtInDecision(route, episode: episode, result: result)
    }

    private static func builtInDecision(_ route: Route, episode: Bool, result: Decision) -> Decision {
        var result = result
        if preservesRouteChoice(route) { result.state.userChoseBuiltIn = true }
        if result.state.userChoseBuiltIn {
            result.reason = .userChoiceAssumed
            return result
        }
        if route.reason == .oldDeviceUnavailable, !lostUSBInput(route) {
            result.state.externalOutputSeen = false
            result.options = configurationOptions(outputs: route.outputs, options: route.options)
            result.reason = .noExternalEvidence
            return result
        }
        result.reason = recoveryReason(route, episode: episode, state: result.state)
        guard result.reason == .repairRequested else { return result }
        result.options.defaultToSpeaker = false
        result.clearOverride = true
        return result
    }

    private static func preservesRouteChoice(_ route: Route) -> Bool {
        // Even our own failed repair echo is indistinguishable from a user choice: leave it alone (#852).
        let hasPreviousRoute = !route.previousInputs.isEmpty || !route.previousOutputs.isEmpty
        return route.reason == .override && !route.outputs.isEmpty && route.outputs.allSatisfy(\.isBuiltInOutput)
            && (!hasPreviousRoute || route.previousInputs == route.inputs)
    }

    private static func lostUSBInput(_ route: Route) -> Bool {
        // A USB-input-only loss retains evidence remembered before the speaker fallback (#852).
        route.previousInputs.contains(.usbAudio) && !route.inputs.contains(.usbAudio)
            && !route.previousOutputs.contains(.usbAudio)
    }

    private static func previousInputs(_ route: Route, state: State) -> [Port] {
        // Notification history wins over cache, especially for a choice after an input-loss blip (#852).
        let hasPreviousRoute = !route.previousInputs.isEmpty || !route.previousOutputs.isEmpty
        return hasPreviousRoute ? route.previousInputs : (state.lastInputs ?? [])
    }

    private static func updateEpisode(_ route: Route, state: inout State) -> Bool {
        defer {
            state.lastInputs = route.inputs
            state.lastOutputs = route.outputs
        }
        guard route.reason != .categoryChange, route.reason != .routeConfigurationChange else { return false }
        let previous = previousInputs(route, state: state)
        let inputReturned = state.inputLossPending && previous != route.inputs && !route.inputs.isEmpty
            && route.reason != .oldDeviceUnavailable
        let newDevice = route.reason == .newDeviceAvailable
            && (route.inputs != (state.lastInputs ?? route.previousInputs)
                || route.outputs != (state.lastOutputs ?? route.previousOutputs)
                || (state.inputLossPending && !route.inputs.isEmpty))
        let episode = newDevice || inputReturned
        if episode {
            state.inputLossPending = false
        } else if route.inputs != (state.lastInputs ?? previous),
                  previous.contains(where: { !route.inputs.contains($0) }) {
            state.inputLossPending = true
        }
        return episode
    }
}

extension AudioOutputRoutePolicy {
    private static func recoveryReason(_ route: Route, episode: Bool, state: State) -> DecisionReason {
        guard episode else { return .noHardwareEpisode }
        guard state.externalOutputSeen else { return .noExternalEvidence }
        guard !route.inputs.isEmpty, !route.outputs.isEmpty,
              route.outputs.allSatisfy(\.isBuiltInOutput) else { return .awaitingRoute }
        return .repairRequested
    }
}
