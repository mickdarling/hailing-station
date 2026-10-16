import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingCueRevocationTests {
    @Test func interruptedUncooperativeRenderJoinsBeforeNextCueWithoutRestartingCapture() async throws {
        let rig = try ForegroundRig()
        var release: CheckedContinuation<Void, Never>?
        rig.speech.handler = { emit in
            await withCheckedContinuation { release = $0 }
            try emit(coachingPCM)
        }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease))
        await drainCoachingTasks()
        #expect(release != nil)
        child.hooks.contextChanged()
        child.hooks.advice(try coachingWireData(lease))
        #expect(rig.speech.texts.count == 1 && rig.driver.status == .active)
        release?.resume(); release = nil
        await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled.isEmpty && rig.owners[0].capture.stopCount == 0)
        rig.speech.handler = nil
        child.hooks.advice(try coachingWireData(lease))
        await drainCoachingTasks()
        #expect(rig.speech.texts.count == 2 && rig.owners[0].player.scheduled == [coachingPCM])
        #expect(rig.owners[0].capture.startCount == 1)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func newerContextCancelsQueuedSpeechAndOldRunCallbacksCannotCancelSuccessor() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let old = try #require(rig.children.first), lease = try #require(old.leases.last)
        old.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(!rig.owners[0].session.pendingPlayback.isEmpty)
        rig.driver.interruptSpeech()
        #expect(rig.owners[0].session.pendingPlayback.isEmpty && rig.owners[0].capture.stopCount == 0)
        #expect(rig.driver.status == .active)
        rig.driver.off(); await drainCoachingTasks()
        try rig.driver.enable(participantAwareness: true)
        let fresh = try #require(rig.children.last), renewed = try #require(fresh.leases.last)
        fresh.hooks.advice(try coachingWireData(renewed)); await drainCoachingTasks()
        let cancellations = rig.owners[1].player.cancelled
        old.hooks.contextChanged()
        #expect(rig.owners[1].player.cancelled == cancellations && rig.driver.status == .active)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func contextChangeDuringAdmissionCannotStartRendererOrCloseCapture() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        rig.owners[0].onAdmit = { rig.driver.interruptSpeech() }
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.speech.texts.isEmpty && rig.owners[0].capture.stopCount == 0)
        #expect(rig.driver.status == .active && !rig.driver.rendering)
        rig.owners[0].onAdmit = nil
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.speech.texts.count == 1)
        rig.driver.off(); await drainCoachingTasks()
    }
}
