import Testing
@testable import HailCore

struct AudioOutputSessionRoutingTests {
    typealias Policy = AudioOutputRoutePolicy
    typealias Effect = AudioOutputRouteDriver.Effect

    @Test func idleHFPToggleKeepsStandaloneRoutingActive() {
        let session = ScriptedOutputSession()
        let driver = session.driver
        driver.ownership = .init(owner: .standalone, isActive: true)
        driver.ownership.configure(.idleSetting, allowsHFP: true, category: { _, _ in
            Issue.record("Expected standalone reconfiguration")
        }, standalone: { preferences in
            driver.ownership.configured(for: .standalone, continuing: true, allowsHFP: preferences.allowsBluetoothHFP)
            session.options.allowsHFP = preferences.allowsBluetoothHFP
        })
        #expect(!driver.ownership.awaitingInputSelection)
        let ownership = driver.ownership
        let arrival = Policy.Route(owner: ownership.owner, outputs: [.speaker], inputs: [.builtInMic],
                                   availableInputs: [.bluetoothHFP], reason: .newDeviceAvailable,
                                   isActive: ownership.isActive,
                                   awaitingInputSelection: ownership.awaitingInputSelection)
        session.overrideOutputs = [.bluetoothHFP]
        session.send(arrival)
        #expect(session.driver.lastObservation?.actual.outputs == [.bluetoothHFP])
        var removal = arrival
        removal.outputs = [.receiver]
        removal.availableInputs = [.builtInMic]
        removal.previousOutputs = [.bluetoothHFP]
        removal.reason = .oldDeviceUnavailable
        session.send(removal)
        #expect(session.effects == [.clearOverride, .setCategory(.init(defaultToSpeaker: true, allowsHFP: true))])
    }

    @Test func standaloneSelectsSavedHFPMicrophoneBeforeSettlement() {
        let session = ScriptedOutputSession()
        let inactive = Policy.Route(outputs: [], inputs: [], reason: .other, isActive: false)
        var live = Policy.Route(owner: .standalone, outputs: [.bluetoothA2DP], inputs: [.builtInMic],
                                availableInputs: [.builtInMic, .bluetoothHFP], reason: .other)
        let preferences = AudioInputPreferences(allowsBluetoothHFP: true)
        session.options = Policy.configurationOptions(for: inactive, owner: .standalone,
                                                      allowsHFP: preferences.allowsBluetoothHFP, state: session.state)
        var selected: [AudioPort] = []
        var currentID = AudioPort.builtIn.id
        for _ in 0..<2 {
            session.driver.configureStandalone(preferences: preferences, prepare: {
                if !session.driver.ownership.isActive {
                    session.driver.write(.activation, before: inactive, actual: { live }, perform: {
                        session.driver.ownership.owner = .standalone
                        session.driver.ownership.isActive = true
                    })
                }
            }, inputs: { ([.builtIn, .hfp], currentID) }, select: { port in
                selected.append(port)
                session.driver.write(.preferredInput(.bluetoothHFP), before: live, actual: { live }, perform: {
                    currentID = port.id
                    live.inputs = [.bluetoothHFP]
                    live.outputs = [.bluetoothHFP]
                })
            }, reconcile: {
                live.settling = true
                live.awaitingInputSelection = session.driver.ownership.awaitingInputSelection
                session.send(live)
                #expect(session.driver.lastObservation?.actual.inputs == [.bluetoothHFP])
                #expect(session.driver.lastObservation?.actual.outputs == [.bluetoothHFP])
            })
        }
        #expect(selected == [.hfp])
        #expect(session.effects.isEmpty)
    }

    enum CategoryOutcome: CaseIterable, Sendable { case inputOnly, headsetSelected, ownerChanged }

    @Test(arguments: CategoryOutcome.allCases)
    func partialCategoryRepairChecksLiveOutputAndOwner(_ outcome: CategoryOutcome) {
        let driver = AudioOutputRouteDriver()
        var live = AudioOutputRouteEchoTests.repairRoute
        live.options.defaultToSpeaker = true
        var effects: [Effect] = []
        driver.process(live, actual: { live }, perform: { effect in
            effects.append(effect)
            switch effect {
            case .setCategory(let options):
                live.options = options
                live.inputs = [.builtInMic]
                if outcome == .ownerChanged { live.owner = .standalone }
                if outcome == .headsetSelected { live.outputs = [.bluetoothA2DP] }
            case .clearOverride: live.outputs = [.bluetoothA2DP]
            case .restoreSpeaker: Issue.record("Unexpected speaker fallback")
            }
        })
        let category = Effect.setCategory(.init())
        #expect(effects == (outcome == .inputOnly ? [category, .clearOverride] : [category]))
        #expect(driver.lastObservation?.actual.outputs == (outcome == .ownerChanged ? [.speaker] : [.bluetoothA2DP]))
        #expect(driver.lastObservation?.actual.inputs == [.builtInMic])
    }
}
