import Testing
@testable import HailCore

@Suite struct AudioOutputRouteChoiceTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .receiver])
    func userChoiceSurvivesHardwareUntilExternalOutputReturns(_ output: Policy.Port) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(Self.choice(output))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
        session.send(.init(
            outputs: [output], inputs: [], previousOutputs: [output],
            previousInputs: [.usbAudio], reason: .oldDeviceUnavailable
        ))
        session.send(.init(outputs: [output], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
        session.send(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousOutputs: [output],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.drainEchoes()
        #expect(!session.state.userChoseBuiltIn)
        let categoriesBeforeBlip = session.categories
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.drainEchoes()
        #expect(session.categories == categoriesBeforeBlip + 1)
        #expect(session.clears == 1)
    }

    @Test func twoSuccessiveUserChoicesExecuteZeroEffects() {
        let session = ScriptedOutputSession()
        session.send(Self.choice(.speaker))
        session.drainEchoes()
        session.send(.init(
            outputs: [.bluetoothA2DP], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: [.usbAudio], reason: .override
        ))
        session.send(Self.choice(.receiver))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
    }

    @Test(arguments: [[], [Policy.Port.usbAudio]])
    func ambiguousOverrideWithNoPreviousOutputsExecutesZeroEffects(_ previousInputs: [Policy.Port]) {
        let session = ScriptedOutputSession()
        session.state.externalOutputSeen = true
        session.options.defaultToSpeaker = true
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousInputs: previousInputs, reason: .override
        ))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange, .newDeviceAvailable])
    func notificationsWithoutHardwareEvidenceExecuteZeroEffects(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.state = .init(externalOutputSeen: true, lastInputs: [.usbAudio], lastOutputs: [.speaker])
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: reason))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Policy.Category.playback, .other])
    func keepaliveExternalObservationPreservesCaptureChoice(_ category: Policy.Category) {
        let session = ScriptedOutputSession()
        session.state.userChoseBuiltIn = true
        session.send(.init(category: category, outputs: [.headphones], inputs: [], reason: .override))
        #expect(session.state.userChoseBuiltIn)
        #expect(session.state.externalOutputSeen)
        #expect(session.effects.isEmpty)
    }

    @Test func previousRouteUnchangedInputsTakePriorityOverCachedInputLoss() {
        let session = ScriptedOutputSession()
        session.state = .init(externalOutputSeen: true, lastInputs: [], lastOutputs: [.speaker])
        session.send(Self.choice(.speaker))
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
    }

    @Test func unknownPreviousOutputLeavesOverrideAlone() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.state = .init(externalOutputSeen: true)
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.other],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.effects.isEmpty)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
    }

    @Test func decisionExposesUserChoiceReason() {
        let decision = Policy.routeChange(Self.choice(.speaker), state: .init())
        #expect(decision.reason == .userChoiceAssumed)
        #expect(decision.state.userChoseBuiltIn)
        #expect(!decision.clearOverride)
    }

    private static func choice(_ output: Policy.Port) -> Policy.Route {
        .init(outputs: [output], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
              previousInputs: [.usbAudio], reason: .override)
    }
}
