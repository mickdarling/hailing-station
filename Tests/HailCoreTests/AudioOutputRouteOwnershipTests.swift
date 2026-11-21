import Testing
@testable import HailCore

@Suite struct AudioOutputRouteOwnershipTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test func coldConfigureEmptyThenA2DPWithoutArrival() {
        let session = ScriptedOutputSession()
        let inactive = Policy.Route(options: .init(defaultToSpeaker: true), outputs: [], inputs: [],
                                    reason: .other, isActive: false)
        session.options = Policy.configurationOptions(for: inactive, allowsHFP: false, state: session.state)
        #expect(!session.options.defaultToSpeaker)
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.builtInMic], reason: .other, settling: true))
        #expect(session.effects.isEmpty)
        #expect(session.driver.lastObservation?.actual.outputs == [.bluetoothA2DP])
    }

    @Test func neutralActivationWithReceiverFallsBackToSpeaker() {
        let session = ScriptedOutputSession()
        let settled = Policy.Route(outputs: [.receiver], inputs: [.builtInMic], reason: .other, settling: true)
        session.send(settled)
        session.drainEchoes()
        session.send(settled)
        #expect(session.effects == [.setCategory(.init(defaultToSpeaker: true))])
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test func disconnectWithOtherExternalOutputKeepsIt() {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.carAudio], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
                           reason: .oldDeviceUnavailable))
        #expect(session.effects.isEmpty)
        #expect(session.driver.lastObservation?.actual.outputs == [.carAudio])
    }

    @Test(arguments: [false, true])
    func newHeadsetClearsChoiceBeforeOutputMoves(active: Bool) {
        let session = ScriptedOutputSession()
        session.send(Self.picker)
        session.options.defaultToSpeaker = true
        var arrival = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], availableInputs: [.bluetoothHFP],
                                   reason: .newDeviceAvailable, isActive: active)
        session.send(arrival)
        #expect(!session.state.userChoseBuiltIn)
        if !active {
            #expect(session.effects.isEmpty)
            arrival.isActive = true
            arrival.reason = .other
            arrival.settling = true
            session.send(arrival)
        }
        #expect(session.effects == [.setCategory(.init()), .clearOverride])
    }

    @Test(arguments: [Policy.Port.usbAudio, .builtInMic], [false, true])
    func usbArrivalWithExistingHFPPreservesChoice(selectedInput: Policy.Port, priorHardwareNotice: Bool) {
        let session = ScriptedOutputSession()
        if priorHardwareNotice {
            session.send(.init(outputs: [.bluetoothA2DP], inputs: [.builtInMic], availableInputs: [.bluetoothHFP],
                               reason: .newDeviceAvailable))
        }
        var picker = Self.picker
        picker.availableInputs = [.bluetoothHFP]
        session.send(picker)
        var category = picker
        category.reason = .categoryChange
        category.availableInputs.append(.usbAudio)
        session.send(category)
        #expect(session.state.userChoseBuiltIn)
        session.send(.init(outputs: [.speaker], inputs: [selectedInput], availableInputs: [.usbAudio, .bluetoothHFP],
                           previousOutputs: [.speaker], previousInputs: [.builtInMic], reason: .newDeviceAvailable))
        #expect(session.state.userChoseBuiltIn)
        #expect(session.state.holdsBuiltInOutput)
        #expect(session.effects.isEmpty)
    }

    @Test func delayedRepairEchoNeverLatches() {
        let session = ScriptedOutputSession()
        session.send(AudioOutputRouteEchoTests.repairRoute)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .categoryChange))
        #expect(session.driver.lastObservation?.attribution == nil)
        session.drainEchoes()
        #expect(session.clears == 1)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.driver.lastObservation?.attribution == .releaseOverride)
    }

    @Test func pickerBeforeEchoSurvivesFailedClear() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.failure = .clearOverride
        session.send(AudioOutputRouteEchoTests.repairRoute)
        #expect(session.driver.lastObservation?.status == .failed)
        session.send(Self.picker)
        session.drainEchoes()
        AudioOutputRouteEchoTests.usbCycle(session)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.clears == 1)
    }

    @Test func ambiguousEchoRecordsNoDurableLatch() {
        let session = ScriptedOutputSession()
        session.send(AudioOutputRouteEchoTests.repairRoute)
        session.drainEchoes()
        #expect(session.driver.lastObservation?.reason == .ambiguous)
        #expect(session.driver.lastObservation?.status == .noWrite)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.state.holdsBuiltInOutput)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .other, settling: true))
        #expect(session.clears == 1)
        AudioOutputRouteEchoTests.usbCycle(session)
        #expect(session.clears == 2)
    }

    @Test(arguments: [Policy.Port.bluetoothA2DP, .bluetoothHFP], [false, true])
    func correctPairMakesNoWrites(_ output: Policy.Port, _ speakerDefault: Bool) {
        let session = ScriptedOutputSession()
        session.options = .init(defaultToSpeaker: speakerDefault, allowsA2DP: true, allowsHFP: output == .bluetoothHFP)
        let input: Policy.Port = output == .bluetoothHFP ? .bluetoothHFP : .builtInMic
        let route = Policy.Route(options: session.options, outputs: [output], inputs: [input],
                                 reason: .newDeviceAvailable)
        let desired = Policy.configurationOptions(for: route, allowsHFP: output == .bluetoothHFP, state: session.state)
        #expect(!route.needsSpeakerDefaultChange(to: desired.defaultToSpeaker))
        session.send(route)
        session.send(.init(outputs: [output], inputs: [input], reason: .other, settling: true))
        #expect(session.effects.isEmpty)
        #expect(session.driver.lastObservation?.actual.inputs == [input])
        #expect(session.driver.lastObservation?.status == .noWrite)
    }
}

extension AudioOutputRouteOwnershipTests {
    @Test func preferredInputEchoNeverBecomesPickerChoice() {
        let session = ScriptedOutputSession()
        let before = Policy.Route(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], reason: .other)
        let after = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: before.outputs,
                                 previousInputs: before.inputs, reason: .override)
        session.driver.write(.preferredInput(.builtInMic), before: before, actual: { after }, perform: {})
        session.send(after)
        #expect(session.driver.lastObservation?.attribution == .preferredInput(.builtInMic))
        session.send(after)
        #expect(session.driver.lastObservation?.attribution == nil)
        #expect(session.decisionReasons.last == .ambiguous)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test func staleReceiverNotificationCannotChangeAnAlreadyExternalRoute() {
        let driver = AudioOutputRouteDriver()
        let receiver = Policy.Route(outputs: [.receiver], inputs: [.builtInMic],
                                    previousOutputs: [.headphones], reason: .oldDeviceUnavailable)
        let external = Policy.Route(outputs: [.bluetoothA2DP], inputs: [.builtInMic], reason: .other)
        var effects: [AudioOutputRouteDriver.Effect] = []
        driver.process(receiver, actual: { external }, perform: { effects.append($0) })
        #expect(effects.isEmpty)
        #expect(driver.lastObservation?.actual.outputs == external.outputs)
    }

    @Test func activationRemembersHeadphonesSeenBeforeCategoryWrite() {
        let session = ScriptedOutputSession()
        let before = Policy.Route(outputs: [.bluetoothA2DP], inputs: [], reason: .other, isActive: false)
        let active = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], reason: .other, settling: true)
        session.driver.write(.configure, before: before, actual: { active }, perform: {})
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(active)
        #expect(session.effects == [.clearOverride])
        #expect(session.driver.lastObservation?.actual.outputs == [.bluetoothA2DP])
    }

    private static var picker: Policy.Route {
        .init(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
              previousInputs: [.builtInMic], reason: .override)
    }
}
