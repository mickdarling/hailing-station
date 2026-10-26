import Testing
@testable import HailCore

struct AudioOutputRouteBurstTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange],
          [Policy.Port.speaker, .bluetoothHFP])
    func bothBurstOrdersKeepTheLatchUntilGenuineHardware(_ first: Policy.Reason, _ output: Policy.Port) {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        let second: Policy.Reason = first == .categoryChange ? .routeConfigurationChange : .categoryChange
        for reason in [first, second, first, second] {
            session.send(Self.headsetChange(reason), now: now.advanced(by: .milliseconds(500)))
            #expect(session.state.userChoseBuiltIn)
            #expect(session.effects.isEmpty)
        }

        session.send(.init(
            outputs: [output], inputs: [.usbAudio], previousOutputs: [.bluetoothHFP],
            previousInputs: [.bluetoothHFP], reason: .newDeviceAvailable
        ), now: now.advanced(by: .milliseconds(600)))
        #expect(session.state.userChoseBuiltIn == (output == .speaker))
        #expect(session.state.externalOutputSeen)
        #expect(session.clears == 0)
        if output == .speaker {
            #expect(session.effects.isEmpty)
            #expect(session.decisionReasons.last == .userChoiceAssumed)
        } else {
            #expect(session.effects == [.setCategory(.init())])
            #expect(session.decisionReasons.last == .externalOutputActive)
        }
    }

    @Test func hardwareAfterTheBurstStillAllowsLaterUSBRecovery() {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        session.send(Self.headsetChange(.categoryChange), now: now)
        session.send(Self.headsetChange(.routeConfigurationChange), now: now)
        session.send(.init(outputs: [.bluetoothHFP], inputs: [.usbAudio], previousOutputs: [.bluetoothHFP],
                           previousInputs: [.bluetoothHFP], reason: .newDeviceAvailable), now: now)
        #expect(!session.state.userChoseBuiltIn)
        session.drainEchoes()

        session.send(.init(outputs: [.speaker], inputs: [], previousOutputs: [.bluetoothHFP],
                           previousInputs: [.usbAudio], reason: .oldDeviceUnavailable))
        #expect(session.state.inputLossPending)
        session.send(.init(outputs: [.speaker], inputs: [.usbAudio], reason: .newDeviceAvailable))
        #expect(session.decisionReasons.last == .repairRequested)
        #expect(session.clears == 1)
        session.drainEchoes()
        #expect(session.clears == 1)
    }

    @Test(arguments: [Policy.Reason.categoryChange, .routeConfigurationChange])
    func attributedNotificationsDoNotExtendTheDeadline(_ reason: Policy.Reason) {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        session.send(Self.headsetChange(reason), now: now.advanced(by: .milliseconds(999)))
        #expect(session.state.userChoseBuiltIn)
        session.send(Self.headsetChange(reason), now: now.advanced(by: .seconds(1)))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Policy.Reason.newDeviceAvailable, .oldDeviceUnavailable])
    func hardwareDuringTheBurstCancelsAllRemainingAttribution(_ hardware: Policy.Reason) {
        var marker = AudioOutputReconfigureMarker()
        let now = ContinuousClock.now
        marker.arm(now: now)
        let categoryAttributed = marker.attributes(.categoryChange, now: now)
        #expect(categoryAttributed)
        let hardwareAttributed = marker.attributes(hardware, now: now.advanced(by: .milliseconds(100)))
        #expect(!hardwareAttributed)
        for reason in [Policy.Reason.categoryChange, .routeConfigurationChange] {
            let attributed = marker.attributes(reason, now: now.advanced(by: .milliseconds(500)))
            #expect(!attributed)
        }
    }

    @Test func repeatedReconfigurationRefreshesTheBoundedWindow() {
        var marker = AudioOutputReconfigureMarker()
        let now = ContinuousClock.now
        marker.arm(now: now)
        marker.arm(now: now.advanced(by: .milliseconds(500)))
        let categoryAttributed = marker.attributes(.categoryChange, now: now.advanced(by: .seconds(1)))
        let configurationAttributed = marker.attributes(.routeConfigurationChange,
                                                        now: now.advanced(by: .milliseconds(1499)))
        #expect(categoryAttributed)
        #expect(configurationAttributed)
        for reason in [Policy.Reason.categoryChange, .routeConfigurationChange] {
            let attributed = marker.attributes(reason, now: now.advanced(by: .milliseconds(1500)))
            #expect(!attributed)
        }
    }

    private static func speakerChoice() -> ScriptedOutputSession {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .override))
        return session
    }

    private static func headsetChange(_ reason: Policy.Reason) -> Policy.Route {
        .init(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], previousOutputs: [.speaker],
              previousInputs: [.builtInMic], reason: reason)
    }
}
