import Testing
@testable import HailCore

@Suite struct AudioOutputRouteHistoryTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .receiver])
    func changedInputChoiceSurvivesUSBConnectionAndLaterCycles(_ output: Policy.Port) {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], reason: .newDeviceAvailable))
        session.options.defaultToSpeaker = true
        session.send(.init(
            outputs: [output], inputs: [.builtInMic], previousOutputs: [.bluetoothHFP],
            previousInputs: [.bluetoothHFP], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        #expect(!session.state.inputLossPending)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
        #expect(session.effects.isEmpty)
        session.send(.init(
            outputs: [output], inputs: [.usbAudio], previousOutputs: [output],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        for _ in 0..<3 {
            session.send(.init(
                outputs: [output], inputs: [.builtInMic], previousOutputs: [output],
                previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
            ))
            session.send(.init(
                outputs: [output], inputs: [.usbAudio], previousOutputs: [output],
                previousInputs: [.builtInMic], reason: .newDeviceAvailable
            ))
            session.drainEchoes()
            #expect(session.effects.isEmpty)
            #expect(session.state.userChoseBuiltIn)
        }
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange, .other],
          [Policy.Port.speaker, .bluetoothA2DP])
    func warmAirPodsConnectionRepairsOnceAcrossDuplicateNotifications(
        _ priorReason: Policy.Reason, _ repairedOutput: Policy.Port
    ) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.overrideOutputs = [repairedOutput]
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: priorReason))
        // Exact original AirPods notification, despite the already-cached speaker/USB route (#852).
        let connected = Policy.Route(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .newDeviceAvailable
        )
        session.send(connected)
        #expect(session.decisionReasons.last == .repairRequested)
        let repair: [AudioOutputRouteDriver.Effect] = [.setCategory(.init()), .clearOverride]
        #expect(session.effects == repair)
        for reason in [Policy.Reason.categoryChange, .routeConfigurationChange, .other] {
            session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: reason))
            session.send(connected)
            #expect(session.decisionReasons.last == .noHardwareEpisode)
            #expect(session.effects == repair)
        }
        session.drainEchoes()
        session.send(connected)
        session.drainEchoes()
        #expect(session.effects == repair)
    }
}
