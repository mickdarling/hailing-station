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
        #expect(session.categories == 0)
        #expect(session.clears == 1)
        #expect(!session.state.userChoseBuiltIn)
        Self.usbCycle(session)
        session.drainEchoes()
        #expect(session.categories == 0)
        #expect(session.clears == 2)
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test(arguments: [0, 4])
    func builtInRepairEchoStaysAmbiguousAcrossCategoryNotifications(_ intervening: Int) {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        for _ in 0..<intervening {
            session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .routeConfigurationChange))
        }
        session.drainEchoes()
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .ambiguous)
        session.overrideOutputs = [.bluetoothA2DP]
        Self.usbCycle(session)
        session.drainEchoes()
        #expect(session.clears == 2)
    }

    @Test(arguments: [false, true])
    func delayedReleaseFromSpeakerToReceiverIsAmbiguous(failedInputBetweenEchoes: Bool) {
        let session = ScriptedOutputSession()
        session.send(Self.repairRoute)
        #expect(session.driver.lastObservation?.actual.outputs == [.speaker])
        session.drainEchoes()
        #expect(session.driver.lastObservation?.reason == .ambiguous)
        #expect(!session.state.userChoseBuiltIn)
        if failedInputBetweenEchoes {
            let speaker = Self.repairRoute
            #expect(throws: FakeAudioError.self) {
                try session.driver.write(.preferredInput(.builtInMic), before: speaker, actual: { speaker }, perform: {
                    throw FakeAudioError.selectionFailed
                })
            }
            #expect(session.driver.lastObservation?.status == .failed)
        }
        let receiver = Policy.Route(outputs: [.receiver], inputs: [.usbAudio], previousOutputs: [.speaker],
                                    previousInputs: [.usbAudio], reason: .override)
        session.send(receiver)
        #expect(session.driver.lastObservation?.attribution == .releaseOverride)
        #expect(session.driver.lastObservation?.reason == .ambiguous)
        session.send(receiver)
        session.send(.init(outputs: [.receiver], inputs: [.usbAudio], reason: .other, settling: true))
        #expect(session.driver.lastObservation?.reason == .ambiguous)
        #expect(session.driver.lastObservation?.status == .noWrite)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects == [.clearOverride])
    }

    @Test func duplicateRemovalKeepsSpeakerFallbackEchoAttribution() {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        let removal = Policy.Route(outputs: [.receiver], inputs: [.builtInMic], previousOutputs: [.headphones],
                                   previousInputs: [.builtInMic], reason: .oldDeviceUnavailable)
        session.send(removal)
        var duplicate = removal
        duplicate.outputs = [.speaker]
        session.send(duplicate)
        session.drainEchoes()
        #expect(session.effects == [.restoreSpeaker])
        #expect(session.driver.lastObservation?.attribution == .restoreSpeaker)
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test(arguments: [false, true])
    func confirmedClearThenPickerReversalSurvivesUSB(speakerDefault: Bool) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = speakerDefault
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(Self.repairRoute)
        session.drainEchoes()
        #expect(session.driver.lastObservation?.attribution == .releaseOverride)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.bluetoothA2DP],
                           previousInputs: [.usbAudio], reason: .override))
        #expect(session.driver.lastObservation?.attribution == nil)
        #expect(session.state.userChoseBuiltIn)
        Self.usbCycle(session)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.categories == (speakerDefault ? 1 : 0))
        #expect(session.clears == 1)
    }

    @Test func duplicateArrivalWithChangedCurrentOutputPreservesPicker() {
        let session = ScriptedOutputSession()
        var notice = Policy.Route(
            outputs: [.speaker], inputs: [.builtInMic], availableInputs: [.bluetoothHFP],
            previousOutputs: [.speaker], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        )
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(notice)
        session.drainEchoes()
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
                           previousInputs: [.builtInMic], reason: .override))
        notice.outputs = [.bluetoothA2DP]
        session.send(notice)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects == [.clearOverride])
    }
}

extension AudioOutputRouteEchoTests {
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
