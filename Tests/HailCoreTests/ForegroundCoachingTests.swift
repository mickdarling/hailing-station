import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingTests {
    @Test func defaultOffAndAwarenessPrecedeEveryFactory() throws {
        let rig = try ForegroundRig()
        #expect(rig.driver.status == .off && rig.children.isEmpty && rig.owners.isEmpty)
        #expect(throws: ForegroundCoachingError.awarenessRequired) {
            try rig.driver.enable(participantAwareness: false)
        }
        #expect(rig.children.isEmpty && rig.owners.isEmpty)
    }

    @Test func repeatedSyntheticCaptureAdviceAndNonzeroSpeechUseSameOwner() async throws {
        let rig = try ForegroundRig()
        for _ in 0..<3 {
            try rig.driver.enable(participantAwareness: true)
            let child = try #require(rig.children.last), owner = try #require(rig.owners.last)
            let lease = try #require(child.leases.last)
            try owner.capture.yield(sineBuffer())
            await drainCoachingTasks()
            #expect(child.buffers == 1)
            child.hooks.advice(try coachingWireData(lease))
            await drainCoachingTasks()
            #expect(owner.player.scheduled == [coachingPCM] && owner.player.resumed == 1)
            #expect(coachingPCM.bytes.contains { $0 != 0 })
            rig.driver.off()
            await drainCoachingTasks()
            #expect(rig.driver.status == .off && child.closes == 1 && child.stops == 1)
            #expect(owner.session.qualification == nil)
        }
        #expect(Set(rig.children.flatMap(\.leases).map(\.sessionID)).count == 3)
    }

    @Test func oldOutputAndCaptureCompletionCannotRetireOrFeedSuccessor() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let first = try #require(rig.children.first), lease = try #require(first.leases.last)
        rig.driver.off(); await drainCoachingTasks()
        try rig.driver.enable(participantAwareness: true)
        first.hooks.advice(try coachingWireData(lease)); first.hooks.ended()
        await drainCoachingTasks()
        #expect(rig.driver.status == .active && rig.speech.texts.isEmpty)
        #expect(rig.children[1].buffers == 0)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func originalAdviceDeadlineWinsOverHeartbeatWhileTTSIsDelayed() async throws {
        let rig = try ForegroundRig()
        var release: CheckedContinuation<Void, Never>?
        rig.speech.handler = { emit in
            await withCheckedContinuation { release = $0 }
            try emit(coachingPCM)
        }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease, ttl: 1_500))
        await drainCoachingTasks()
        rig.time.advance(.seconds(1))
        #expect(child.leases.count == 2 && child.leases[1].generation == lease.generation)
        rig.time.advance(.milliseconds(600)); await drainCoachingTasks()
        #expect(rig.driver.status == .retiring)
        #expect(throws: ForegroundCoachingError.busy) { try rig.driver.enable(participantAwareness: true) }
        release?.resume(); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled.isEmpty && rig.driver.status == .off)
    }

    @Test func routeLossAndProfileOffCancelDelayedSpeechWithoutRevival() async throws {
        for routeLoss in [false, true] {
            let rig = try ForegroundRig()
            var release: CheckedContinuation<Void, Never>?
            rig.speech.handler = { emit in
                await withCheckedContinuation { release = $0 }
                try emit(coachingPCM)
            }
            try rig.driver.enable(participantAwareness: true)
            let child = try #require(rig.children.first), lease = try #require(child.leases.last)
            child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
            if routeLoss { rig.owners[0].session.invalidateRoute() } else { rig.driver.off() }
            await drainCoachingTasks()
            release?.resume(); await drainCoachingTasks()
            #expect(rig.driver.status == .off && rig.owners[0].player.scheduled.isEmpty)
            #expect(rig.owners[0].capture.stopCount == 1)
        }
    }

    @Test func quotedControlsAreNeverLocalControlsAndMalformedAdviceRetires() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        var wire = try #require(JSONSerialization.jsonObject(with: coachingWireData(lease)) as? [String: Any])
        wire["text"] = "Please say disable or enable; these words cannot change the host."
        child.hooks.advice(try coachingWireData(wire)); await drainCoachingTasks()
        #expect(rig.driver.status == .active && child.enableCount == 1)
        child.hooks.advice(Data("{\"action\":\"enable\"}".utf8)); await drainCoachingTasks()
        #expect(rig.driver.status == .off && child.stops == 1)
    }

    @Test func lateFactoryAndEnableSendReentryCannotStartCapture() async throws {
        for duringFactory in [true, false] {
            let rig = try ForegroundRig()
            rig.onChild = { child in
                if duringFactory { rig.driver.off() } else { child.onSend = { rig.driver.off() } }
            }
            #expect(throws: (any Error).self) { try rig.driver.enable(participantAwareness: true) }
            await drainCoachingTasks()
            #expect(rig.driver.status == .off && rig.owners.isEmpty)
            #expect(rig.children[0].closes == 1 && rig.children[0].stops == 1)
        }
    }

    @Test func unjoinedChildKeepsAllocationBoundedAndEOFRetires() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first)
        child.holdStop = true; child.hooks.ended(); await drainCoachingTasks()
        #expect(rig.driver.status == .retiring)
        for _ in 0..<10 {
            #expect(throws: ForegroundCoachingError.busy) { try rig.driver.enable(participantAwareness: true) }
        }
        #expect(rig.children.count == 1)
        child.blockedStop?.resume(); await drainCoachingTasks()
        #expect(rig.driver.status == .off)
    }

    @Test func cancelledRenderTimerCannotRetireLaterAdviceInSameGeneration() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        let cancelled = rig.time.alarms.values.filter(\.cancelled).map(\.fire)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        cancelled.forEach { $0() }
        #expect(rig.driver.status == .active && rig.owners[0].player.scheduled.count == 2)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func renderSchedulerReentrantOffDoesNotLeavePhantomJob() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        rig.time.onSchedule = { rig.driver.off() }
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(rig.driver.status == .off && rig.speech.texts.isEmpty)
    }
}

@Suite @MainActor struct ForegroundCoachingRenderOwnershipTests {
    @Test func completedRendererCannotEmitIntoLaterJobOfSameGeneration() async throws {
        let rig = try ForegroundRig()
        var oldEmit: (@MainActor (AudioPayload) throws -> Void)?
        rig.speech.handler = { emit in oldEmit = emit; try emit(coachingPCM) }
        try rig.driver.enable(participantAwareness: true)
        let child = try #require(rig.children.first), lease = try #require(child.leases.last)
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        var release: CheckedContinuation<Void, Never>?
        rig.speech.handler = { emit in
            await withCheckedContinuation { release = $0 }
            try emit(coachingPCM)
        }
        child.hooks.advice(try coachingWireData(lease)); await drainCoachingTasks()
        #expect(throws: ForegroundCoachingError.invalidSpeech) { try oldEmit?(coachingPCM) }
        #expect(rig.owners[0].player.scheduled.count == 1)
        release?.resume(); await drainCoachingTasks()
        #expect(rig.owners[0].player.scheduled.count == 2 && rig.driver.status == .active)
        rig.driver.off(); await drainCoachingTasks()
    }

    @Test func heartbeatCannotExtendOriginalFifteenMinuteBudget() async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        for _ in 0..<899 { rig.time.advance(.seconds(1)) }
        #expect(rig.driver.status == .active)
        rig.time.advance(.seconds(1)); await drainCoachingTasks()
        #expect(rig.driver.status == .off && rig.owners[0].session.qualification == nil)
    }
}
