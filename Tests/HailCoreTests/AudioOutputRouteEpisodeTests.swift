import Testing
@testable import HailCore

@Suite struct AudioOutputRouteEpisodeTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test func failedRepairCanRetryAfterAnotherInputBlip() {
        let first = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ), state: .init())
        // A failed effect consumes this attempt, but a later input episode permits a fresh attempt (#852).
        let lost = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [], previousInputs: [.usbAudio], reason: .override
        ), state: first.state)
        let returned = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable
        ), state: lost.state)
        #expect(returned.clearOverride)
    }

    @Test func usbUnplugOnSpeakerRetainsRememberedExternalOutput() {
        let lost = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ), state: .init(externalOutputSeen: true))
        #expect(lost.state.externalOutputSeen)
        let returned = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ), state: lost.state)
        #expect(returned.clearOverride)
    }

    @Test func builtInOverrideWithChangedInputIsAChoice() {
        let decision = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .override
        ), state: .init())
        #expect(!decision.clearOverride)
        #expect(decision.state.userChoseBuiltIn)
        #expect(decision.reason == .userChoiceAssumed)
    }

    @Test func builtInOverrideOnInputReturnIsAChoice() {
        let lost = Policy.routeChange(.init(
            outputs: [], inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ), state: .init())
        let returned = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], reason: .override
        ), state: lost.state)
        // A non-empty-input built-in override is a choice, including after an input loss (#852).
        #expect(!returned.clearOverride)
        #expect(returned.state.userChoseBuiltIn)
        let knownReturn = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker], reason: .override
        ), state: lost.state)
        #expect(!knownReturn.clearOverride)
        #expect(knownReturn.state.userChoseBuiltIn)
    }

    @Test func duplicateHardwareNotificationCannotRepairTwiceWithoutAnyEcho() {
        let session = ScriptedOutputSession()
        let route = AudioOutputRouteEchoTests.repairRoute
        session.send(route)
        session.send(route)
        #expect(session.categories == 1)
        #expect(session.clears == 1)
    }

    @Test func externalObservationDoesNotRearmUserChoiceRepair() {
        let restored = Policy.routeChange(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousInputs: [.usbAudio], reason: .override
        ), state: .init(externalOutputSeen: true))
        let userChoice = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ), state: restored.state)
        #expect(!userChoice.clearOverride)
    }
}
