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
        let delivered = checkpoint == .paste ? ["one", "two"] : ["one"]
        await #expect(throws: HostError.partial(delivered: delivered, reason: "target_policy_changed")) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted == (checkpoint == .paste ? ["one", "two"] : ["one"]))
        #expect(rig.runner.enters == (checkpoint == .paste ? 2 : 1))
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
        #expect(rig.runner.enters == lineCount + (fails ? 0 : 1))
        #expect(!rig.log.all.contains { $0.event == "tmux_policy_retired_unsent" })
        rig.runner.setInput("")
        // An Enter may have gone out: clearing input never lifts the sticky taint.
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await rig.adapter.deliver("later input", to: "codex", binding: TmuxAuthorityRig.binding)
        }
    }

    @Test func clearedInputKeepsFailureTaintAndDeviceRefusalUntilRestart() async throws {
        let rig = try await taintedRig()
        let session = await session(rig)
        let reason = "the target's input already holds unsent text"
        let expected = HostDeliveryOutcome.inputPending(reason: reason)
        #expect(try await deliver(session, text: "refused input") == expected)
        rig.runner.setInput("")
        let calls = rig.runner.calls.count
        #expect(try await deliver(session, text: "still refused") == expected)
        let frame = sessionFrame(target: TmuxAuthorityRig.target, payload: .text(TextPayload(text: "phone input")))
        #expect(try onlyControl(await session.receive(frame)) == .error(code: .notAllowed, message: reason))
        #expect(rig.runner.input.isEmpty)
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.enters == 1)
        #expect(!rig.runner.calls.dropFirst(calls).contains { $0.first == "capture-pane" })
        #expect(rig.log.all.last?.detail.contains("reason=tainted") == true)
    }

    @Test(arguments: [AuthorityTmuxRunner.Checkpoint.fill, .paste])
    func lineTwoRetirementCompletesOnlyTheAdmittedLine(
        checkpoint: AuthorityTmuxRunner.Checkpoint
    ) async throws {
        let rig = try await TmuxAuthorityRig.make(checkpoint, delivery: 2)
        defer { rig.runner.gate.fire() }
        let session = await session(rig)
        let frame = sessionFrame(target: TmuxAuthorityRig.target, payload: .text(TextPayload(text: "one\ntwo\nthree")))
        let sending = Task { await session.receive(frame) }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        let result = try await rig.runner.gate.finish(sending)
        let reason = "target action was refused"
        #expect(try onlyControl(result) == .error(code: .notAllowed, message: reason))
        #expect(rig.runner.pasted == (checkpoint == .paste ? ["one", "two"] : ["one"]))
        #expect(rig.runner.enters == (checkpoint == .paste ? 2 : 1))
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
        rig.runner.failEnter()
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: PolicyRetiredDelivery.possiblySubmitted) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.enters == 1)
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
