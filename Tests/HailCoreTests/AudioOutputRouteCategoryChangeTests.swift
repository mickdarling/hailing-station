import Testing
@testable import HailCore

struct AudioOutputRouteCategoryChangeTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .bluetoothHFP])
    func hardwareArrivalAfterToggleStillFollowsTheOwnerChoicePolicy(_ output: Policy.Port) {
        let session = Self.speakerChoice()
        session.reconfigureMarker.arm()
        session.send(Self.headsetCategoryChange)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)

        session.send(.init(
            outputs: [output], inputs: [.builtInMic], availableInputs: [.builtInMic, .bluetoothHFP],
            previousOutputs: [.speaker], previousInputs: [.builtInMic], reason: .newDeviceAvailable
        ))
        session.drainEchoes()
        #expect(session.state.userChoseBuiltIn == (output == .speaker))
        #expect(session.state.externalOutputSeen)
        if output == .speaker {
            #expect(session.effects.isEmpty)
            #expect(session.decisionReasons.last == .userChoiceAssumed)
        } else {
            #expect(session.effects == [.setCategory(.init())])
            #expect(!session.options.defaultToSpeaker)
        }
    }

    @Test func repeatedCategoryChangesWithinTheWindowKeepTheLatch() {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        for delay in [Duration.zero, .milliseconds(500), .milliseconds(999)] {
            session.send(Self.headsetCategoryChange, now: now.advanced(by: delay))
            #expect(session.state.userChoseBuiltIn)
        }
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Policy.Reason.newDeviceAvailable, .oldDeviceUnavailable],
          [Policy.Reason.categoryChange, .routeConfigurationChange])
    func hardwareBeforeTheNotificationCancelsAttribution(_ hardware: Policy.Reason, _ reason: Policy.Reason) {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: hardware), now: now)
        #expect(session.state.userChoseBuiltIn)
        var change = Self.headsetCategoryChange
        change.reason = reason
        session.send(change, now: now.advanced(by: .milliseconds(500)))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Duration.seconds(1), .seconds(5)],
          [Policy.Reason.categoryChange, .routeConfigurationChange])
    func missingNotificationCannotLeaveAStaleMarker(_ delay: Duration, _ reason: Policy.Reason) {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.reconfigureMarker.arm(now: now)
        var change = Self.headsetCategoryChange
        change.reason = reason
        session.send(change, now: now.advanced(by: delay))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test func failedReconfigureCancelsAttribution() {
        let session = Self.speakerChoice()
        session.reconfigureMarker.arm()
        session.reconfigureMarker.cancel()
        session.send(Self.headsetCategoryChange)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: Policy.Reason.allCases)
    func markerAttributesOnlyCategoryAndConfigurationChanges(_ reason: Policy.Reason) {
        var marker = AudioOutputReconfigureMarker()
        let now = ContinuousClock.now
        marker.arm(now: now)
        let expected = reason == .categoryChange || reason == .routeConfigurationChange
        #expect(marker.attributes(reason, now: now.advanced(by: .milliseconds(500))) == expected)
    }

    @Test func configurationNotificationKeepsAttributionForTheCategoryNotification() {
        let session = Self.speakerChoice()
        session.reconfigureMarker.arm()
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .routeConfigurationChange))
        session.send(Self.headsetCategoryChange)
        #expect(session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    private static func speakerChoice() -> ScriptedOutputSession {
        let session = ScriptedOutputSession()
        session.options.defaultToSpeaker = true
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: .override))
        return session
    }

    private static var headsetCategoryChange: Policy.Route {
        .init(outputs: [.bluetoothHFP], inputs: [.bluetoothHFP], previousOutputs: [.speaker],
              previousInputs: [.builtInMic], reason: .categoryChange)
    }
}
