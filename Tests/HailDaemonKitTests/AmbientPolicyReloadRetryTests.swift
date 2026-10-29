import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyReloadRetryTests {
    @Test(arguments: ["tmux:a", "tmux:b"], [false, true])
    func secondProcessWriteDuringRead(_ target: String, _ hostReload: Bool) async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let input = try await rig.input()
        let affected = rig.host.targetPolicy.snapshot(for: target)
        let unrelated = rig.host.targetPolicy.snapshot(for: target == "tmux:a" ? "tmux:b" : "tmux:a")
        // A new inode with identical content forces a reload without changing either target's authority.
        try rig.file.save(rig.file.load())
        let before = hook.loads
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        hook.arm(blocked)
        let checking = Task(executorPreference: blocked.executor) {
            if hostReload { _ = await rig.host.refreshedPolicy() }
            return await rig.segment(1)
        }
        try await blocked.waitUntilSuspended()
        #expect(rig.sink.segments == [0], "Admission waits inside the same check")
        #expect(rig.sink.endings.isEmpty)
        // Lock-only snapshots can run while read/decode is held: the generation lock is not held.
        #expect(affected.performIfCurrent({ true }) == true)
        #expect(unrelated.performIfCurrent({ true }) == true)
        try await rig.write(target == "tmux:a" ? "deny" : "tier", target: target,
                            tier: target == "tmux:b" ? "confirm" : nil)
        let result = try await blocked.finish(checking)
        // A host refresh also leaves the admission cache unobserved, requiring one further stable read.
        #expect(hook.loads == before + (hostReload ? 3 : 2))
        #expect(affected.performIfCurrent({ true }) == nil)
        #expect(unrelated.performIfCurrent({ true }) == true)
        if target == "tmux:b" {
            try await continuing(result, rig: rig)
            #expect(await rig.session.deliver(input) == .delivered(request: nil))
        } else {
            try terminal(result, rig: rig)
            #expect(!rig.host.targetPolicy.snapshot(for: target).wasGranted)
        }
    }

    @Test func secondProcessMovesEveryReadRetiresAllGrantsOnThirdAttempt() async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let retained = ["tmux:a", "tmux:b"].map { rig.host.targetPolicy.snapshot(for: $0) }
        try rig.file.save(rig.file.load())
        let before = hook.loads
        let first = PolicyWriteGate()
        let gates = [first, PolicyWriteGate(executor: first.executor), PolicyWriteGate(executor: first.executor)]
        defer { for gate in gates { gate.fire() } }
        hook.armReads(gates)
        let checking = Task(executorPreference: first.executor) { await rig.segment(1) }
        for (index, gate) in gates.enumerated() {
            try await gate.waitUntilSuspended()
            #expect(hook.loads == before + index + 1)
            #expect(rig.sink.segments == [0])
            #expect(rig.sink.endings.isEmpty)
            for grant in retained { #expect(grant.performIfCurrent({ true }) == true) }
            try await rig.write("tier", target: "tmux:b", tier: index == 1 ? "open" : "confirm")
            hook.clock.advance(.milliseconds(1))
            gate.fire()
        }
        let result = try await first.finish(checking)
        #expect(hook.loads == before + 3)
        #expect(hook.clock.delay == .milliseconds(3))
        #expect(hook.clock.delay < .milliseconds(50))
        for grant in retained { #expect(grant.performIfCurrent({ true }) == nil) }
        for target in ["tmux:a", "tmux:b"] { #expect(!rig.host.targetPolicy.snapshot(for: target).wasGranted) }
        try terminal(result, rig: rig)
    }

    @Test func secondProcessDirectorySwapBetweenAttemptsRetiresAllGrants() async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer {
            rig.cleanUp()
            try? FileManager.default.removeItem(atPath: rig.directory.path + ".moved")
        }
        let retained = ["tmux:a", "tmux:b"].map { rig.host.targetPolicy.snapshot(for: $0) }
        try rig.file.save(rig.file.load())
        let decoded = PolicyWriteGate()
        let observed = PolicyWriteGate(executor: decoded.executor)
        defer { decoded.fire(); observed.fire() }
        hook.arm(decoded)
        let checking = Task(executorPreference: decoded.executor) { await rig.segment(1) }
        try await decoded.waitUntilSuspended()
        try await rig.write("tier", target: "tmux:b", tier: "confirm")
        hook.armObservation(observed)
        decoded.fire()
        try await observed.waitUntilSuspended()
        // Swap after the first attempt's final lstat but before the retry's initial observation.
        try await rig.mutateDirectory("replacement")
        #expect(rig.sink.segments == [0])
        let result = try await observed.finish(checking)
        for grant in retained { #expect(grant.performIfCurrent({ true }) == nil) }
        try terminal(result, rig: rig)
    }

    private func continuing(_ result: HostSessionResult, rig: AmbientPolicyProcessRig) async throws {
        #expect(result.frames.isEmpty)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        #expect(await rig.gate.activeStream == rig.stream)
        #expect(rig.host.targetPolicy.snapshot(for: "tmux:b").wasGranted)
        #expect(try rig.file.load().targets["tmux:b"]?.tier == .confirm)
    }

    private func terminal(_ result: HostSessionResult, rig: AmbientPolicyProcessRig) throws {
        let control = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(result.disposition == .keepOpen)
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyRetryEvidenceTests {
    @Test(arguments: ["deny", "tier", "binding"], [false, true])
    func restoredGrantRetiresOnlyTheObservedTarget(_ change: String, _ hostReload: Bool) async throws {
        try await restoredGrant(change: change, target: "tmux:a", hostReload: hostReload)
    }

    @Test(arguments: ["deny", "tier", "binding"], [false, true])
    func restoredUnrelatedGrantLeavesAStreaming(_ change: String, _ hostReload: Bool) async throws {
        try await restoredGrant(change: change, target: "tmux:b", hostReload: hostReload)
    }

    private func restoredGrant(change: String, target: String, hostReload: Bool) async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let original = try rig.file.load()
        let affected = rig.host.targetPolicy.snapshot(for: target)
        let unrelated = rig.host.targetPolicy.snapshot(for: target == "tmux:a" ? "tmux:b" : "tmux:a")
        var transient = original
        switch change {
        case "deny": transient.deny(target)
        case "tier": transient.targets[target]?.tier = .confirm
        default: transient.targets[target]?.binding = "$3@1/%3:3"
        }
        try rig.file.save(transient)
        let before = hook.loads
        let decoded = PolicyWriteGate()
        defer { decoded.fire() }
        hook.arm(decoded)
        let checking = Task(executorPreference: decoded.executor) {
            if hostReload { _ = await rig.host.refreshedPolicy() }
            return await rig.segment(1)
        }
        // The first read has captured the changed grant; restore it before its final path observation.
        try await decoded.waitUntilSuspended()
        #expect(rig.sink.segments == [0])
        #expect(affected.performIfCurrent({ true }) == true, "Reads stay outside the generation lock")
        try rig.file.save(original)
        let result = try await decoded.finish(checking)
        #expect(hook.loads == before + (hostReload ? 3 : 2))
        #expect(try rig.file.load() == original)
        #expect(affected.performIfCurrent({ true }) == nil)
        #expect(unrelated.performIfCurrent({ true }) == true)
        let fresh = rig.host.targetPolicy.snapshot(for: target)
        #expect(fresh.wasGranted)
        #expect(fresh.performIfCurrent({ true }) == true)
        try await verifyStream(result, rig: rig, target: target)
    }

    private func verifyStream(_ result: HostSessionResult, rig: AmbientPolicyProcessRig, target: String) async throws {
        if target == "tmux:a" {
            let control = try onlyControl(result)
            #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
            #expect(result.disposition == .keepOpen)
            #expect(rig.sink.segments == [0])
            #expect(rig.sink.endings == [.notAllowed])
        } else {
            #expect(result.frames.isEmpty)
            #expect(rig.sink.segments == [0, 1])
            #expect(rig.sink.endings.isEmpty)
            #expect(await rig.gate.activeStream == rig.stream)
        }
    }
}
