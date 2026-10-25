import Testing
@testable import HailCore

@Suite struct AudioOutputRouteInterleavingTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [0, 1, 2], [Policy.Port.speaker, .receiver])
    func userChoiceAfterRepairSurvivesLaterUSBCycles(_ intervening: Int, _ output: Policy.Port) {
        let session = ScriptedOutputSession()
        session.send(AudioOutputRouteEchoTests.repairRoute)
        #expect(session.clears == 1)
        for reason in [Policy.Reason.categoryChange, .routeConfigurationChange].prefix(intervening) {
            session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: reason))
        }
        Self.chooseBuiltIn(session, output: output)
        // Do not drain pending effects first: this reproduces a user choice before our echo arrives (#852).
        let effects = session.effects
        Self.checkLaterCycles(session, effects: effects)
    }

    @Test func usbLossThenUserChoiceBeforeAvailabilitySurvivesLaterCycles() {
        let session = ScriptedOutputSession()
        session.send(AudioOutputRouteEchoTests.repairRoute)
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        Self.chooseBuiltIn(session, output: .receiver)
        let effects = session.effects
        session.send(.init(outputs: [.receiver], inputs: [.usbAudio], reason: .newDeviceAvailable))
        Self.checkLaterCycles(session, effects: effects)
    }

    @Test func throwingClearWithoutEchoCannotSwallowAUserChoice() {
        let session = ScriptedOutputSession()
        session.failure = .clearOverride
        session.send(AudioOutputRouteEchoTests.repairRoute)
        #expect(session.clears == 1)
        Self.chooseBuiltIn(session, output: .speaker)
        let effects = session.effects
        Self.checkLaterCycles(session, effects: effects)
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange])
    func categoryAndConfigurationAloneNeverRepairOrLatch(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.state = .init(externalOutputSeen: true, inputLossPending: true, lastInputs: [])
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP], reason: reason
        ))
        #expect(session.effects.isEmpty)
        #expect(!session.state.userChoseBuiltIn)
        // They can observe external output and clear a prior choice, still without an effect.
        session.state.userChoseBuiltIn = true
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: reason))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.state.externalOutputSeen)
        #expect(session.effects.isEmpty)
    }

    private static func chooseBuiltIn(_ session: ScriptedOutputSession, output: Policy.Port) {
        let effects = session.effects
        session.send(.init(
            outputs: [output], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
        #expect(session.effects == effects)
    }

    private static func checkLaterCycles(_ session: ScriptedOutputSession, effects: [AudioOutputRouteDriver.Effect]) {
        for _ in 0..<2 {
            AudioOutputRouteEchoTests.usbCycle(session)
            session.drainEchoes()
            #expect(session.state.userChoseBuiltIn)
            #expect(session.effects == effects)
        }
    }
}
