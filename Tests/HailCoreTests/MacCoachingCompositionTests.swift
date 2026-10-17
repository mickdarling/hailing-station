#if os(macOS)
import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import HailCore

@MainActor final class MacCoachingCompositionRig {
    let capture = FakeAudioCapture()
    let time = CoachingTestClock()
    let center = NotificationCenter()
    let event = Notification.Name("AuthoredMacCoachingLifecycle")
    var safeBinding = true
    var outputRunning = false
    var starts = 0
    var stops = 0
    var plays = 0
    var queued = 0
    var captureBuffers = 0
    var nonzeroCapture = false
    var suspensions: [CoachingSuspension] = []
    var propertyChanged: (@Sendable () -> Void)?
    var outputStart: (() throws -> Void)?
    var onReady: (() -> Void)?
    var mutes: [Bool] = []
    lazy var owner = MacCoachingAudioOwner(
        input: .init(deviceID: 10, uid: "authored-room-microphone", streams: [11]), capture: capture,
        output: .init(start: { self.starts += 1; self.outputRunning = true; try self.outputStart?() },
                      stop: { self.stops += 1; self.outputRunning = false }, running: { self.outputRunning }),
        bound: { self.safeBinding })

    func make() throws -> ApplePrivateCoaching {
        let monitor = try MacCoachingOutputMonitor(bound: { self.owner.isStillBound() }, registrations: [
            .init(install: { handler in self.propertyChanged = handler; return {} })
        ], center: center, names: [event])
        let renderer = CoachingEngineRenderer(operations: .init(ready: {
            self.onReady?()
            return self.outputRunning
        }, schedule: { _, _ in
            self.queued += 1
        }, control: { command in
            if case .play = command { self.plays += 1 }
            if case .stop = command { self.queued = 0 }
            if case .muted(let muted) = command { self.mutes.append(muted) }
        }), observe: { monitor.observe() })
        return try ApplePrivateCoaching(capture: owner, player: renderer, monitor: monitor, listenerID: "private-coach",
            hooks: .init(buffer: { buffer, _ in
                self.captureBuffers += 1
                self.nonzeroCapture = buffer.pcmBuffer.floatChannelData?.pointee[1] != 0
            }, suspended: { _, reason in self.suspensions.append(reason) }), clock: time.clock)
    }
}

@Suite @MainActor struct MacCoachingLifecycleTests {
    @Test func bindingLossWithoutNotificationRetiresCaptureAndQueuedOutput() throws {
        for action in 0..<3 {
            let rig = MacCoachingCompositionRig()
            let adapter = try rig.make()
            let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            let advice = try adapter.admit(coachingWireData(lease))
            try adapter.schedule(coachingPCM, for: advice)
            rig.safeBinding = false
            #expect(throws: (any Error).self) {
                switch action {
                case 0: try adapter.schedule(coachingPCM, for: advice)
                case 1: try adapter.resume(advice)
                default: try adapter.setMuted(false, for: advice)
                }
            }
            #expect(rig.queued == 0 && rig.stops == 1 && rig.capture.stopCount == 1)
            #expect(rig.suspensions == [.routeInvalidated] && rig.plays == 1)
        }
    }

    @Test func expiryAndLifecycleClearContextWithoutRestart() async throws {
        for expires in [false, true] {
            let rig = MacCoachingCompositionRig()
            let adapter = try rig.make()
            let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            let advice = try adapter.admit(coachingWireData(lease))
            try adapter.schedule(coachingPCM, for: advice)
            if expires { rig.time.advance(.seconds(2)) } else { rig.center.post(name: rig.event, object: nil) }
            await drainCoachingTasks()
            #expect(rig.queued == 0 && rig.stops == 1 && rig.capture.stopCount == 1)
            #expect(rig.suspensions == [expires ? .qualificationExpired : .routeInvalidated])
            #expect(throws: (any Error).self) { try adapter.resume(advice) }
            #expect(rig.starts == 1 && rig.plays == 1)
        }
    }

    @Test func staleNotificationCleanupCannotRetireExplicitFreshBegin() async throws {
        let rig = MacCoachingCompositionRig()
        let adapter = try rig.make()
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let oldAdvice = try adapter.admit(coachingWireData(old))
        rig.center.post(name: rig.event, object: nil)
        let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let freshAdvice = try adapter.admit(coachingWireData(fresh))
        try adapter.schedule(coachingPCM, for: freshAdvice)
        await drainCoachingTasks()
        #expect(throws: (any Error).self) { try adapter.resume(oldAdvice) }
        try adapter.resume(freshAdvice)
        #expect(rig.starts == 2 && rig.stops == 1 && rig.capture.stopCount == 1 && rig.queued == 1)
        #expect(rig.suspensions == [.stopped] && rig.plays == 2)
        adapter.stop()
    }
}

@Suite @MainActor struct MacCoachingCompositionTests {
    @Test func invalidOrSharedDeviceIDsFailBeforeConstructingLiveEngines() {
        for (output, input) in [(UInt32(0), UInt32(10)), (20, 0), (20, 20)] {
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                _ = try ApplePrivateCoaching(privateOutputDeviceID: output, roomMicrophoneDeviceID: input,
                    listenerID: "private-coach", hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }))
            }
        }
    }

    @Test func constructionAndMissingConsentCannotStartEitherEngine() throws {
        let rig = MacCoachingCompositionRig()
        let adapter = try rig.make()
        #expect(rig.starts == 0 && rig.capture.startCount == 0)
        #expect(throws: CoachingSafetyError.consentRequired) {
            try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: false)
        }
        #expect(rig.starts == 0 && rig.capture.startCount == 0)
    }

    @Test func fixedOutputAndRawRoomCaptureHaveOneOwnedLifetime() async throws {
        let rig = MacCoachingCompositionRig()
        let adapter = try rig.make()
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        try rig.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.starts == 1 && rig.capture.startCount == 1 && rig.plays == 1 && rig.queued == 1)
        #expect(rig.captureBuffers == 1 && rig.nonzeroCapture)
        adapter.stop()
        adapter.stop()
        #expect(rig.stops == 1 && rig.capture.stopCount == 1 && rig.queued == 0 && rig.suspensions == [.stopped])
    }

    @Test func propertyLossFencesQueuedAndLateAdviceWithoutFallback() async throws {
        let rig = MacCoachingCompositionRig()
        let adapter = try rig.make()
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        let changed = try #require(rig.propertyChanged)
        await Task.detached { changed() }.value
        #expect(throws: (any Error).self) { try adapter.resume(advice) }
        #expect(rig.queued == 0 && rig.stops == 1 && rig.capture.stopCount == 1 && rig.plays == 1)
        await drainCoachingTasks()
        #expect(rig.suspensions.count == 1)
    }

    @Test func changedBindingAndPartialStartupFailureRetireBothResources() throws {
        for fails in [false, true] {
            let rig = MacCoachingCompositionRig()
            let adapter = try rig.make()
            rig.outputStart = {
                if fails { throw CoachingSafetyError.invalidAudio }
                rig.safeBinding = false
            }
            #expect(throws: (any Error).self) {
                try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
            }
            #expect(rig.starts == 1 && rig.stops == 1 && rig.capture.startCount == 0 && !rig.outputRunning)
            #expect(rig.capture.stopCount == 1)
        }
    }
}
#endif
