import Testing
@testable import HailCore

@Suite struct AudioOutputRouteRecoveryTests {
    typealias Policy = AudioOutputRoutePolicy

    // Port of the independent review's SwallowedEpisodeTests reproduction (#852).
    @Test(arguments: [Policy.Reason.other, .newDeviceAvailable])
    func keepaliveAvailabilityCannotConsumePendingCaptureRecovery(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        session.send(.init(outputs: [.bluetoothA2DP], inputs: [.usbAudio], reason: .newDeviceAvailable))
        session.send(.init(
            outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothA2DP],
            previousInputs: [.usbAudio], reason: .override
        ))
        #expect(session.state.inputLossPending)
        Self.observePlayback(session)
        // Capture configuration defers its audible fallback before emitting the category notification.
        let before = Policy.Route(category: .playback, outputs: [.speaker], inputs: [], reason: .other)
        session.options = Policy.configurationOptions(for: before, allowsHFP: false, state: session.state)
        session.send(.init(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker], reason: .categoryChange
        ))
        #expect(session.effects.isEmpty)
        let returned = Policy.Route(
            outputs: [.speaker], inputs: [.usbAudio], previousOutputs: [.speaker],
            previousInputs: reason == .other ? [] : [.usbAudio], reason: reason
        )
        session.send(returned)
        #expect(session.decisionReasons.last == .repairRequested)
        #expect(!session.state.userChoseBuiltIn)
        session.send(returned)
        #expect(session.decisionReasons.last == .noHardwareEpisode)
        session.drainEchoes()
        #expect(session.categories == 0)
        #expect(session.clears == 1)
        #expect(session.effects.count == 1)
        #expect(!session.options.defaultToSpeaker)
    }

    @Test(arguments: [Policy.Category.playback, .other], [false, true])
    func keepaliveAddsCurrentOrPreviousExternalEvidence(_ category: Policy.Category, _ previous: Bool) {
        let session = ScriptedOutputSession()
        session.state.userChoseBuiltIn = true
        session.options = .init(defaultToSpeaker: true, mixWithOthers: true)
        session.send(.init(
            category: category, outputs: previous ? [.speaker] : [.bluetoothA2DP], inputs: [],
            previousOutputs: previous ? [.bluetoothA2DP] : [.speaker], reason: .newDeviceAvailable
        ))
        #expect(session.state.externalOutputSeen)
        #expect(session.state.userChoseBuiltIn == previous)
        #expect(session.effects.isEmpty)
        #expect(session.options == .init(defaultToSpeaker: true, mixWithOthers: true))
    }

    private static func observePlayback(_ session: ScriptedOutputSession) {
        session.options = .init(mixWithOthers: true)
        let state = session.state
        let routes: [Policy.Route] = [
            .init(category: .playback, outputs: [.speaker], inputs: [], reason: .categoryChange),
            .init(category: .playback, outputs: [.bluetoothA2DP], inputs: [],
                  previousOutputs: [.speaker], reason: .newDeviceAvailable),
            .init(category: .playback, outputs: [.speaker], inputs: [],
                  previousOutputs: [.bluetoothA2DP], reason: .other)
        ]
        for route in routes {
            session.send(route)
            #expect(session.effects.isEmpty)
            #expect(session.options == .init(mixWithOthers: true))
            #expect(session.decisionReasons.last == .keepalive)
            #expect(session.state.inputLossPending == state.inputLossPending)
            #expect(session.state.lastAvailability == state.lastAvailability)
        }
    }
}
