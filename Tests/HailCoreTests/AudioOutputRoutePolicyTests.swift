import Testing
@testable import HailCore

@Suite struct AudioOutputRoutePolicyTests {
    typealias Policy = AudioOutputRoutePolicy
    static let externalOutputs: [Policy.Port] = [
        .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .usbAudio, .lineOut, .airPlay, .carAudio
    ]
    static let recoveryReasons: [Policy.Reason] = [
        .newDeviceAvailable, .override, .routeConfigurationChange
    ]

    @Test(arguments: Policy.Port.allCases)
    func configurationUsesSpeakerDefaultOnlyForBuiltInOutputs(_ port: Policy.Port) {
        for previousDefault in [false, true] {
            let options = Policy.configurationOptions(
                outputs: [port], options: .init(defaultToSpeaker: previousDefault, mixWithOthers: true)
            )
            #expect(options.defaultToSpeaker == (port == .speaker || port == .receiver))
            #expect(options.mixWithOthers)
        }
    }

    @Test func capturelessReplyUsesAudibleSpeakerIncludingAnInactiveRoute() {
        for outputs: [Policy.Port] in [[], [.receiver], [.speaker], [.receiver, .speaker]] {
            #expect(Policy.configurationOptions(outputs: outputs, options: .init()).defaultToSpeaker)
        }
    }

    @Test(arguments: Self.externalOutputs)
    func externalOutputWinsEvenInAMixedRoute(_ port: Policy.Port) {
        let options = Policy.configurationOptions(
            outputs: [.speaker, port], options: .init(defaultToSpeaker: true)
        )
        #expect(!options.defaultToSpeaker)
    }

    @Test func fieldSequenceRestoresExternalOutputExactlyOnce() {
        // 21:16Z: USB input disappears, then returns; AirPods are remembered from the previous route (#852).
        let blip = Policy.routeChange(.init(
            options: .init(defaultToSpeaker: true), outputs: [.speaker], inputs: [],
            previousOutputs: [.bluetoothA2DP], previousInputs: [.usbAudio], reason: .override
        ), state: .init())
        #expect(blip.state.externalOutputSeen)
        #expect(!blip.options.defaultToSpeaker)
        #expect(!blip.clearOverride)
        let returned = Policy.routeChange(.init(
            options: blip.options, outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable
        ), state: blip.state)
        #expect(returned.clearOverride)
        #expect(!returned.options.defaultToSpeaker)
        #expect(returned.state.attemptedInEpisode)
        for reason in Self.recoveryReasons {
            let repeated = Policy.routeChange(.init(
                options: returned.options, outputs: [.speaker], inputs: [.usbAudio], reason: reason
            ), state: returned.state)
            #expect(!repeated.clearOverride)
            #expect(!repeated.options.defaultToSpeaker)
        }
    }

    @Test(arguments: Policy.Reason.allCases, [Policy.Port.speaker, .receiver])
    func onlyPermittedReasonsRepairBuiltInFallback(_ reason: Policy.Reason, _ output: Policy.Port) {
        let decision = Policy.routeChange(.init(
            options: .init(defaultToSpeaker: true), outputs: [output], inputs: [.usbAudio],
            previousOutputs: [.bluetoothA2DP], previousInputs: [.builtInMic], reason: reason
        ), state: .init(hardwareChangePending: true))
        #expect(decision.clearOverride == Self.recoveryReasons.contains(reason))
        if Self.recoveryReasons.contains(reason) { #expect(!decision.options.defaultToSpeaker) }
    }

    @Test(arguments: Policy.Reason.allCases)
    func reapplyNotificationsCannotLoopEvenWhenTheRepairFails(_ reason: Policy.Reason) {
        let repaired = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.builtInMic], reason: .override
        ), state: .init())
        let ownNotification = Policy.routeChange(.init(
            options: repaired.options, outputs: [.speaker], inputs: [.usbAudio], reason: reason
        ), state: repaired.state)
        #expect(!ownNotification.clearOverride)
    }

    @Test(arguments: Self.externalOutputs, Policy.Reason.allCases)
    func seeingExternalOutputRemovesSpeakerDefaultWithoutClearingAnOverride(
        _ output: Policy.Port, _ reason: Policy.Reason
    ) {
        let decision = Policy.routeChange(.init(
            options: .init(defaultToSpeaker: true), outputs: [output], inputs: [.usbAudio], reason: reason
        ), state: .init(externalOutputSeen: true, restoreAttempted: true,
                       lastInputs: [.usbAudio], lastOutputs: [output]))
        #expect(!decision.options.defaultToSpeaker)
        #expect(!decision.clearOverride)
        #expect(decision.state.externalOutputSeen)
        #expect(decision.state.restoreAttempted)
    }
}

extension AudioOutputRoutePolicyTests {
    @Test(arguments: Policy.Port.allCases, Policy.Reason.allCases)
    func keepaliveRemainsUntouched(_ output: Policy.Port, _ reason: Policy.Reason) {
        let original = Policy.Options(defaultToSpeaker: false, mixWithOthers: true)
        let state = Policy.State(externalOutputSeen: true)
        let decision = Policy.routeChange(.init(
            category: .playback, options: original, outputs: [output], inputs: [.usbAudio],
            previousOutputs: [.bluetoothA2DP], reason: reason
        ), state: state)
        #expect(decision.options == original)
        #expect(!decision.clearOverride)
        #expect(decision.state == state)
    }

    @Test(arguments: Policy.Reason.allCases)
    func usbMicAloneDoesNotProveAnExternalOutputExists(_ reason: Policy.Reason) {
        let decision = Policy.routeChange(.init(
            options: .init(defaultToSpeaker: true), outputs: [.speaker], inputs: [.usbAudio], reason: reason
        ), state: .init())
        #expect(!decision.clearOverride)
        #expect(decision.options.defaultToSpeaker)
    }

    @Test func removalForgetsExternalOutputAndExternalObservationDoesNotRearm() {
        let remembered = Policy.State(externalOutputSeen: true, restoreAttempted: true)
        let removed = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.headphones], reason: .oldDeviceUnavailable
        ), state: remembered)
        #expect(!removed.state.externalOutputSeen)
        #expect(removed.options.defaultToSpeaker)
        let later = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.builtInMic], reason: .categoryChange
        ), state: removed.state)
        #expect(!later.clearOverride)
        let restored = Policy.routeChange(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .override
        ), state: remembered)
        let nextFallback = Policy.routeChange(.init(
            outputs: [.receiver], inputs: [.usbAudio], reason: .routeConfigurationChange
        ), state: restored.state)
        #expect(!nextFallback.clearOverride)
    }

    @Test func usbMicUnplugDoesNotForgetTheSeparateAirPodsOutput() {
        let unplugged = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ), state: .init(externalOutputSeen: true))
        #expect(unplugged.state.externalOutputSeen)
        #expect(!unplugged.clearOverride)
        let replugged = Policy.routeChange(.init(
            outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable
        ), state: unplugged.state)
        #expect(replugged.clearOverride)
    }

    @Test func unpluggingHeadphonesRestoresAnAudibleReceiverFallback() {
        let unplugged = Policy.routeChange(.init(
            outputs: [.receiver], inputs: [.builtInMic], previousOutputs: [.headphones], reason: .oldDeviceUnavailable
        ), state: .init(externalOutputSeen: true))
        #expect(unplugged.options.defaultToSpeaker)
        #expect(!unplugged.clearOverride)
    }

    @Test(arguments: Policy.Port.allCases, Policy.Reason.allCases)
    func unrelatedCategoriesRemainUntouched(_ output: Policy.Port, _ reason: Policy.Reason) {
        for speakerDefault in [false, true] {
            let original = Policy.Options(defaultToSpeaker: speakerDefault)
            let state = Policy.State(externalOutputSeen: true, restoreAttempted: true)
            let decision = Policy.routeChange(.init(
                category: .other, options: original, outputs: [output], inputs: [], reason: reason
            ), state: state)
            #expect(decision.options == original)
            #expect(!decision.clearOverride)
            #expect(decision.state == state)
        }
    }

    @Test(arguments: [[], [Policy.Port.other]])
    func absentOrUnknownOutputDoesNotRestore(_ outputs: [Policy.Port]) {
        let decision = Policy.routeChange(.init(
            outputs: outputs, inputs: [.usbAudio], reason: .newDeviceAvailable
        ), state: .init(externalOutputSeen: true))
        #expect(!decision.clearOverride)
    }
}
