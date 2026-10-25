import Testing
@testable import HailCore

@Suite struct AudioOutputRouteBluetoothTests {
    typealias Policy = AudioOutputRoutePolicy
    static let bluetoothInputs: [Policy.Port] = [.bluetoothHFP, .bluetoothLE]

    @Test(arguments: Self.bluetoothInputs, [false, true])
    func firstAirPodsAvailabilityRepairsOnce(_ port: Policy.Port, _ warm: Bool) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        if warm {
            session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .categoryChange))
        }
        let connected = Self.available(port, warm: warm)
        session.send(connected)
        #expect(session.decisionReasons.last == .repairRequested)
        let repair: [AudioOutputRouteDriver.Effect] = [.setCategory(.init()), .clearOverride]
        #expect(session.effects == repair)
        #expect(session.state.externalOutputSeen)
        session.send(connected)
        #expect(session.decisionReasons.last == .noHardwareEpisode)
        #expect(session.effects == repair)
        session.drainEchoes()
        session.send(connected)
        session.drainEchoes()
        #expect(session.effects == repair)
        #expect(session.categories == 1)
        #expect(session.clears == 1)
    }

    @Test(arguments: Policy.Port.allCases.filter { !Self.bluetoothInputs.contains($0) })
    func otherAvailableInputsAreNotOutputEvidence(_ port: Policy.Port) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(Self.available(port))
        #expect(session.effects.isEmpty)
        #expect(session.decisionReasons.last == .noExternalEvidence)
        #expect(!session.state.externalOutputSeen)
        #expect(session.options.defaultToSpeaker)
    }

    @Test(arguments: Self.bluetoothInputs)
    func ownerChoiceSurvivesFirstAirPodsAvailability(_ port: Policy.Port) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .override))
        session.send(Self.available(port, warm: true))
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state.externalOutputSeen)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.decisionReasons.last == .userChoiceAssumed)
    }

    @Test(arguments: Self.bluetoothInputs, [Policy.Category.playback, .other])
    func keepaliveOnlyCachesAvailableBluetoothEvidence(_ port: Policy.Port, _ category: Policy.Category) {
        let session = ScriptedOutputSession()
        session.options = .init(defaultToSpeaker: true, mixWithOthers: true)
        session.state = .init(userChoseBuiltIn: true, inputLossPending: true,
                              lastInputs: [], lastOutputs: [.speaker])
        var expected = session.state
        expected.externalOutputSeen = true
        var route = Self.available(port)
        route.category = category
        route.inputs = []
        session.send(route)
        session.drainEchoes()
        #expect(session.effects.isEmpty)
        #expect(session.state == expected)
        #expect(session.options == .init(defaultToSpeaker: true, mixWithOthers: true))
        #expect(session.decisionReasons.last == (category == .playback ? .keepalive : .unsupportedCategory))
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange, .other])
    func availabilityEvidenceRequiresNewDeviceReason(_ reason: Policy.Reason) {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        var route = Self.available(.bluetoothHFP)
        route.reason = reason
        session.send(route)
        #expect(session.effects.isEmpty)
        #expect(!session.state.externalOutputSeen)
        #expect(!session.state.userChoseBuiltIn)
    }

    @Test func keepaliveAvailabilityPreservesPendingCaptureRecovery() {
        let session = ScriptedOutputSession()
        session.state = .init(inputLossPending: true, lastInputs: [], lastOutputs: [.speaker])
        var playback = Self.available(.bluetoothHFP)
        playback.category = .playback
        playback.inputs = []
        session.send(playback)
        #expect(session.effects.isEmpty)
        #expect(session.state.inputLossPending)
        #expect(session.state.lastAvailability == nil)
        session.options.defaultToSpeaker = true
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .other))
        #expect(session.effects == [.setCategory(.init()), .clearOverride])
        #expect(!session.state.inputLossPending)
    }

    @Test(arguments: [false, true])
    func failedBluetoothRepairRetriesOnNextHardwareEpisode(_ failClear: Bool) {
        let session = ScriptedOutputSession()
        session.failure = failClear ? .clearOverride : .setCategory(.init())
        let connected = Self.available(.bluetoothHFP)
        session.send(connected)
        #expect(session.applyResult == .failed)
        let attempts = session.effects
        session.send(connected)
        #expect(session.effects == attempts)
        session.drainEchoes()
        session.send(.init(
            outputs: [.speaker], inputs: [.builtInMic], reason: .oldDeviceUnavailable
        ))
        // Removal may restore the speaker default; count only the next availability's repair effects.
        let categoriesBeforeRetry = session.categories
        let clearsBeforeRetry = session.clears
        session.send(connected)
        #expect(session.applyResult == .succeeded)
        #expect(session.categories == categoriesBeforeRetry + 1)
        #expect(session.clears == clearsBeforeRetry + 1)
        session.drainEchoes()
    }

    private static func available(_ port: Policy.Port, warm: Bool = false) -> Policy.Route {
        .init(outputs: [.speaker], inputs: [.builtInMic], availableInputs: [port],
              previousOutputs: warm ? [.speaker] : [], previousInputs: warm ? [.builtInMic] : [],
              reason: .newDeviceAvailable)
    }
}
