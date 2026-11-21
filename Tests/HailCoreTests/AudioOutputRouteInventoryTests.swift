import Testing
@testable import HailCore

struct AudioOutputRouteInventoryTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test func wiredThenAirPodsWithSamePreviousRouteReleasesSpeaker() {
        let session = ScriptedOutputSession()
        let wired = Policy.Route(
            outputs: [.headphones], inputs: [.builtInMic], availableInputs: [.headsetMic],
            previousOutputs: [.speaker], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        )
        session.send(wired)
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.headphones],
                           previousInputs: [.builtInMic], reason: .override))
        session.send(wired)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
        var airPods = wired
        airPods.outputs = [.speaker]
        airPods.availableInputs.append(.bluetoothHFP)
        session.send(airPods)
        session.send(airPods)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects == [.clearOverride])
    }

    @Test(arguments: [false, true])
    func duplicateAirPodsArrivalAfterEnablingHFPPreservesSpeaker(visibleAtWrite: Bool) {
        let session = ScriptedOutputSession()
        var arrival = Policy.Route(outputs: [.bluetoothA2DP], inputs: [.builtInMic], availableInputs: [.builtInMic],
                                   previousOutputs: [.speaker], previousInputs: [.builtInMic],
                                   reason: .newDeviceAvailable)
        session.send(arrival)
        let generation = session.state.hardwareGeneration
        let pick = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], availableInputs: [.builtInMic],
                                previousOutputs: [.bluetoothA2DP], previousInputs: [.builtInMic], reason: .override)
        session.send(pick)
        #expect(session.state.userChoseBuiltIn)

        var category = pick
        category.reason = .categoryChange
        category.previousOutputs = [.speaker]
        category.options.allowsHFP = true
        if visibleAtWrite { category.availableInputs.append(.bluetoothHFP) }
        session.driver.write(.configure, before: pick, actual: { category }, perform: {
            session.options.allowsHFP = true
        })
        session.send(category)
        arrival.outputs = [.speaker]
        arrival.availableInputs.append(.bluetoothHFP)
        session.send(arrival)
        #expect(session.state.hardwareGeneration == generation)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.driver.lastObservation?.status == .noWrite)
        #expect(session.effects.isEmpty)
    }

    @Test func duplicateUSBRemovalAfterMicReturnsPreservesAirPods() {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        var removal = Policy.Route(outputs: [.speaker], inputs: [], previousOutputs: [.speaker],
                                   previousInputs: [.usbAudio], reason: .oldDeviceUnavailable)
        session.send(removal)
        removal.inputs = [.usbAudio]
        session.send(removal)
        #expect(session.state.externalOutputSeen)
        session.overrideOutputs = [.bluetoothA2DP]
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], availableInputs: [.usbAudio],
                           previousOutputs: [.speaker], reason: .newDeviceAvailable))
        #expect(session.effects == [.clearOverride])
        #expect(session.driver.lastObservation?.actual.outputs == [.bluetoothA2DP])
    }

    @Test func failedReceiverSettlementRetriesOnlyOnReconciliation() {
        let session = ScriptedOutputSession()
        let receiver = Policy.Route(outputs: [.receiver], inputs: [.builtInMic], reason: .other, settling: true)
        let fallback = AudioOutputRouteDriver.Effect.setCategory(.init(defaultToSpeaker: true))
        session.failure = fallback
        session.send(receiver)
        #expect(session.driver.lastObservation?.status == .failed)
        #expect(session.state.lastSettled == nil)
        var echo = receiver
        echo.settling = false
        echo.reason = .categoryChange
        echo.origin = .repairCategory
        session.send(echo)
        #expect(session.effects == [fallback])
        #expect(session.driver.lastObservation?.attribution == .repairCategory)
        session.send(receiver)
        #expect(session.driver.lastObservation?.status == .applied)
        #expect(session.state.lastSettled == receiver.pair)
        session.drainEchoes()
        session.send(receiver)
        #expect(session.effects == [fallback, fallback])
    }
}
