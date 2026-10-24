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

    @Test func repairEchoesDoNotChooseBuiltInOrPreventNextEpisode() {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        session.drainEchoes()
        #expect(session.categories == 1)
        #expect(session.clears == 1)
        #expect(!session.state.userChoseBuiltIn)
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker], reason: .newDeviceAvailable
        ))
        session.drainEchoes()
        #expect(session.categories == 2)
        #expect(session.clears == 2)
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test func ownEchoTokenDoesNotMatchAnotherPreviousRoute() {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.receiver],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        session.drainEchoes()
        #expect(session.state.userChoseBuiltIn)
        #expect(session.clears == 1)
    }

    @Test func consumedEchoTokenCannotHideASubsequentMatchingChoice() {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        session.drainEchoes()
        #expect(!session.state.userChoseBuiltIn)
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        #expect(session.categories == 1)
        #expect(session.clears == 1)
    }

    @Test func unusedOwnEchoTokensExpireBeforeLaterUserChoice() {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        for _ in 0..<3 {
            session.send(.init(
                outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
                previousInputs: [.usbAudio], reason: .routeConfigurationChange
            ))
        }
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.userChoseBuiltIn)
        session.drainEchoes()
        #expect(session.clears == 1)
        #expect(session.categories == 1)
    }

    private static var repairRoute: Policy.Route {
        .init(outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
              previousInputs: [.builtInMic], reason: .override)
    }
}
