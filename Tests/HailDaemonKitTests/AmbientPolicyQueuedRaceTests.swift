import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyQueuedRaceTests {
    @Test func secondProcessDenyWhileAdmissionQueued() async throws {
        let rig = try await AmbientPolicyProcessRig.make(startStream: false)
        defer { rig.cleanUp() }
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        let holding = Task(executorPreference: blocked.executor) { await rig.gate.holdPolicyAdmission(blocked) }
        try await blocked.waitUntilSuspended()
        let receiving = Task { await rig.segment(0) }
        try await rig.session.waitForPolicyAdmission()
        let before: PolicyFileIdentity = try rig.file.identity()
        try await rig.write("deny")
        let after: PolicyFileIdentity = try rig.file.identity()
        try #require(before.inode != after.inode)
        blocked.fire()
        await holding.value
        let result: HostSessionResult = await receiving.value
        let controls: [FramePayload] = result.frames.map(\.payload)
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(controls == [expected])
        #expect(result.disposition == .keepOpen)
        #expect(rig.sink.segments.isEmpty)
        let active: UUID? = await rig.gate.activeStream
        #expect(active == nil)
    }

    @Test(arguments: [false, true])
    func secondProcessDenyDuringReload(_ hostReload: Bool) async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        let generation = rig.host.targetPolicy.snapshot(for: "tmux:a")
        // Only B changes first: adopting this stale read would preserve A's grant.
        try await rig.write("deny", target: "tmux:b")
        hook.arm(blocked)
        let checking = Task(executorPreference: blocked.executor) {
            if hostReload {
                let policy: Policy? = await rig.host.refreshedPolicy()
                return policy == nil
            }
            do {
                try generation.requireCurrent()
                return false
            } catch { return true }
        }
        try await blocked.waitUntilSuspended()
        let before: PolicyFileIdentity = try rig.file.identity()
        try await rig.write("deny")
        let after: PolicyFileIdentity = try rig.file.identity()
        try #require(before.inode != after.inode)
        blocked.fire()
        let refused: Bool = await checking.value
        #expect(refused, "A policy replaced between open and decode must never be adopted")
        let current: Bool = generation.performIfCurrent({ true }) == true
        #expect(!current)
        // The failed observation must not cache B's old identity; retry must see A's denial.
        let result: HostSessionResult = await rig.segment(1)
        let fresh = rig.host.targetPolicy.snapshot(for: "tmux:a")
        #expect(!fresh.wasGranted)
        let control: ControlPayload = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }
}
