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
        var restoreAttempted = false
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
        let external = route.outputs.contains(where: \.isExternalOutput)
        let lostUSBInput = route.previousInputs.contains(.usbAudio) && !route.inputs.contains(.usbAudio)
            && route.previousOutputs.contains { $0.isExternalOutput && $0 != .usbAudio }
        if external {
            result.state = State(externalOutputSeen: true)
            result.options.defaultToSpeaker = false
            return result
        } else if route.reason == .oldDeviceUnavailable, !lostUSBInput {
            // Forget disconnected outputs, but retain a separate output across a USB mic unplug (#852).
            result.state = State()
            result.options = configurationOptions(outputs: route.outputs, options: route.options)
            return result
        }
        result.state.externalOutputSeen = state.externalOutputSeen
            || route.previousOutputs.contains(where: \.isExternalOutput)
        guard route.reason.permitsRecovery, result.state.externalOutputSeen else { return result }
        result.options.defaultToSpeaker = false
        // Wait out an input-less blip; the returning USB input's notification completes the repair (#852).
        guard !route.inputs.isEmpty, !route.outputs.isEmpty,
              route.outputs.allSatisfy(\.isBuiltInOutput), !state.restoreAttempted else { return result }
        result.clearOverride = true
        // Latch *before* applying. It covers synchronous re-entry, queued category/override notifications,
        // and repeated availability events until external output actually returns (#852).
        result.state.restoreAttempted = true
        return result
    }
}
