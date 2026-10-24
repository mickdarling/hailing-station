import Testing
@testable import HailCore

@Suite struct AudioOutputRouteEpisodeTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test func failedRepairCanRetryAfterAnotherInputBlip() {
        let first = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .override
        ), state: .init())
        // The original backend saved this state even when applying the decision threw (#852).
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
        ), state: .init(externalOutputSeen: true, restoreAttempted: true))
        #expect(lost.state.externalOutputSeen)
        let returned = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ), state: lost.state)
        #expect(returned.clearOverride)
    }

    @Test func externalObservationDoesNotRearmUserChoiceRepair() {
        let restored = Policy.routeChange(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousInputs: [.usbAudio], reason: .override
        ), state: .init(externalOutputSeen: true, restoreAttempted: true))
        let userChoice = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ), state: restored.state)
        #expect(!userChoice.clearOverride)
    }
}
