import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyProcessDeletionTests {
    @Test func secondProcessDeletionRetiresAllGrantsAndCLIRepairAdmitsFirstFreshStart() async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let targets = ["tmux:a", "tmux:b"]
        let retained = targets.map { rig.host.targetPolicy.snapshot(for: $0) }
        for grant in retained { try #require(grant.wasGranted) }
        let live: UUID? = await rig.gate.activeStream
        try #require(live == rig.stream)

        try await rig.removePolicy()
        // The next segment must observe the deletion itself; no host or generation refresh intervenes.
        let refused: HostSessionResult = await rig.segment(1)
        let control: ControlPayload = try onlyControl(refused)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(refused.disposition == .keepOpen)
        #expect(rig.sink.segments == [0], "The refused segment must not publish PCM")
        #expect(rig.sink.events.last == .ended(stream: rig.stream, reason: .notAllowed))
        #expect(rig.sink.endings == [.notAllowed])
        let active: UUID? = await rig.gate.activeStream
        #expect(active == nil)
        for (target, grant) in zip(targets, retained) {
            // These lock-only reads cannot refresh policy and conceal a missing segment-time retirement.
            #expect(!rig.host.targetPolicy.snapshot(for: target).wasGranted)
            #expect(grant.performIfCurrent({ true }) == nil)
        }

        try await rig.write("allow", tier: "open")
        // Use a distinct stream ID and its very first start, with no refresh or reselection after repair.
        let fresh = UUID()
        let start: HostSessionResult = await rig.session.receive(sessionFrame(
            target: "tmux:a", payload: .audio(ambientSegment(stream: fresh, sequence: 0))
        ))
        #expect(start.frames.isEmpty)
        #expect(start.disposition == .keepOpen)
        #expect(rig.sink.segments == [0, 0])
        let restarted: UUID? = await rig.gate.activeStream
        #expect(restarted == fresh)
        #expect(rig.sink.endings == [.notAllowed])
        for grant in retained { #expect(grant.performIfCurrent({ true }) == nil) }
        #expect(!rig.host.targetPolicy.snapshot(for: "tmux:b").wasGranted)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyObservationRaceTests {
    @Test(arguments: [false, true])
    func secondProcessCreateReadDeleteCannotCacheAbsentGrants(_ hostReload: Bool) async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let retained = rig.host.targetPolicy.snapshot(for: "tmux:a")
        try #require(retained.wasGranted)
        try await rig.removePolicy()
        let observed = PolicyWriteGate(timeout: .seconds(20))
        let decoded = PolicyWriteGate(timeout: .seconds(20), executor: observed.executor)
        defer { observed.fire(); decoded.fire() }
        hook.armObservation(observed)
        hook.arm(decoded)
        let checking = Task(executorPreference: observed.executor) {
            if hostReload { return await rig.host.refreshedPolicy() == Policy() }
            do { try retained.requireCurrent(); return false } catch { return true }
        }
        try await observed.waitUntilSuspended()
        // Real CLI creation happens after the nil path observation, before open/read.
        try await rig.write("allow", tier: "open")
        observed.fire()
        try await decoded.waitUntilSuspended()
        // Bytes and fstat came from the allowing descriptor; the path is absent again before decode returns.
        try await rig.removePolicy()
        let refused = try await decoded.finish(checking)
        #expect(refused, "The retry must adopt the final absent path, never the replaced allowing descriptor")
        #expect(!rig.host.targetPolicy.snapshot(for: "tmux:a").wasGranted)
        #expect(retained.performIfCurrent({ true }) == nil)
        let loads = hook.loads
        try rig.host.targetPolicy.refreshIfChanged()
        // Host refreshes invalidate the admission cache; admission's own stable read retains its final stamp.
        #expect(hook.loads == loads + (hostReload ? 1 : 0))
        #expect(!rig.host.targetPolicy.snapshot(for: "tmux:a").wasGranted)
        let result = await rig.segment(1)
        let control = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }

    @Test(arguments: ["permissions", "symlink", "replacement"])
    func secondProcessDirectoryChangeRetiresCachedLiveStream(_ mutation: String) async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer {
            rig.cleanUp()
            try? FileManager.default.removeItem(atPath: rig.directory.path + ".moved")
        }
        let retained = rig.host.targetPolicy.snapshot(for: "tmux:a")
        try #require(retained.wasGranted)
        let before = try #require(try rig.file.identity())
        try await rig.mutateDirectory(mutation)
        // chmod, symlink and a safe replacement directory all leave the actual policy inode unchanged.
        let result = await rig.segment(1)
        let control = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
        #expect(result.disposition == .keepOpen)
        #expect(await rig.gate.activeStream == nil)
        #expect(!rig.host.targetPolicy.snapshot(for: "tmux:a").wasGranted)
        #expect(retained.performIfCurrent({ true }) == nil)
        var info = stat()
        try #require(stat(rig.file.path.path, &info) == 0)
        #expect(info.st_ino == before.inode)
        #expect(info.st_dev == before.device)
    }
}
