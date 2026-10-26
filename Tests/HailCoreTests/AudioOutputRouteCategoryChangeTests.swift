import Testing
@testable import HailCore

struct AudioOutputRouteCategoryChangeTests {
    typealias Policy = AudioOutputRoutePolicy

    @Test(arguments: [Policy.Port.speaker, .bluetoothHFP])
    func hardwareArrivalAfterToggleStillFollowsTheOwnerChoicePolicy(_ output: Policy.Port) {
        let session = Self.speakerChoice()
        session.categoryChangeMarker.arm()
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

    @Test func secondUnrelatedCategoryChangeClearsTheLatch() {
        let session = Self.speakerChoice()
        session.categoryChangeMarker.arm()
        session.send(Self.headsetCategoryChange)
        #expect(session.state.userChoseBuiltIn)
        session.send(Self.headsetCategoryChange)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Policy.Reason.newDeviceAvailable, .oldDeviceUnavailable])
    func hardwareBeforeTheCategoryNotificationCancelsAttribution(_ reason: Policy.Reason) {
        let session = Self.speakerChoice()
        session.categoryChangeMarker.arm()
        session.send(.init(outputs: [.speaker], inputs: [.builtInMic], reason: reason))
        #expect(session.state.userChoseBuiltIn)
        session.send(Self.headsetCategoryChange)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: [Duration.seconds(1), .seconds(5)])
    func missingNotificationCannotLeaveAStaleMarker(_ delay: Duration) {
        let session = Self.speakerChoice()
        let now = ContinuousClock.now
        session.categoryChangeMarker.arm(now: now)
        session.send(Self.headsetCategoryChange, now: now.advanced(by: delay))
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test func failedReconfigureCancelsAttribution() {
        let session = Self.speakerChoice()
        session.categoryChangeMarker.arm()
        session.categoryChangeMarker.cancel()
        session.send(Self.headsetCategoryChange)
        #expect(!session.state.userChoseBuiltIn)
        #expect(session.effects.isEmpty)
    }

    @Test(arguments: Policy.Reason.allCases)
    func markerNeverAttributesAnotherReason(_ reason: Policy.Reason) {
        var marker = AudioOutputCategoryChangeMarker()
        let now = ContinuousClock.now
        marker.arm(now: now)
        #expect(marker.consume(reason, now: now.advanced(by: .milliseconds(500))) == (reason == .categoryChange))
    }

    @Test func configurationNotificationDoesNotSpendTheCategoryMarker() {
        let session = Self.speakerChoice()
        session.categoryChangeMarker.arm()
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
