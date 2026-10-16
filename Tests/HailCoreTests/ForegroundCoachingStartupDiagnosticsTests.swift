import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor private final class StartupDiagnosticChild: ForegroundCoachingTransport {
    let failedStage: ForegroundCoaching.StartupStage
    var qualified: CoachingQualification?
    var closes = 0, joins = 0
    init(_ stage: ForegroundCoaching.StartupStage) { failedStage = stage }
    func send(_ control: ForegroundCoachingControl) -> Bool {
        switch control {
        case .enable: return failedStage != .providerStart
        case .qualify(let lease): qualified = lease; return failedStage != .providerQualification
        case .disable: return true
        }
    }
    func write(_ buffer: AudioCaptureBuffer) -> Bool { false }
    func close() { closes += 1 }
    func stop() async { joins += 1 }
}

@MainActor private final class StartupDiagnosticAudio: ForegroundCoachingAudio {
    let base: ForegroundTestAudio
    var failBegin = false
    var stops = 0
    init(hooks: PrivateCoachingSession.Hooks, clock: CoachingClock) throws {
        base = try ForegroundTestAudio(hooks: hooks, clock: clock)
    }
    func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification {
        if failBegin { throw CoachingSafetyError.unsafeOutput }
        return try base.begin(sessionID: sessionID, destinationID: destinationID, consentConfirmed: consentConfirmed)
    }
    func renew(_ lease: CoachingQualification) throws -> CoachingQualification { try base.renew(lease) }
    func admit(_ data: Data) throws -> AdmittedCoachingAdvice { try base.admit(data) }
    func prepareSpeech(_ advice: AdmittedCoachingAdvice) throws -> AdmittedCoachingAdvice {
        try base.prepareSpeech(advice)
    }
    func interruptSpeech() { base.interruptSpeech() }
    func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try base.schedule(payload, for: advice)
    }
    func resume(_ advice: AdmittedCoachingAdvice) throws { try base.resume(advice) }
    func stop() { stops += 1; base.stop() }
}

@Suite @MainActor struct CoachingStartupDiagnosticsTests {
    @Test func firstRetirementCauseSurvivesLateOldCallbacksAndClearsOnRestart() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let old = try #require(rig.children.last)
        rig.owners[0].session.invalidateRoute()
        old.hooks.ended()
        await drainCoachingTasks()
        #expect(rig.driver.retirementReason == .audioStopped(.routeInvalidated))
        try rig.driver.enable(participantAwareness: true)
        old.hooks.ended()
        #expect(rig.driver.retirementReason == nil && rig.driver.status == .active)
        rig.children[1].hooks.ended()
        await drainCoachingTasks()
        #expect(rig.driver.retirementReason == .providerEnded && rig.driver.status == .off)
    }

    @Test func explicitStopDoesNotBecomeAnAudioFailure() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        rig.driver.off()
        await drainCoachingTasks()
        #expect(rig.driver.status == .off && rig.driver.retirementReason == nil)
    }

    @Test(arguments: [ForegroundCoaching.StartupStage.providerSetup, .providerStart, .deviceSetup,
                      .audioStart, .providerQualification, .activation])
    func actualStageIsRetainedAfterOwnedCleanup(stage: ForegroundCoaching.StartupStage) async throws {
        let time = ForegroundTestClock(), child = StartupDiagnosticChild(stage)
        var audio: StartupDiagnosticAudio?
        var childAllocated = false
        let clock = CoachingClock(now: {
            if stage == .activation, let lease = child.qualified { return lease.expiresAt }
            return time.now
        }, schedule: time.clock.schedule)
        let owner = try ForegroundCoaching(listenerID: "private-coach", transport: { _ in
            if stage == .providerSetup { throw ForegroundCoachingError.transportFailed }
            childAllocated = true
            return child
        }, audio: { hooks in
            if stage == .deviceSetup { throw CoachingSafetyError.unsafeOutput }
            let made = try StartupDiagnosticAudio(hooks: hooks, clock: time.clock)
            made.failBegin = stage == .audioStart
            audio = made
            return made
        }, speech: ForegroundTestSpeech(), clock: clock)
        #expect(throws: (any Error).self) { try owner.enable(participantAwareness: true) }
        #expect(owner.startupFailure == stage)
        await drainCoachingTasks()
        #expect(owner.status == .off)
        #expect(child.closes == (childAllocated ? 1 : 0))
        #expect(child.joins == (childAllocated ? 1 : 0))
        if let audio {
            #expect(audio.stops > 0 && audio.base.session.qualification == nil)
            if stage == .audioStart { #expect(audio.base.capture.startCount == 0) }
        }
        owner.off()
        #expect(owner.startupFailure == stage)
    }

    @Test func freshSuccessfulAttemptClearsPreviousStage() async throws {
        let rig = try ForegroundRig()
        var fail = true
        let owner = try ForegroundCoaching(listenerID: "private-coach", transport: { hooks in
            if fail { throw ForegroundCoachingError.transportFailed }
            return ForegroundTestChild(hooks)
        }, audio: { hooks in
            try ForegroundTestAudio(hooks: hooks, clock: rig.time.clock)
        }, speech: rig.speech, clock: rig.time.clock)
        #expect(throws: (any Error).self) { try owner.enable(participantAwareness: true) }
        #expect(owner.startupFailure == .providerSetup)
        fail = false
        try owner.enable(participantAwareness: true)
        #expect(owner.status == .active && owner.startupFailure == nil)
        owner.off()
        await drainCoachingTasks()
    }
}
