#if os(macOS)
import AppKit
import AVFAudio
import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingInterruptionSimulationTests {
    @Test func unrelatedClientEngineAndAppFocusDoNotCancelQualifiedCaptureOrQueuedCue() async throws {
        let rig = MacCoachingInterruptionRig(), adapter = try rig.make()
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.prepareSpeech(adapter.admit(coachingWireData(lease)))
        try adapter.playCompletePhrase([coachingPCM], for: advice)
        let unrelated = AVAudioEngine()
        for _ in 0..<3 {
            rig.center.post(name: .AVAudioEngineConfigurationChange, object: unrelated)
            rig.center.post(name: NSApplication.didResignActiveNotification, object: nil)
            rig.fake.feed(try sineBuffer())
            await drainCoachingTasks()
        }
        #expect(adapter.privatePlaybackObservation() == .pending && rig.fake.running && rig.outputRunning)
        #expect(rig.buffers == 3 && rig.suspensions.isEmpty)
        adapter.stop()
    }

    @Test(arguments: [false, true])
    func ownedEngineLossFencesImmediatelyAndOldCleanupCannotStopFreshBegin(output: Bool) async throws {
        let rig = MacCoachingInterruptionRig(), adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let oldAdvice = try adapter.prepareSpeech(adapter.admit(coachingWireData(old)))
        try adapter.playCompletePhrase([coachingPCM], for: oldAdvice)
        rig.center.post(name: .AVAudioEngineConfigurationChange, object: output ? rig.output : rig.input)
        #expect(adapter.privatePlaybackObservation() == .unavailable)
        #expect(!rig.fake.running && !rig.outputRunning)
        let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let freshAdvice = try adapter.prepareSpeech(adapter.admit(coachingWireData(fresh)))
        await drainCoachingTasks()
        #expect(rig.fake.running && rig.outputRunning && rig.fake.starts == 2)
        #expect(throws: (any Error).self) { try adapter.playCompletePhrase([coachingPCM], for: oldAdvice) }
        try adapter.playCompletePhrase([coachingPCM], for: freshAdvice)
        adapter.stop()
    }

    @Test func runningEngineWithoutBuffersClosesForegroundAndExplicitRestartCaptures() async throws {
        let rig = MacCoachingInterruptionRig(watchdog: true)
        var child: ForegroundTestChild?
        let driver = try ForegroundCoaching(listenerID: "private-coach", transport: { hooks in
            let owned = ForegroundTestChild(hooks); child = owned; return owned
        }, audio: { hooks in try rig.make(hooks: hooks) }, speech: ForegroundTestSpeech(), clock: rig.time.clock)
        try driver.enable(participantAwareness: true)
        for _ in 0..<5 {
            try await waitUntil { [sleeper = rig.sleeper] in sleeper.isWaiting }
            rig.time.advance(.seconds(1))
            rig.sleeper.tick()
            await drainCoachingTasks()
        }
        await drainCoachingTasks()
        #expect(driver.status == .off && rig.suspensions == [.captureEnded])
        #expect(rig.fake.starts == 1 && !rig.fake.running && !rig.outputRunning)
        #expect(child?.stops == 1)
        try driver.enable(participantAwareness: true)
        rig.fake.feed(try sineBuffer()); await drainCoachingTasks()
        #expect(driver.status == .active && rig.buffers == 1 && rig.fake.starts == 2)
        driver.off(); rig.sleeper.tick(.zero); await drainCoachingTasks()
        #expect(driver.status == .off && !rig.fake.running && !rig.outputRunning)
    }
}
#endif
