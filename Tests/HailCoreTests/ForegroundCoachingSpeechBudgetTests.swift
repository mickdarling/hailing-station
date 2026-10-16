import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingSpeechBudgetTests {
    @Test func longCompletePhraseSurvivesAdmissionExpiryWithCurrentHeartbeat() async throws {
        let rig = try ForegroundRig()
        rig.speech.handler = { emit in
            for _ in 0..<3 { rig.time.advance(.seconds(1)) }
            for index in 0..<3 {
                try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                    sequence: index, isFinal: index == 2, bytes: Data(repeating: 17, count: 48_000)))
                #expect(rig.owners[0].player.scheduled.isEmpty)
            }
        }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), original = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(original, ttl: 100)); await drainCoachingTasks()
        #expect(rig.time.now > original.expiresAt)
        #expect(rig.owners[0].player.scheduled.count == 3 && rig.driver.status == .active)
        #expect(rig.owners[0].capture.startCount == 1 && rig.driver.speechFailure == nil)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func wholePhraseMustFitRemainingCompletionTimeBeforeFirstPlayerEffect() async throws {
        let rig = try ForegroundRig()
        rig.speech.handler = { emit in
            for _ in 0..<17 { rig.time.advance(.seconds(1)) }
            for index in 0..<3 {
                try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                    sequence: index, isFinal: index == 2, bytes: Data(repeating: 17, count: 48_000)))
            }
        }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled.isEmpty && rig.driver.status == .active)
        #expect(rig.driver.speechFailure == .durationExceeded && rig.owners[0].capture.stopCount == 0)
        rig.speech.handler = nil
        let fresh = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(fresh)); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled == [coachingPCM] && rig.driver.speechFailure == nil)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func knownRendererBudgetFailureHoldsOnlyCueAndNextCueCanRecover() async throws {
        let rig = try ForegroundRig()
        rig.speech.handler = { _ in throw CoachingSpeechFailure.renderTimedOut }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.driver.status == .active && rig.driver.speechFailure == .renderTimedOut)
        #expect(rig.owners[0].capture.stopCount == 0 && rig.owners[0].player.scheduled.isEmpty)
        rig.speech.handler = nil
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled == [coachingPCM] && rig.driver.speechFailure == nil)
        rig.driver.off(); await drainCoachingTasks()
    }
}
