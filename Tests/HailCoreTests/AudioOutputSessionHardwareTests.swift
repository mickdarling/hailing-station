import Testing
@testable import HailCore

struct AudioOutputSessionHardwareTests {
    typealias Policy = AudioOutputRoutePolicy
    typealias Effect = AudioOutputRouteDriver.Effect

    @Test(arguments: [false, true])
    func skippedReceiverFallbackRemainsEligible(speakerDefault: Bool) {
        let driver = AudioOutputRouteDriver()
        let removal = Policy.Route(options: .init(defaultToSpeaker: speakerDefault), outputs: [.receiver],
                                   inputs: [.builtInMic], previousOutputs: [.headphones], reason: .oldDeviceUnavailable)
        var live = removal
        live.outputs = [.speaker]
        var writes: [Effect] = []
        driver.process(removal, actual: { live }, perform: { writes.append($0) })
        #expect(writes.isEmpty)
        #expect(driver.lastObservation?.status == .noWrite)
        #expect(driver.state.disconnectFallback == .waitingForReceiver)
        live.reason = .routeConfigurationChange
        live.outputs = [.receiver]
        let receiver = live
        driver.process(receiver, actual: { live }, perform: { effect in
            writes.append(effect)
            live.outputs = [.speaker]
            if case .setCategory(let options) = effect { live.options = options }
        })
        #expect(driver.lastObservation?.status == .applied)
        #expect(driver.lastObservation?.actual.outputs == [.speaker])
        driver.process(receiver, actual: { live }, perform: { writes.append($0) })
        #expect(driver.state.disconnectFallback == .applied)
        #expect(writes == [speakerDefault ? .restoreSpeaker : .setCategory(.init(defaultToSpeaker: true))])
    }

    @Test func skippedCategoryCannotClearLivePickerReceiver() {
        let driver = AudioOutputRouteDriver()
        var queued = AudioOutputRouteEchoTests.repairRoute
        queued.options.defaultToSpeaker = true
        var live = queued
        live.outputs = [.receiver]
        var writes: [Effect] = []
        driver.process(queued, actual: { live }, perform: { writes.append($0) })
        #expect(writes.isEmpty)
        live.reason = .routeConfigurationChange
        driver.process(live, actual: { live }, perform: { writes.append($0) })
        #expect(writes.isEmpty)
        live.reason = .override
        live.previousOutputs = [.speaker]
        driver.process(live, actual: { live }, perform: { writes.append($0) })
        #expect(driver.state.userChoseBuiltIn)
        #expect(writes.isEmpty)
    }

    @Test func inactiveA2DPWithOldSpeakerDefaultRequiresNeutralCategory() {
        let route = Policy.Route(options: .init(defaultToSpeaker: true, allowsA2DP: true), outputs: [.bluetoothA2DP],
                                 inputs: [.builtInMic], reason: .other, isActive: false)
        let desired = Policy.configurationOptions(for: route, allowsHFP: false, state: .init())
        #expect(!desired.defaultToSpeaker)
        #expect(route.needsSpeakerDefaultChange(to: desired.defaultToSpeaker))
    }

    @Test(arguments: [false, true], [false, true])
    func standaloneArrivalResolvesActualPair(allowsHFP: Bool, startsOnHFP: Bool) {
        let driver = AudioOutputRouteDriver()
        driver.ownership.configured(for: .standalone, continuing: true, allowsHFP: allowsHFP)
        driver.ownership.isActive = true
        let event = Policy.Route(options: .init(allowsA2DP: true, allowsHFP: allowsHFP), owner: .standalone,
                                 outputs: startsOnHFP ? [.bluetoothHFP] : [.bluetoothA2DP],
                                 inputs: startsOnHFP ? [.bluetoothHFP] : [.builtInMic],
                                 availableInputs: [.builtInMic, .bluetoothHFP], previousOutputs: [.speaker],
                                 previousInputs: [.builtInMic], reason: .newDeviceAvailable)
        var live = event
        var mic = startsOnHFP ? AudioPort.hfp : .builtIn
        var selections: [AudioPort] = []
        func deliver(_ notice: Policy.Route) {
            driver.routeChanged(notice, actual: { live }, perform: { _ in Issue.record("Unexpected output write") },
                                inputs: { ([.hfp, .builtIn], mic.id) }, select: { selections.append($0) })
        }
        deliver(event)
        // setPreferredInput returned successfully. The duplicate still reports the original pair.
        deliver(event)
        #expect(selections == (startsOnHFP == allowsHFP ? [] : [allowsHFP ? .hfp : .builtIn]))
        if let requested = selections.first {
            mic = requested
            live.inputs = mic == .hfp ? [.bluetoothHFP] : [.builtInMic]
            live.outputs = mic == .hfp ? [.bluetoothHFP] : [.bluetoothA2DP]
        }
        var reflected = live
        reflected.reason = .routeConfigurationChange
        deliver(reflected)
        #expect(selections.count == (startsOnHFP == allowsHFP ? 0 : 1))
        #expect(driver.lastObservation?.actual.inputs == (allowsHFP ? [.bluetoothHFP] : [.builtInMic]))
        #expect(driver.lastObservation?.actual.outputs == (allowsHFP ? [.bluetoothHFP] : [.bluetoothA2DP]))
    }

    @Test(arguments: [Policy.Owner.standalone, .capture])
    func mixablePlaybackRelinquishesStationOwnership(_ previousOwner: Policy.Owner) {
        let driver = AudioOutputRouteDriver()
        driver.ownership = .init(owner: previousOwner, isActive: true)
        let playback = Policy.Route(category: .playback, options: .init(mixWithOthers: true), owner: previousOwner,
                                    outputs: [.bluetoothA2DP], inputs: [], reason: .categoryChange)
        driver.routeChanged(playback, actual: { playback }, perform: { _ in Issue.record("Unexpected output write") },
                            inputs: { ([], nil) }, select: { _ in Issue.record("Unexpected mic request") })
        #expect(driver.ownership.owner == .unownedSession)
        #expect(!driver.ownership.isActive)
        #expect(driver.lastObservation?.reason == .keepalive)
        #expect(driver.lastObservation?.status == .noWrite)
    }
}
