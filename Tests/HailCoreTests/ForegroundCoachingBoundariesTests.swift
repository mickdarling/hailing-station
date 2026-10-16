import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingBoundariesTests {
    @Test func aggregatePCMLimitAndMissingFinalAreTerminal() async throws {
        for missingFinal in [true, false] {
            let rig = try ForegroundRig()
            rig.speech.handler = { emit in
                for index in 0..<(missingFinal ? 1 : 13) {
                    try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                        sequence: index, isFinal: false, bytes: Data(repeating: 1, count: 48_000)))
                }
            }
            try rig.driver.enable(participantAwareness: true)
            let child = try #require(rig.children.first), lease = try #require(child.leases.last)
            child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
            #expect(rig.driver.status == .off)
            #expect(rig.owners[0].player.scheduled.isEmpty)
            #expect(rig.owners[0].session.qualification == nil)
        }
    }

    @Test func noncontiguousSpeechAndProviderFailureStopWithoutPublication() async throws {
        for failure in [true, false] {
            let rig = try ForegroundRig()
            rig.speech.handler = { emit in
                if failure { throw ForegroundCoachingError.invalidSpeech }
                try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                    sequence: 1, isFinal: true, bytes: Data([1, 0])))
            }
            try rig.driver.enable(participantAwareness: true)
            let child = try #require(rig.children.first), lease = try #require(child.leases.last)
            child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
            #expect(rig.driver.status == .off && rig.owners[0].player.scheduled.isEmpty)
        }
    }

    @Test func qualifiedAppleCompositionRetainsItsFinalRouteGateThroughForegroundPorts() async throws {
        let time = ForegroundTestClock(), capture = FakeAudioCapture(), speech = ForegroundTestSpeech()
        let center = NotificationCenter(), event = Notification.Name("AuthoredForegroundRouteLoss")
        var privateRoute = true
        let monitor = CoachingOutputMonitor(snapshot: {
            privateRoute ? [CoachingObservedPort(uid: "authored-wired", kind: .wiredHeadphones)] : []
        }, center: center, names: [event])
        var scheduled = 0
        let player = CoachingEngineRenderer(operations: .init(ready: { true }, schedule: { _, _ in
            scheduled += 1
        }, control: { _ in }), observe: { monitor.observe() })
        var child: ForegroundTestChild?
        let driver = try ForegroundCoaching(listenerID: "private-coach", transport: { hooks in
            let owned = ForegroundTestChild(hooks); child = owned; return owned
        }, audio: { hooks in
            try ApplePrivateCoaching(capture: capture, player: player, monitor: monitor,
                                     listenerID: "private-coach", hooks: hooks, clock: time.clock)
        }, speech: speech, clock: time.clock)
        try driver.enable(participantAwareness: true)
        let transport = try #require(child), lease = try #require(transport.leases.last)
        speech.handler = { emit in
            privateRoute = false
            center.post(name: event, object: nil)
            try emit(coachingPCM)
        }
        transport.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(scheduled == 0 && driver.status == .off && capture.stopCount == 1)
    }
}
