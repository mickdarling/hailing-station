// swiftlint:disable file_length
// Keep the AVFoundation-free route state and all of its transitions together.
/// Route decisions independent of AVFoundation so fallback and recovery are testable on macOS (#852).
struct AudioOutputRoutePolicy: Sendable {
    enum Port: CaseIterable, Sendable {
        case speaker, receiver, builtInMic, bluetoothA2DP, bluetoothLE, bluetoothHFP
        case headphones, headsetMic, usbAudio, lineIn, lineOut, hdmi, airPlay, carAudio, other

        var isBuiltInOutput: Bool { self == .speaker || self == .receiver }
        var isBluetoothOutput: Bool { self == .bluetoothA2DP || self == .bluetoothHFP || self == .bluetoothLE }
        var isExternalOutput: Bool {
            [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones,
             .usbAudio, .lineOut, .hdmi, .airPlay, .carAudio].contains(self)
        }
    }

    enum Owner: Sendable { case unownedSession, capture, standalone }
    enum Category: CaseIterable, Sendable { case playAndRecord, playback, other }
    enum Reason: CaseIterable, Sendable {
        case newDeviceAvailable, oldDeviceUnavailable, override, categoryChange, routeConfigurationChange, other
    }
    enum DecisionReason: Sendable {
        // A request precedes effects, which can still fail; it is not proof of a repaired hardware route (#852).
        case repairRequested, userChoiceAssumed, noHardwareEpisode, keepalive, unsupportedCategory
        case noExternalEvidence, externalOutputActive, awaitingRoute, speakerFallback, ambiguous, appOperation
    }

    /// Only the flags this policy changes or guards; the iOS adapter preserves every other option (#852).
    struct Options: Equatable, Sendable {
        var defaultToSpeaker = false
        var mixWithOthers = false
        var allowsA2DP = false
        var allowsHFP = false
    }

    struct Route: Sendable {
        var category: Category = .playAndRecord
        var options = Options()
        var categoryOptions: UInt = 0
        var owner = Owner.capture
        var outputs: [Port]
        var inputs: [Port]
        var availableInputs: [Port] = []
        var previousOutputs: [Port] = []
        var previousInputs: [Port] = []
        var reason: Reason
        var isActive = true
        var awaitingInputSelection = false
        var settling = false
        var origin: Operation?
        var pair: Pair { Pair(inputs: inputs, outputs: outputs) }
        func needsSpeakerDefaultChange(to desired: Bool) -> Bool {
            let activeExternalPair = isActive && !inputs.isEmpty && outputs.contains(where: \.isExternalOutput)
            return options.defaultToSpeaker != desired && !activeExternalPair
        }

        var episode: HardwareEpisode {
            HardwareEpisode(reason: reason, previous: Pair(inputs: previousInputs, outputs: previousOutputs))
        }

        var notificationTransition: RouteTransition {
            RouteTransition(inputs: inputs, outputs: outputs, previousInputs: previousInputs,
                            previousOutputs: previousOutputs)
        }
    }

    struct Pair: Equatable, Sendable {
        var inputs: [Port]
        var outputs: [Port]
    }

    enum Operation: Equatable, Sendable {
        case configure, activation, preferredInput(Port?), repairCategory, releaseOverride, restoreSpeaker
    }

    /// AVAudioSession notifications have no transaction ID. Compare both endpoints of completed writes.
    struct Transition: Equatable, Sendable {
        var operation: Operation
        var before: Pair
        var after: Pair
        var lastEcho: Pair?

        func isConfirmed(by route: Route) -> Bool {
            switch operation {
            case .releaseOverride: route.reason == .override || route.outputs.contains(where: \.isExternalOutput)
            case .restoreSpeaker: route.reason == .override && route.outputs == [.speaker]
            case .preferredInput(let port): port.map { route.inputs.contains($0) } ?? true
            default: true
            }
        }

        func couldProduce(_ route: Route) -> Bool {
            guard route.reason == .override || route.reason == .categoryChange ||
                    route.reason == .routeConfigurationChange else { return false }
            let knownPrevious = !route.previousInputs.isEmpty || !route.previousOutputs.isEmpty
            let previous = Pair(inputs: route.previousInputs, outputs: route.previousOutputs)
            let matchesPrevious = previous == before || previous == after || previous == lastEcho
            guard !knownPrevious || matchesPrevious else { return false }
            if operation != .releaseOverride, before != after, previous == after, route.pair == before { return false }
            if operation == .releaseOverride, previous.outputs.contains(where: \.isExternalOutput),
               !route.outputs.isEmpty, route.outputs.allSatisfy(\.isBuiltInOutput) { return false }
            if route.pair == after { return true }
            switch operation {
            case .preferredInput(let input): return input.map { route.inputs.contains($0) } ?? true
            case .releaseOverride:
                // Clearing to the system default can settle on receiver after returning on speaker.
                let builtInOverride = route.reason == .override && !route.inputs.isEmpty &&
                    route.outputs.contains(where: \.isBuiltInOutput)
                return builtInOverride || route.outputs.contains(where: \.isExternalOutput)
            case .restoreSpeaker: return route.outputs == [.speaker]
            case .configure: return !knownPrevious || previous == before
            case .activation, .repairCategory: return route.reason != .override || previous == before && before != after
            }
        }
    }

    struct HardwareEpisode: Equatable, Sendable {
        var reason: Reason
        var previous: Pair
    }

    enum DisconnectFallback: Sendable { case none, waitingForReceiver, applied }

    struct State: Equatable, Sendable {
        var disconnectFallback = DisconnectFallback.none
        var externalOutputSeen = false
        var userChoseBuiltIn = false
        var inputLossPending = false
        var lastInputs: [Port]?
        var lastOutputs: [Port]?
        var lastAvailability: HardwareEpisode?
        var hardwareInputs: Set<Port> = []
        var lastArrival: Arrival?
        var lastRemoval: Removal?
        var lastHardware: HardwareEpisode?
        var hardwareGeneration = 0
        var pickerTransition: RouteTransition?
        var externalPorts: Set<Port> = []
        var transitions: [Transition] = []
        var confirmedTransition: RouteTransition?
        var ambiguousEpisode = false
        var needsSettlement = false
        var lastSettled: Pair?
        var failedSettlement: Pair?
        var skippedOutputs: [Port]?

        // Selecting an HFP mic also selects its output. A background input reconciliation must respect
        // both a picker choice and the temporary hold for an indistinguishable built-in override.
        var holdsBuiltInOutput: Bool { userChoseBuiltIn || ambiguousEpisode }

        mutating func observeOutputs(_ outputs: [Port]) {
            externalPorts.formUnion(outputs.filter(\.isExternalOutput))
            if outputs.contains(where: \.isExternalOutput) { externalOutputSeen = true }
        }

        mutating func retireTransitions() {
            confirmedTransition = nil
            failedSettlement = nil
            transitions.removeAll()
        }

        mutating func completed(_ transition: Transition) {
            if transition.operation == .activation || transition.operation == .configure {
                lastSettled = nil
                if disconnectFallback == .applied { disconnectFallback = .none }
            }
            if transition.operation == .activation { ambiguousEpisode = false }
            transitions.removeAll { $0 == transition }
            transitions.append(transition)
        }
    }

    /// Notification identity excludes options, which our own repair changes (#852).
    struct RouteTransition: Equatable, Sendable {
        var inputs: [Port]
        var outputs: [Port]
        var previousInputs: [Port]
        var previousOutputs: [Port]
    }
}

extension AudioOutputRoutePolicy {
    struct Arrival: Equatable, Sendable {
        let episode: HardwareEpisode
        var observedBluetoothOutput = false
        var enabledHFP = false
    }

    struct Removal: Equatable, Sendable {
        let episode: HardwareEpisode
        let usbInputOnly: Bool
    }

    struct Decision: Sendable {
        var options: Options
        var clearOverride = false
        var restoreSpeaker = false
        var attribution: Operation?
        var settlesPair = false
        var reason: DecisionReason = .noHardwareEpisode
        var state: State
    }

    /// Inactive outputs are not a device inventory. Let activation establish the first actual pair.
    static func configurationOptions(
        for route: Route, owner: Owner = .capture, allowsHFP: Bool, state: State
    ) -> Options {
        var options = Options(allowsA2DP: true, allowsHFP: allowsHFP)
        // Retain an already effective fallback only on an active station reconfiguration.
        if route.isActive, route.owner == owner, route.category == .playAndRecord, !route.options.mixWithOthers,
           route.outputs == [.speaker], route.options.defaultToSpeaker {
            options.defaultToSpeaker = state.holdsBuiltInOutput ||
                (!state.externalOutputSeen && !route.availableInputs.contains(where: isHeadset))
        }
        return options
    }
}

extension AudioOutputRoutePolicy {
    static func routeChange(_ route: Route, state: State) -> Decision {
        var result = Decision(options: route.options, state: state)
        if let receipt = state.confirmedTransition, receipt.inputs != route.inputs || receipt.outputs != route.outputs {
            result.state.confirmedTransition = nil
        }
        let arrived = observeHardware(route, state: &result.state)
        updateOutputHistory(route, arrived: arrived, state: &result.state)
        if !route.settling, state.failedSettlement == route.pair,
           route.origin != nil || route.reason == .categoryChange || route.reason == .routeConfigurationChange {
            result.attribution = route.origin
            result.reason = route.origin == nil ? .noHardwareEpisode : .appOperation
            return result
        }
        if let fallback = disconnectDecision(route, result: result) { return fallback }
        if let attributed = attributedDecision(route, result: result) {
            return settleAfterAppChange(route, decision: attributed)
        }
        guard route.category == .playAndRecord else { return observedPlayback(route, result: result) }
        return stationDecision(route, arrived: arrived, result: result)
    }

    private static func updateOutputHistory(_ route: Route, arrived: Bool, state: inout State) {
        let external = route.outputs.contains(where: \.isExternalOutput)
        let removal = route.reason == .oldDeviceUnavailable
        let lostOutput = removal && state.lastRemoval?.usbInputOnly != true
        if arrived {
            state.externalOutputSeen = true
            state.userChoseBuiltIn = false
        }
        // USB input loss can also be delivered as an empty-input override (#852).
        let usbBlip = route.origin == nil && route.reason == .override && route.inputs.isEmpty && lostUSBInput(route)
        if arrived || usbBlip { state.retireTransitions() }
        if external || arrived {
            state.skippedOutputs = nil
            state.disconnectFallback = .none
        } else if lostOutput, state.disconnectFallback == .none {
            state.disconnectFallback = .waitingForReceiver
        }
        if route.outputs.contains(where: \.isBluetoothOutput) { state.lastArrival?.observedBluetoothOutput = true }
        state.observeOutputs(route.outputs)
        if !lostOutput { state.observeOutputs(route.previousOutputs) }
        if external, !state.userChoseBuiltIn { state.pickerTransition = nil }
        if lostOutput, !external {
            state.externalOutputSeen = false
            state.externalPorts.removeAll()
        }
    }

    // The removal may report speaker before iOS settles on receiver. Keep watching until an external
    // route returns or the receiver needs its one audible fallback, including for a latched speaker pick.
    private static func disconnectDecision(_ route: Route, result: Decision) -> Decision? {
        guard result.state.disconnectFallback == .waitingForReceiver, !result.state.ambiguousEpisode,
              route.origin == nil, route.reason != .override, route.outputs == [.receiver],
              route.category == .playAndRecord,
              route.isActive, !route.awaitingInputSelection else { return nil }
        var result = result
        result.reason = .speakerFallback
        result.settlesPair = true
        if result.state.userChoseBuiltIn || route.options.defaultToSpeaker {
            result.restoreSpeaker = true
        } else {
            result.options.defaultToSpeaker = true
        }
        return result
    }

    private static func observedPlayback(_ route: Route, result: Decision) -> Decision {
        var result = result
        if route.category == .playback, route.reason == .override, route.outputs == [.speaker],
           result.state.pickerTransition != route.notificationTransition {
            result.state.pickerTransition = route.notificationTransition
            result.state.userChoseBuiltIn = true
        }
        result.reason = route.category == .playback ? .keepalive : .unsupportedCategory
        return result
    }

    private static func stationDecision(_ route: Route, arrived: Bool, result: Decision) -> Decision {
        var result = result
        let episode = updateEpisode(route, arrived: arrived, state: &result.state)
        if episode {
            result.state.skippedOutputs = nil
            if route.reason == .newDeviceAvailable { result.state.retireTransitions() }
            result.state.ambiguousEpisode = false
            result.state.lastSettled = nil
        }
        if preservesRouteChoice(route) { return pickerDecision(route, result: result) }
        if route.settling || result.state.needsSettlement || result.state.skippedOutputs == route.outputs {
            let receiverOnly = route.outputs == [.receiver] && !result.state.externalOutputSeen
            if route.isActive, !route.awaitingInputSelection, !route.outputs.isEmpty,
               !route.inputs.isEmpty || receiverOnly {
                result.state.needsSettlement = false
                result.state.skippedOutputs = nil
                return settled(route, result: result)
            }
            result.state.needsSettlement = true
            result.reason = .awaitingRoute
            return result
        }
        guard route.isActive, !route.awaitingInputSelection else {
            if arrived { result.state.needsSettlement = true }
            return result
        }
        guard route.reason != .categoryChange, route.reason != .routeConfigurationChange else { return result }
        if route.outputs.contains(where: \.isExternalOutput) {
            result.reason = .externalOutputActive
            return result
        }
        return builtInDecision(route, episode: episode, result: result)
    }

    private static func settled(_ route: Route, result: Decision) -> Decision {
        var result = result
        if result.state.ambiguousEpisode {
            result.reason = .ambiguous
            return result
        }
        if result.state.lastSettled == route.pair ||
            (result.state.disconnectFallback == .applied && route.outputs == [.receiver]) { return result }
        result.settlesPair = true
        if result.state.userChoseBuiltIn {
            result.restoreSpeaker = route.outputs != [.speaker]
            result.reason = .userChoiceAssumed
        } else if route.outputs.contains(where: \.isExternalOutput) {
            result.reason = .externalOutputActive
        } else if route.outputs.allSatisfy(\.isBuiltInOutput) {
            if result.state.externalOutputSeen || route.availableInputs.contains(where: isHeadset) {
                result.options.defaultToSpeaker = false
                result.clearOverride = true
                result.reason = .repairRequested
            } else if route.outputs == [.receiver] {
                result.restoreSpeaker = route.options.defaultToSpeaker
                result.options.defaultToSpeaker = true
                result.reason = .speakerFallback
            }
        }
        return result
    }

    private static func attributedDecision(_ route: Route, result: Decision) -> Decision? {
        guard !route.settling else { return nil }
        var result = result
        let pending = result.state.transitions
        let candidates = pending.indices.reversed().filter {
            (route.origin == nil || pending[$0].operation == route.origin) && pending[$0].couldProduce(route)
        }
        let index = candidates.first { pending[$0].isConfirmed(by: route) }
        let operation = index.map { pending[$0].operation }
        guard let origin = route.origin ?? operation else {
            let repeated = result.state.confirmedTransition == route.notificationTransition
            if route.reason == .override, repeated || !candidates.isEmpty {
                let builtIn = !route.outputs.isEmpty && route.outputs.allSatisfy(\.isBuiltInOutput)
                result.reason = builtIn ? .ambiguous : .appOperation
                if builtIn { result.state.ambiguousEpisode = true }
                return result
            }
            return nil
        }
        // A category notice may precede the override notification from the same port override.
        if let index {
            if origin == .releaseOverride {
                // A clear may report speaker first, then receiver. Retain its provenance through both echoes.
                result.state.transitions[index].lastEcho = route.pair
            } else {
                result.state.transitions.remove(at: index)
                result.state.confirmedTransition = route.notificationTransition
            }
        }
        result.attribution = origin
        result.reason = .appOperation
        if route.origin == nil, route.reason == .override, route.outputs.allSatisfy(\.isBuiltInOutput),
           !route.outputs.isEmpty {
            result.reason = .ambiguous
            result.state.ambiguousEpisode = true
        }
        return result
    }

    private static func settleAfterAppChange(_ route: Route, decision: Decision) -> Decision {
        guard route.isActive, !route.awaitingInputSelection, route.category == .playAndRecord,
              !route.inputs.isEmpty, !route.outputs.isEmpty, decision.reason != .ambiguous else { return decision }
        let ownerDrift = decision.state.userChoseBuiltIn && route.outputs.contains(where: \.isExternalOutput)
        let reconfigured = decision.attribution == .configure && route.outputs.allSatisfy(\.isBuiltInOutput)
        guard decision.state.needsSettlement || ownerDrift || reconfigured else { return decision }
        var result = decision
        result.state.needsSettlement = false
        return settled(route, result: result)
    }

    private static func isHeadset(_ port: Port) -> Bool { port == .bluetoothHFP || port == .bluetoothLE }

    private static func observeHardware(_ route: Route, state: inout State) -> Bool {
        guard route.origin == nil, route.reason == .newDeviceAvailable || route.reason == .oldDeviceUnavailable
        else { return false }
        if route.reason == .oldDeviceUnavailable, state.lastRemoval?.episode == route.episode { return false }
        let available = Set(route.availableInputs)
        var baseline = state.hardwareInputs
        // Enabling HFP exposes another profile of an already observed Bluetooth output (#914).
        // availableInputs may change only when the original arrival is redelivered.
        if let arrival = state.lastArrival, arrival.enabledHFP, arrival.episode == route.episode,
           route.options.allowsHFP, available.contains(.bluetoothHFP) {
            baseline.insert(.bluetoothHFP)
        }
        let additions = available.subtracting(baseline)
        let inventoryChanged = available != baseline
        state.hardwareInputs = available
        let differentEvent = state.lastHardware != route.episode
        state.lastHardware = route.episode
        if route.reason == .oldDeviceUnavailable {
            state.hardwareGeneration += 1
            let usbOnly = lostUSBInput(route)
            state.lastRemoval = Removal(episode: route.episode, usbInputOnly: usbOnly)
            state.retireTransitions()
            state.lastArrival = nil
            if !usbOnly {
                state.externalPorts.subtract(route.previousOutputs.filter { !route.outputs.contains($0) })
            }
            state.lastSettled = nil
            state.ambiguousEpisode = false
            return false
        }
        state.lastRemoval = nil
        let arrived = externalArrival(route, additions: additions, state: state)
        if differentEvent || inventoryChanged || arrived {
            state.hardwareGeneration += 1
            state.retireTransitions()
        }
        guard arrived else { return false }
        state.lastArrival = Arrival(episode: route.episode)
        state.lastSettled = nil
        state.ambiguousEpisode = false
        return true
    }

    private static func externalArrival(_ route: Route, additions: Set<Port>, state: State) -> Bool {
        let previous = previousRoute(route, state: state)
        let usbSelected = route.inputs.contains(.usbAudio) && !previous.previousInputs.contains(.usbAudio)
        let headsetAdded = additions.contains(where: isHeadset) && !additions.contains(.usbAudio) && !usbSelected
        if headsetAdded { return true }
        let newOutputs = route.outputs.filter { $0.isExternalOutput && !previous.previousOutputs.contains($0) }
        // Current output may move on a duplicate. An unseen output type is independent inventory evidence.
        if newOutputs.contains(where: { !state.externalPorts.contains($0) }) { return true }
        let unseenHistory = route.previousOutputs.contains { $0.isExternalOutput && !state.externalPorts.contains($0) }
        let outputOnly = !route.inputs.isEmpty && route.inputs == previous.previousInputs
        return state.lastArrival?.episode != route.episode && (!newOutputs.isEmpty || outputOnly && unseenHistory)
    }

    private static func builtInDecision(_ route: Route, episode: Bool, result: Decision) -> Decision {
        var result = result
        if result.state.userChoseBuiltIn {
            result.reason = .userChoiceAssumed
            return result
        }
        if route.reason == .oldDeviceUnavailable, result.state.lastRemoval?.usbInputOnly != true {
            result.state.externalOutputSeen = false
            if route.outputs.isEmpty { result.state.needsSettlement = true }
            result.reason = .noExternalEvidence
            return result
        }
        if result.state.ambiguousEpisode {
            result.reason = .ambiguous
            return result
        }
        result.reason = recoveryReason(route, episode: episode, state: result.state)
        if result.reason == .awaitingRoute { result.state.needsSettlement = true }
        guard result.reason == .repairRequested else { return result }
        result.settlesPair = true
        result.options.defaultToSpeaker = false
        result.clearOverride = true
        return result
    }

    private static func pickerDecision(_ route: Route, result: Decision) -> Decision {
        var result = result
        result.state.skippedOutputs = nil
        if result.state.pickerTransition != route.notificationTransition {
            result.state.confirmedTransition = nil
            result.state.pickerTransition = route.notificationTransition
            result.state.userChoseBuiltIn = true
            result.state.ambiguousEpisode = false
            result.state.inputLossPending = false
            result.state.lastSettled = nil
        }
        result.reason = result.state.userChoseBuiltIn ? .userChoiceAssumed : .ambiguous
        if !result.state.userChoseBuiltIn { result.state.ambiguousEpisode = true }
        return result
    }

    private static func preservesRouteChoice(_ route: Route) -> Bool {
        // App writes and ambiguous echoes have already been attributed.
        // Changed non-empty inputs are still a choice; only empty-input overrides are loss blips (#852).
        route.reason == .override && !route.outputs.isEmpty && route.outputs.allSatisfy(\.isBuiltInOutput)
            && !route.inputs.isEmpty
    }

    private static func lostUSBInput(_ route: Route) -> Bool {
        // A USB-input-only loss retains evidence remembered before the speaker fallback (#852).
        route.previousInputs.contains(.usbAudio) && !route.inputs.contains(.usbAudio)
            && !route.previousOutputs.contains(.usbAudio)
    }

    private static func previousRoute(_ route: Route, state: State) -> RouteTransition {
        // Notification history wins over cache even when the current route was already observed (#852).
        let hasPreviousRoute = !route.previousInputs.isEmpty || !route.previousOutputs.isEmpty
        return RouteTransition(
            inputs: route.inputs, outputs: route.outputs,
            previousInputs: hasPreviousRoute ? route.previousInputs : (state.lastInputs ?? []),
            previousOutputs: hasPreviousRoute ? route.previousOutputs : (state.lastOutputs ?? [])
        )
    }
}

extension AudioOutputRoutePolicy {
    private static func updateEpisode(_ route: Route, arrived: Bool, state: inout State) -> Bool {
        defer {
            state.lastInputs = route.inputs
            state.lastOutputs = route.outputs
        }
        guard route.reason != .categoryChange, route.reason != .routeConfigurationChange else { return false }
        let previous = previousRoute(route, state: state)
        let identity = route.episode
        let inputReturned = state.inputLossPending && previous.previousInputs != route.inputs && !route.inputs.isEmpty
            && route.reason != .oldDeviceUnavailable
        let newDevice = route.reason == .newDeviceAvailable
            && (arrived || route.inputs != previous.previousInputs
                || route.outputs != previous.previousOutputs
                || (state.inputLossPending && !route.inputs.isEmpty))
        let episode = route.reason == .newDeviceAvailable
            ? arrived || (newDevice && state.lastAvailability != identity) : inputReturned
        if episode {
            state.inputLossPending = false
            if route.reason == .newDeviceAvailable { state.lastAvailability = identity }
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
}
