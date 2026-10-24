import Testing
@testable import HailCore

@Suite struct AudioOutputRouteEchoTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .receiver], [Policy.Port.speaker, .receiver])
    func builtInChoiceSurvivesUSBUnplugAndReplug(_ previous: Policy.Port, _ selected: Policy.Port) {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.send(.init(
            outputs: [previous], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .routeConfigurationChange
        ))
        session.send(.init(
            outputs: [selected], inputs: [.usbAudio], previousOutputs: [previous],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        session.send(.init(
            outputs: [selected], inputs: [], previousOutputs: [selected],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        session.send(.init(
            outputs: [selected], inputs: [.usbAudio], previousOutputs: [selected], reason: .newDeviceAvailable
        ))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
    }

    @Test func builtInChoiceAfterInputLossUsesNotificationHistory() {
        let session = ScriptedOutputSession()
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.effects.isEmpty)
        session.send(.init(
            outputs: [.receiver], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
    }

    @Test func externalRepairEchoAllowsLaterGenuineEpisode() {
        let session = ScriptedOutputSession()
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(Self.repairRoute)
        session.drainEchoes()
        #expect(session.categories == 1)
        #expect(session.clears == 1)
        #expect(!session.state.userChoseBuiltIn)
        Self.usbCycle(session)
        session.drainEchoes()
        #expect(session.categories == 2)
        #expect(session.clears == 2)
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test(arguments: [0, 4])
    func builtInRepairEchoConservativelyLatchesEvenAfterUnrelatedEvents(_ intervening: Int) {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        for _ in 0..<intervening {
            session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .routeConfigurationChange))
        }
        session.drainEchoes()
        #expect(session.state.userChoseBuiltIn)
        let effects = session.effects
        Self.usbCycle(session)
        session.drainEchoes()
        #expect(session.effects == effects)
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .categoryChange))
        #expect(!session.state.userChoseBuiltIn)
        session.overrideOutputs = [.bluetoothA2DP]
        Self.usbCycle(session)
        session.drainEchoes()
        #expect(session.clears == 2)
    }

    static func usbCycle(_ session: ScriptedOutputSession) {
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker], reason: .newDeviceAvailable
        ))
    }

    static var repairRoute: Policy.Route {
        .init(outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
              previousInputs: [.builtInMic], reason: .newDeviceAvailable)
    }
}
