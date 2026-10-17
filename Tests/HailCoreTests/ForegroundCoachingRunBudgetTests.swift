import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct ForegroundCoachingRunBudgetTests {
    @Test func postCaptureQualificationDelayCannotExtendTheRunBudget() async throws {
        let rig = try ForegroundRig()
        let origin = rig.time.now
        rig.onChild = { child in
            child.onSend = {
                guard child.leases.count == 1 else { return }
                child.onSend = nil
                rig.time.now = rig.time.now.advanced(by: .milliseconds(500))
            }
        }
        try rig.driver.enable(participantAwareness: true)
        #expect(rig.driver.deadline == origin.advanced(by: .seconds(900)))
        let epoch = rig.driver.epoch
        for tick in 1...899 {
            rig.time.now = origin.advanced(by: .milliseconds(500)).advanced(by: .seconds(tick))
            rig.driver.heartbeat(epoch)
        }
        try #require(rig.driver.status == .active)
        let owner = try #require(rig.owners.first)
        rig.time.now = origin.advanced(by: .seconds(900))
        try owner.capture.yield(sineBuffer())
        await drainCoachingTasks()
        #expect(rig.driver.status == .off && owner.capture.stopCount == 1)
        rig.driver.off()
        await drainCoachingTasks()
    }

    @Test(arguments: [-1, 0, 1], ["buffer", "advice"])
    func delayedHeartbeatCannotKeepCapturePastTheRunBudget(offset: Int, action: String) async throws {
        let rig = try ForegroundRig()
        try rig.driver.enable(participantAwareness: true)
        let origin = rig.time.now, epoch = rig.driver.epoch
        // Deliver the prior renewals normally, then withhold all timers at the run boundary.
        for tick in 1...899 {
            rig.time.now = origin.advanced(by: .seconds(tick))
            rig.driver.heartbeat(epoch)
        }
        try #require(rig.driver.status == .active)
        let child = try #require(rig.children.first), owner = try #require(rig.owners.first)
        let lease = try #require(child.leases.last)
        rig.time.now = origin.advanced(by: .seconds(900)).advanced(by: .milliseconds(offset))
        try #require(rig.time.now < lease.expiresAt) // The short capture lease is deliberately still valid.
        if action == "buffer" { try owner.capture.yield(sineBuffer()) } else {
            child.hooks.advice(try coachingWireData(lease))
        }
        await drainCoachingTasks()
        let expired = offset >= 0
        #expect(rig.driver.status == (expired ? .off : .active))
        #expect(owner.capture.stopCount == (expired ? 1 : 0))
        #expect(child.closes == (expired ? 1 : 0))
        #expect(child.buffers == (!expired && action == "buffer" ? 1 : 0))
        #expect(rig.speech.texts.count == (!expired && action == "advice" ? 1 : 0))
        rig.driver.off()
        await drainCoachingTasks()
    }
}
