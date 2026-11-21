import Testing
@testable import HailCore

struct AudioOutputRouteCategoryChangeTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange, .override])
    func categoryWriteAndItsDelayedNotificationsKeepTheChoice(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        let speaker = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], reason: .override)
        session.send(speaker)
        var headset = Policy.Route(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP],
                                   previousOutputs: speaker.outputs, previousInputs: speaker.inputs, reason: reason)
        session.driver.write(.configure, before: speaker, actual: { headset }, perform: {})
        session.send(headset)
        #expect(session.driver.lastObservation?.attribution == .configure)
        #expect(session.state.userChoseBuiltIn)
        headset.settling = true
        session.send(headset)
        #expect(session.effects == [.restoreSpeaker])
    }

    @Test func failedReconfigureCannotClaimNextPickerTap() {
        let session = ScriptedOutputSession()
        let headset = Policy.Route(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], reason: .newDeviceAvailable)
        session.send(headset)
        let picker = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: headset.outputs,
                                  previousInputs: headset.inputs, reason: .override)
        session.driver.write(.preferredInput(.builtInMic), before: headset, actual: { picker }, perform: {})
        session.send(picker)
        #expect(session.driver.lastObservation?.attribution == .preferredInput(.builtInMic))
        #expect(!session.state.userChoseBuiltIn)

        var disconnected = picker
        disconnected.reason = .oldDeviceUnavailable
        session.send(disconnected)
        session.send(headset)
        #expect(throws: ScriptedOutputSession.Failure.self) {
            try session.driver.write(.configure, before: headset, actual: { headset }, perform: {
                throw ScriptedOutputSession.Failure.scripted
            })
        }
        #expect(session.driver.lastObservation?.status == .failed)
        session.send(picker)
        #expect(session.driver.lastObservation?.attribution == nil)
        #expect(session.driver.lastObservation?.reason == .userChoiceAssumed)
        AudioOutputRouteEchoTests.usbCycle(session)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }
}
