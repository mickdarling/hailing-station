import Testing
@testable import HailDaemonKit

/// Dead-mapping cleanup parity using synthetic outcomes and the existing tmux command gate.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeliveryMappingCleanupTests {
    @Test(arguments: ["target_policy_changed", "delivery cancelled", "adapter delivery failed"])
    func partialEqualityKeepsDeliveredLinesAndReason(reason: String) {
        let delivered: [String] = ["one", "two"]
        let partial = HostError.partial(delivered: delivered, reason: reason)
        let same = HostError.partial(delivered: Array(delivered), reason: String(reason))
        let fewer = HostError.partial(delivered: ["one"], reason: reason)
        let reordered = HostError.partial(delivered: ["two", "one"], reason: reason)
        let otherReason = HostError.partial(delivered: delivered, reason: "other reason")
        #expect(partial == same)
        #expect(partial != fewer)
        #expect(partial != reordered)
        #expect(partial != otherReason)
        #expect(partial != .unknownTarget("tmux:codex"))
    }

    @Test(arguments: [false, true], [1, 2])
    func possiblySubmittedKeepsTheCurrentLineInThePartial(fails: Bool, lineCount: Int) async throws {
        let rig = try await TmuxAuthorityRig.make(.enter, delivery: lineCount)
        defer { rig.runner.gate.fire() }
        rig.runner.requireRetry()
        if fails { rig.runner.failEnter() }
        let text = lineCount == 1 ? "one\ntwo" : "one\ntwo\nthree"
        let sending = Task {
            try await rig.host.sendAuthorized(
                text, policyGeneration: rig.host.targetPolicy.snapshot(for: TmuxAuthorityRig.target),
                from: "test", expectedBinding: nil, context: nil
            )
        }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        let delivered: [String] = lineCount == 1 ? ["one"] : ["one", "two"]
        let expected = HostError.partial(delivered: delivered, reason: "target_policy_changed")
        await #expect(throws: expected) { try await rig.runner.gate.finish(sending) }
        #expect(rig.runner.pasted == delivered)
        let expectedEnters: Int = lineCount + (fails ? 0 : 1)
        #expect(rig.runner.enters == expectedEnters)
    }
}
