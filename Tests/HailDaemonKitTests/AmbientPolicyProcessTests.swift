import Darwin
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyProcessTests {
    @Test(arguments: ["deny", "confirm", "locked"])
    func secondProcessRevokesNextSegment(_ change: String) async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        var before = stat()
        try #require(lstat(rig.file.path.path, &before) == 0)
        try await rig.write(change == "deny" ? "deny" : "tier", tier: change == "deny" ? nil : change)
        var after = stat()
        try #require(lstat(rig.file.path.path, &after) == 0)
        #expect(before.st_ino != after.st_ino, "The real CLI replaced the file by atomic rename")
        let result: HostSessionResult = await rig.segment(1)
        try terminal(result, rig: rig)
    }

    @Test(arguments: ["deny", "confirm", "locked"])
    func secondProcessRevokesRetainedHandoff(_ change: String) async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let input: AuthorizedInput = try await rig.input()
        try await rig.write(change == "deny" ? "deny" : "tier", tier: change == "deny" ? nil : change)
        let outcome: HostDeliveryOutcome = await rig.session.deliver(input)
        #expect(outcome == .refused(.notAllowed, "target action was refused"))
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func secondProcessRevokesBeforeDeliveryGenerationCompare() async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let generation = rig.host.targetPolicy.snapshot(for: "tmux:a")
        try await rig.write("deny")
        #expect(throws: HostError.denied(.notAllowed("tmux:a"))) { try generation.requireCurrent() }
    }

    @Test func secondProcessOtherTargetKeepsStreamAndHandoff() async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let input: AuthorizedInput = try await rig.input()
        try await rig.write("deny", target: "tmux:b")
        let result: HostSessionResult = await rig.segment(1)
        #expect(result.frames.isEmpty)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        let outcome: HostDeliveryOutcome = await rig.session.deliver(input)
        #expect(outcome == .delivered(request: nil))
    }

    @Test func slowUnchangedDispatchReadKeepsStreamAndDeliversRequest() async throws {
        let hook = PolicyReloadStore.Hook()
        let rig = try await AmbientPolicyProcessRig.make(reload: hook)
        defer { rig.cleanUp() }
        let retained = ["tmux:a", "tmux:b"].map { rig.host.targetPolicy.snapshot(for: $0) }
        let original = try rig.file.observation()
        let before = hook.loads
        let decoded = PolicyWriteGate()
        defer { decoded.fire() }
        hook.arm(decoded)
        let delivering = Task(executorPreference: decoded.executor) {
            let input = try await rig.input()
            return await rig.session.deliver(input)
        }
        try await decoded.waitUntilSuspended()
        #expect(await rig.adapter.deliveries.isEmpty)
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings.isEmpty)
        for grant in retained { #expect(grant.performIfCurrent({ true }) == true) }
        hook.clock.advance(.milliseconds(60))
        let outcome = try await decoded.finish(delivering)
        #expect(outcome == .delivered(request: nil))
        #expect(hook.loads == before + 1, "Dispatch must reread even an unchanged policy")
        #expect(try rig.file.observation() == original)
        #expect(await rig.host.policyFailure == nil)
        #expect(await rig.adapter.deliveries == [.init(target: "a", text: "synthetic", binding: "$1@1/%1:1")])
        for grant in retained { #expect(grant.performIfCurrent({ true }) == true) }
        let result = await rig.segment(1)
        #expect(result.frames.isEmpty)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        #expect(await rig.gate.activeStream == rig.stream)
    }

    @Test func coalescedSecondProcessDenyAllowKeepsStream() async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let input: AuthorizedInput = try await rig.input()
        try await rig.write("deny")
        try await rig.write("allow", tier: "open")
        let result: HostSessionResult = await rig.segment(1)
        #expect(result.frames.isEmpty)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        let outcome: HostDeliveryOutcome = await rig.session.deliver(input)
        #expect(outcome == .delivered(request: nil))
    }

    @Test(arguments: ["missing", "unreadable", "malformed"])
    func removedOrUnusablePolicyRetiresStreamAndRefusesFreshInput(_ failure: String) async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        switch failure {
        case "missing": try FileManager.default.removeItem(at: rig.file.path)
        case "unreadable": try #require(chmod(rig.file.path.path, 0o000) == 0)
        default: try Data("invalid".utf8).write(to: rig.file.path)
        }
        let result: HostSessionResult = await rig.segment(1)
        try terminal(result, rig: rig)
        let policy: Policy? = await rig.host.refreshedPolicy()
        if failure == "missing" {
            #expect(policy == Policy())
            #expect(await rig.host.policyFailure == nil)
            let other = rig.host.targetPolicy.snapshot(for: "tmux:b")
            #expect(!other.wasGranted, "Deleting the policy retires every target's grant")
            #expect(throws: HostError.denied(.notAllowed("tmux:b"))) { try other.requireCurrent() }
        } else {
            #expect(policy == nil)
            #expect(await rig.host.policyFailure != nil)
        }
        let fresh: HostSessionResult = await rig.session.receive(sessionFrame(
            target: "tmux:a", payload: .audio(ambientSegment(stream: UUID(), sequence: 0))
        ))
        let control: ControlPayload = try onlyControl(fresh)
        #expect(control == .error(code: .notAllowed,
                                 message: "ambient target is not allowed — run haild targets allow on the Mac"))
        let input: AuthorizedInput = try await rig.input()
        if failure == "missing" {
            await #expect(throws: HostError.denied(.notAllowed("tmux:a"))) {
                try await rig.host.send("synthetic", to: "tmux:a")
            }
        }
        let outcome: HostDeliveryOutcome = await rig.session.deliver(input)
        #expect(outcome == .refused(.notAllowed, "target action was refused"))
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func repairAllowsFreshInputWithoutRevivingRetainedGrant() async throws {
        let rig = try await AmbientPolicyProcessRig.make()
        defer { rig.cleanUp() }
        let policy: Policy = try rig.file.load()
        let retained: AuthorizedInput = try await rig.input()
        try FileManager.default.removeItem(at: rig.file.path)
        let refused: HostSessionResult = await rig.segment(1)
        try terminal(refused, rig: rig)
        try rig.file.save(policy)
        let input: AuthorizedInput = try await rig.input()
        let stale: HostDeliveryOutcome = await rig.session.deliver(retained)
        let fresh: HostDeliveryOutcome = await rig.session.deliver(input)
        #expect(stale == .refused(.notAllowed, "target action was refused"))
        #expect(fresh == .delivered(request: nil))
    }

    private func terminal(_ result: HostSessionResult, rig: AmbientPolicyProcessRig) throws {
        let control: ControlPayload = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(result.disposition == .keepOpen)
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }
}
