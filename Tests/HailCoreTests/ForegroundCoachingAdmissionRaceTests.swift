import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingAdmissionRaceTests {
    @Test(arguments: [99, 100, 101])
    func originalAdviceDeadlineFencesQueuedProviderStartup(milliseconds: Int) async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease, ttl: 100))
        rig.time.now = rig.time.now.advanced(by: .milliseconds(milliseconds)) // No timer delivery.
        await drainCoachingTasks()
        #expect(rig.speech.texts.count == (milliseconds < 100 ? 1 : 0))
        #expect(rig.owners[0].player.scheduled.count == (milliseconds < 100 ? 1 : 0))
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func renewalCancellationCannotRedeliverCurrentHeartbeatOrDuplicatePublication() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first)
        let fire = try #require(rig.time.alarms.values.first {
            $0.at == rig.time.now.advanced(by: .seconds(1))
        }).fire
        rig.time.onCancel = {
            rig.time.onCancel = nil
            fire()
        }
        rig.time.advance(.seconds(1))
        #expect(rig.driver.status == .active && child.leases.count == 2)
        fire() // An already delivered timer cannot publish another qualification.
        #expect(rig.driver.status == .active && child.leases.count == 2)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func reentrantAdmissionCannotAllocateSecondRendererOrReleaseOldJoinSlot() async throws {
        let rig = try ForegroundRig()
        var releases: [CheckedContinuation<Void, Never>] = []
        rig.speech.handler = { _ in await withCheckedContinuation { releases.append($0) } }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        let nested = try coachingWireData(lease)
        rig.owners[0].onAdmit = {
            rig.owners[0].onAdmit = nil
            child.hooks.advice(nested)
        }
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(releases.count == 1 && rig.speech.texts.count == 1)
        rig.driver.off(); await drainCoachingTasks()
        #expect(rig.driver.status == .retiring)
        #expect(throws: ForegroundCoachingError.busy) { try rig.driver.enable(participantAwareness: true) }
        // Join all actual jobs even in the red case, preserving evidence without leaking continuations.
        releases.forEach { $0.resume() }; await drainCoachingTasks()
        #expect(rig.driver.status == .off)
    }

    @Test func offBeforeFirstTaskExecutionCannotStartSpeechProvider() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease))
        rig.driver.off() // Deliberately no actor yield before retirement.
        await drainCoachingTasks()
        #expect(rig.speech.texts.isEmpty && rig.driver.status == .off)
        #expect(rig.owners[0].player.scheduled.isEmpty)
    }

    @Test func timerCancellationCannotAdmitJobBeforeOldJoinFinishes() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        let nested = try coachingWireData(lease)
        rig.speech.handler = { emit in
            try emit(coachingPCM)
            rig.time.onCancel = {
                rig.time.onCancel = nil
                child.hooks.advice(nested)
            }
        }
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.speech.texts.count == 1 && rig.driver.status == .active)
        rig.speech.handler = nil
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.speech.texts.count == 2 && rig.driver.status == .active)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func noncooperativeSpeechCannotRetainOwnerAndPreventDeinitRevocation() async throws {
        let rig = try ForegroundRig()
        var release: CheckedContinuation<Void, Never>?
        rig.speech.handler = { emit in
            await withCheckedContinuation { release = $0 }
            try emit(coachingPCM)
        }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        weak var driver = rig.driver
        defer { driver = nil }
        rig.releaseDriver(); await drainCoachingTasks()
        #expect(driver == nil && rig.owners[0].session.qualification == nil)
        #expect(child.closes == 1 && rig.speech.cancellations > 0)
        release?.resume(); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled.isEmpty)
    }
}
