import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1028 part 4b: synthetic panes only; command replies park on the gate's dedicated executor.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TmuxPolicyRetirementTests {
    @Test(arguments: [AuthorityTmuxRunner.Checkpoint.fill, .paste])
    func retirementDuringLineTwoPreservesThePolicyReason(checkpoint: AuthorityTmuxRunner.Checkpoint) async throws {
        let rig = try await TmuxAuthorityRig.make(checkpoint, delivery: 2)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await send("one\ntwo\nthree", rig: rig) }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: HostError.partial(delivered: ["one"], reason: "target_policy_changed")) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted == (checkpoint == .paste ? ["one", "two"] : ["one"]))
        #expect(rig.runner.enters == 1)
    }

    @Test(arguments: [false, true], [1, 2])
    func possiblySubmittedLineIsIncludedEvenWhenEnterReplyFails(fails: Bool, lineCount: Int) async throws {
        let rig = try await TmuxAuthorityRig.make(.enter, delivery: lineCount)
        rig.runner.requireRetry()
        if fails { rig.runner.failEnter() }
        defer { rig.runner.gate.fire() }
        let text = lineCount == 1 ? "two\nthree" : "one\ntwo\nthree"
        let sending = Task { try await send(text, rig: rig) }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        let delivered = lineCount == 1 ? ["two"] : ["one", "two"]
        await #expect(throws: HostError.partial(delivered: delivered, reason: "target_policy_changed")) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted == delivered)
        #expect(rig.runner.enters == lineCount)
        #expect(!rig.log.all.contains { $0.event == "tmux_policy_retired_unsent" })
        rig.runner.setInput("")
        // An Enter may have gone out: clearing input never lifts the sticky taint.
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await rig.adapter.deliver("later input", to: "codex", binding: TmuxAuthorityRig.binding)
        }
    }

    @Test func clearedInputKeepsThePolicyTaintAndDeviceRefusalUntilRestart() async throws {
        let rig = try await taintedRig()
        let session = await session(rig)
        let expected = HostDeliveryOutcome.refused(
            .notAllowed, "a line was pasted but not sent — clear it on the Mac; "
                + "hand-offs to this target are paused until haild restarts"
        )
        #expect(try await deliver(session, text: "refused input") == expected)
        rig.runner.setInput("")
        let calls = rig.runner.calls.count
        #expect(try await deliver(session, text: "still refused") == expected)
        #expect(rig.runner.input.isEmpty)
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.enters == 0)
        #expect(!rig.runner.calls.dropFirst(calls).contains { $0.first == "capture-pane" })
        #expect(rig.log.all.last?.detail.contains("reason=tainted") == true)
    }

    private func send(_ text: String, rig: TmuxAuthorityRig) async throws -> SendOutcome {
        try await rig.host.sendAuthorized(
            text, policyGeneration: rig.host.targetPolicy.snapshot(for: TmuxAuthorityRig.target),
            from: "test", expectedBinding: nil, context: nil
        )
    }

    private func taintedRig() async throws -> TmuxAuthorityRig {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: PolicyRetiredDelivery.pastedUnsent) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.enters == 0)
        return rig
    }

    private func session(_ rig: TmuxAuthorityRig) async -> HostSession {
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        await session.forceSelection(TmuxAuthorityRig.target)
        return session
    }

    private func deliver(_ session: HostSession, text: String) async throws -> HostDeliveryOutcome {
        let frame = sessionFrame(target: TmuxAuthorityRig.target, payload: .text(TextPayload(text: text)))
        let input = try await authorizedInput(session, frame, device: "test")
        return await session.deliver(input)
    }
}
