import Testing
@testable import HailCore

struct AudioOutputRouteBurstTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange])
    func bothBurstOrdersKeepTheLatchUntilGenuineHardware(_ first: Policy.Reason) {
        let session = ScriptedOutputSession()
        let speaker = Policy.Route(outputs: [.speaker], inputs: [.builtInMic], reason: .override)
        session.send(speaker)
        let second: Policy.Reason = first == .categoryChange ? .routeConfigurationChange : .categoryChange
        var route = Policy.Route(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP],
                                 previousOutputs: speaker.outputs, previousInputs: speaker.inputs, reason: first)
        session.driver.write(.configure, before: speaker, actual: { route }, perform: {})
        for reason in [first, second, first, second] {
            route.reason = reason
            session.send(route)
            #expect(session.state.userChoseBuiltIn)
            #expect(session.effects == [.restoreSpeaker])
        }
        route.reason = .newDeviceAvailable
        route.outputs = [.headphones]
        route.previousOutputs = [.bluetoothHFP]
        session.send(route)
        #expect(!session.state.userChoseBuiltIn)
        AudioOutputRouteEchoTests.usbCycle(session)
        #expect(session.clears == 1)
    }

    @Test func duplicateAvailabilityAfterPickerDoesNotReleaseSpeaker() {
        let session = ScriptedOutputSession()
        let arrival = Policy.Route(outputs: [.bluetoothA2DP], inputs: [.builtInMic],
                                   previousOutputs: [.speaker], reason: .newDeviceAvailable)
        session.send(arrival)
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], previousOutputs: [.bluetoothA2DP],
                           reason: .override))
        session.send(arrival)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }
}
