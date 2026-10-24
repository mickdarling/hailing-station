import Testing
@testable import HailCore

@Suite struct AudioOutputRouteDecisionTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .bluetoothA2DP])
    func airPodsConnectWhileSpeakerStuckRepairsOnce(_ repairedOutput: Policy.Port) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.overrideOutputs = [repairedOutput]
        // Newly seen AirPods are in notification history; current output is still speaker (#852).
        // Unchanged USB input makes this an output-only hardware episode, not an input-return repair.
        let connected = Policy.Route(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .newDeviceAvailable
        )
        session.send(connected)
        #expect(session.decisionReasons.last == .repairRequested)
        let repair: [AudioOutputRouteDriver.Effect] = [.setCategory(.init()), .clearOverride]
        #expect(session.effects == repair)
        session.send(connected)
        #expect(session.decisionReasons.last == .noHardwareEpisode)
        #expect(session.effects == repair)
        session.drainEchoes()
        for reason in [Policy.Reason.newDeviceAvailable, .categoryChange, .routeConfigurationChange] {
            session.send(.init(outputs: [repairedOutput], inputs: [.usbAudio], reason: reason))
        }
        session.drainEchoes()
        #expect(session.effects == repair)
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange, .other])
    func noHardwareEpisodeExplainsUnchangedRoute(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        session.state.externalOutputSeen = true
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: reason))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .noHardwareEpisode)
    }

    @Test func usbInputAloneReportsNoExternalEvidence() {
        let session = ScriptedOutputSession()
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .noExternalEvidence)
    }

    @Test(arguments: [[], [Policy.Port.other]])
    func incompleteRouteExplainsDeferredRepair(_ outputs: [Policy.Port]) {
        let session = ScriptedOutputSession()
        session.send(.init(
            outputs: outputs, inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .awaitingRoute)
    }

    @Test func activeExternalOutputExplainsNoRepair() {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .externalOutputActive)
    }

    @Test func unsupportedCategoryExplainsNoRepair() {
        let session = ScriptedOutputSession()
        session.send(.init(category: .other, outputs: [.speaker], inputs: [], reason: .newDeviceAvailable))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .unsupportedCategory)
    }
}
