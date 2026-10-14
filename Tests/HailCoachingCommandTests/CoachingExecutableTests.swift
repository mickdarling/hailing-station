import Foundation
import HailCore
import Testing
@testable import haild
@testable import HailCoaching

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct CoachingExecutableTests {
    private var executable: String? { ProcessInfo.processInfo.environment["HAIL_COACHING_EXECUTABLE"] }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAIL_COACHING_EXECUTABLE"] != nil,
                   "Requires an explicitly supplied pinned authored-only executable"))
    func sameForegroundOwnerRunsActualPCMFinalActivityAdviceAndPrivateMockPCMOverTime() async throws {
        guard let executable else { return } // Optional executable lane: absence is NOT end-to-end proof.
        let rig = try ExecutableCoachingRig(executable: executable, commandControls: true)
        #expect(rig.transports.isEmpty && rig.driver.status == .off)
        try rig.enable()
        try await rig.capture.utterance()
        try await rig.waitFor { rig.player.played == 1 }
        let child = try #require(rig.transports.first)
        #expect(child.finalCount == 1 && child.adviceCount == 1 && rig.player.nonzeroBytes > 0)
        try await rig.capture.utterance() // Quoted controls cannot activate actions; cadence holds.
        try await rig.waitFor { child.finalCount == 2 }
        #expect(rig.speech.calls == 1 && rig.driver.status == .active && rig.transports.count == 1)
        try await rig.capture.silence(seconds: 20) // Real unchanged cadence; one-second real renewals.
        try await rig.capture.utterance()
        try await rig.waitFor { rig.player.played == 2 }
        #expect(child.finalCount == 3 && child.adviceCount == 2 && rig.speech.calls == 2)
        #expect(rig.driver.status == .active && rig.transports.count == 1)
        try await rig.off()
        #expect(rig.audio?.session.qualification == nil && rig.capture.stops == 1)
        // Scratch is authored diagnostic evidence; preserve on either success or failure for this proof.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAIL_COACHING_EXECUTABLE"] != nil,
                   "Requires an explicitly supplied pinned authored-only executable"))
    func missingTrustedActivityAndOwnerAnswerOrPlaybackHoldWithoutSpeech() async throws {
        guard let executable else { return }
        for flags in [nil, CoachingActivityFlags(ownerMidAnswer: true, playback: false),
                      CoachingActivityFlags(ownerMidAnswer: false, playback: true)] {
            let rig = try ExecutableCoachingRig(executable: executable, commandControls: true); rig.flags = flags
            try rig.enable()
            try await rig.capture.utterance()
            try await rig.waitFor { rig.transports.first?.finalCount == 1 }
            try await rig.capture.silence(seconds: 1)
            #expect(rig.player.played == 0 && rig.speech.calls == 0 && rig.driver.status == .active)
            try await rig.off()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAIL_COACHING_EXECUTABLE"] != nil,
                   "Requires an explicitly supplied pinned authored-only executable"))
    func offOrOriginalDeadlineCancelsDelayedMockSpeechAndRejectsLatePCM() async throws {
        guard let executable else { return }
        for immediateOff in [true, false] {
            let rig = try ExecutableCoachingRig(executable: executable, commandControls: true)
            rig.speech.delayed = true
            try rig.enable()
            try await rig.capture.utterance()
            try await rig.waitFor { rig.speech.calls == 1 }
            if immediateOff { rig.driver.off() } else {
                try await rig.waitFor { rig.driver.status == .retiring }
            }
            #expect(rig.driver.status == .retiring && rig.audio?.session.qualification == nil)
            #expect(throws: ForegroundCoachingError.busy) { try rig.driver.enable(participantAwareness: true) }
            rig.speech.release?.resume(); rig.speech.release = nil
            try await rig.waitFor { rig.driver.status == .off }
            #expect(rig.player.played == 0 && rig.player.nonzeroBytes == 0)
        }
    }
}
