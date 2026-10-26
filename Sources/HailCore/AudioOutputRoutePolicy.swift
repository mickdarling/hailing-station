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
        var availableInputs: [Port] = []
        var previousOutputs: [Port] = []
        var previousInputs: [Port] = []
        var reason: Reason
        var appInitiatedReconfigure = false
    }

    struct State: Equatable, Sendable {
        var externalOutputSeen = false
        var userChoseBuiltIn = false
        var inputLossPending = false
        var lastInputs: [Port]?
        var lastOutputs: [Port]?
        var lastAvailability: HardwareRoute?
    }

    /// Notification identity excludes options, which our own repair changes (#852).
    struct HardwareRoute: Equatable, Sendable {
        var inputs: [Port]
        var outputs: [Port]
        var previousInputs: [Port]
        var previousOutputs: [Port]
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
        // Keepalive may add observed output evidence for capture recovery, without consuming its episode (#852).
        result.state.externalOutputSeen = externalOutput || result.state.externalOutputSeen
            || route.previousOutputs.contains(where: \.isExternalOutput) || hasNewBluetoothInput(route)
        // The background keepalive owns playback/mixWithOthers; never reconfigure it (#282, #352, #852).
        guard route.category == .playAndRecord else {
            if !externalOutput, route.reason == .oldDeviceUnavailable, !lostUSBInput(route) {
                result.state.externalOutputSeen = false
            }
            result.reason = route.category == .playback ? .keepalive : .unsupportedCategory
            return result
        }
        // Our HFP reconfigure can move output without an owner choice or hardware arrival (#914).
        let appReconfigure = route.appInitiatedReconfigure
            && (route.reason == .categoryChange || route.reason == .routeConfigurationChange)
        if externalOutput && !appReconfigure { result.state.userChoseBuiltIn = false }
        // Only capture can act on recovery; playback must leave its pending loss and history untouched (#852).
        let episode = updateEpisode(route, state: &result.state)
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
        if preservesRouteChoice(route) {
            result.state.userChoseBuiltIn = true
            result.state.inputLossPending = false
        }
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
        // Changed non-empty inputs are still a choice; only empty-input overrides are loss blips (#852).
        route.reason == .override && !route.outputs.isEmpty && route.outputs.allSatisfy(\.isBuiltInOutput)
            && !route.inputs.isEmpty
    }

    private static func lostUSBInput(_ route: Route) -> Bool {
        // A USB-input-only loss retains evidence remembered before the speaker fallback (#852).
        route.previousInputs.contains(.usbAudio) && !route.inputs.contains(.usbAudio)
            && !route.previousOutputs.contains(.usbAudio)
    }

    private static func previousRoute(_ route: Route, state: State) -> HardwareRoute {
        // Notification history wins over cache even when the current route was already observed (#852).
        let hasPreviousRoute = !route.previousInputs.isEmpty || !route.previousOutputs.isEmpty
        return HardwareRoute(
            inputs: route.inputs, outputs: route.outputs,
            previousInputs: hasPreviousRoute ? route.previousInputs : (state.lastInputs ?? []),
            previousOutputs: hasPreviousRoute ? route.previousOutputs : (state.lastOutputs ?? [])
        )
    }
}

extension AudioOutputRoutePolicy {
    private static func updateEpisode(_ route: Route, state: inout State) -> Bool {
        defer {
            state.lastInputs = route.inputs
            state.lastOutputs = route.outputs
        }
        guard route.reason != .categoryChange, route.reason != .routeConfigurationChange else { return false }
        let previous = previousRoute(route, state: state)
        let identity = HardwareRoute(inputs: route.inputs, outputs: route.outputs,
                                     previousInputs: route.previousInputs, previousOutputs: route.previousOutputs)
        let inputReturned = state.inputLossPending && previous.previousInputs != route.inputs && !route.inputs.isEmpty
            && route.reason != .oldDeviceUnavailable
        let newDevice = route.reason == .newDeviceAvailable
            && (hasNewBluetoothInput(route) || route.inputs != previous.previousInputs
                || route.outputs != previous.previousOutputs
                || (state.inputLossPending && !route.inputs.isEmpty))
        let episode = (newDevice && state.lastAvailability != identity) || inputReturned
        if episode {
            state.inputLossPending = false
            state.lastAvailability = identity
        } else if route.reason != .newDeviceAvailable,
                  previous.previousInputs.contains(where: { !route.inputs.contains($0) }) {
            state.inputLossPending = true
            state.lastAvailability = nil
        }
        // A removal starts a later episode even if availability reports the same route tuple (#852).
        if route.reason == .oldDeviceUnavailable { state.lastAvailability = nil }
        return episode
    }

    private static func recoveryReason(_ route: Route, episode: Bool, state: State) -> DecisionReason {
        guard episode else { return .noHardwareEpisode }
        guard state.externalOutputSeen else { return .noExternalEvidence }
        guard !route.inputs.isEmpty, !route.outputs.isEmpty,
              route.outputs.allSatisfy(\.isBuiltInOutput) else { return .awaitingRoute }
        return .repairRequested
    }

    private static func hasNewBluetoothInput(_ route: Route) -> Bool {
        // Availability can reveal a headset before it becomes an output; a USB input cannot (#882).
        route.reason == .newDeviceAvailable
            && route.availableInputs.contains { $0 == .bluetoothHFP || $0 == .bluetoothLE }
    }
}
