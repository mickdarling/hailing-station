import Testing
@testable import HailCore

@Suite struct AudioOutputRouteKeepaliveTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Category.playback, .other])
    func removedAirPodsCannotMakeUSBInputRepairSpeaker(_ category: Policy.Category) {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.builtInMic], reason: .newDeviceAvailable))
        #expect(session.state.externalOutputSeen)
        session.options = .init(defaultToSpeaker: true, mixWithOthers: true)
        Self.observeWithoutEffects(session, route: .init(
            category: category, outputs: [.bluetoothA2DP], inputs: [], reason: .categoryChange
        ))
        Self.observeWithoutEffects(session, route: .init(
            category: category, outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothA2DP],
            reason: .oldDeviceUnavailable
        ))
        #expect(!session.state.externalOutputSeen)
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .categoryChange))
        #expect(session.effects.isEmpty)
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        #expect(session.decisionReasons.last == .noExternalEvidence)
        #expect(session.options.defaultToSpeaker)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Policy.Category.playback, .other])
    func connectedAirPodsStillRepairOnceAfterKeepaliveUSBBlip(_ category: Policy.Category) {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.options = .init(defaultToSpeaker: true, mixWithOthers: true)
        Self.observeWithoutEffects(session, route: .init(
            category: category, outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .categoryChange
        ))
        // USB-input-only removal must retain the separate AirPods evidence even on fallback (#852).
        Self.observeWithoutEffects(session, route: .init(
            category: category, outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        #expect(session.state.externalOutputSeen)
        #expect(session.state.inputLossPending)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .categoryChange))
        #expect(session.effects.isEmpty)
        let returned = Policy.Route(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable)
        session.send(returned)
        #expect(session.decisionReasons.last == .repairRequested)
        session.send(returned)
        session.drainEchoes()
        #expect(session.categories == 1)
        #expect(session.clears == 1)
        #expect(session.effects.count == 2)
    }

    @Test func keepaliveTracksCompletedEpisodeWithoutLatchingChoice() {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        Self.observeWithoutEffects(session, route: .init(
            category: .playback, outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        let returned = Policy.Route(
            category: .playback, outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            reason: .newDeviceAvailable
        )
        Self.observeWithoutEffects(session, route: returned)
        #expect(session.state.lastInputs == [.usbAudio])
        #expect(session.state.lastOutputs == [.speaker])
        #expect(session.state.lastAvailability == .init(
            inputs: [.usbAudio], outputs: [.speaker], previousInputs: [], previousOutputs: [.speaker]
        ))
        #expect(!session.state.inputLossPending)
        Self.observeWithoutEffects(session, route: .init(
            category: .playback, outputs: [.speaker], inputs: [.usbAudio], reason: .override
        ))
        #expect(!session.state.userChoseBuiltIn)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .categoryChange))
        var duplicate = returned
        duplicate.category = .playAndRecord
        session.send(duplicate)
        #expect(session.decisionReasons.last == .noHardwareEpisode)
        #expect(session.effects.isEmpty)
    }

    @Test func keepaliveDoesNotForgetAnExplicitOwnerChoice() {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .override))
        #expect(session.state.userChoseBuiltIn)
        Self.observeWithoutEffects(session, route: .init(
            category: .playback, outputs: [.speaker], inputs: [], reason: .oldDeviceUnavailable
        ))
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .categoryChange))
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
        #expect(session.effects.isEmpty)
    }

    private static func observeWithoutEffects(_ session: ScriptedOutputSession, route: Policy.Route) {
        let effects = session.effects
        let options = session.options
        session.send(route)
        #expect(session.effects == effects)
        #expect(session.options == options)
        #expect(session.decisionReasons.last == (route.category == .playback ? .keepalive : .unsupportedCategory))
    }
}
