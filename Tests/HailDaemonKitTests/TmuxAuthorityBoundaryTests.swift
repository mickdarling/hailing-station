import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TmuxAuthorityBoundaryTests {
    @Test func alreadyRetiredAuthorityIssuesNoTmuxCommands() async throws {
        let rig = try await TmuxAuthorityRig.make()
        try await rig.retire()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) { try await rig.send() }
        #expect(rig.runner.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func retirementDuringFinalPrePasteObservationPastesNothing(framed: Bool) async throws {
        let rig = try await TmuxAuthorityRig.make(.prePaste)
        defer { rig.runner.gate.fire() }
        let text = framed ? try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
            : "synthetic input"
        let sending = Task {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver(text, to: "codex", binding: TmuxAuthorityRig.binding, authority: rig.authority)
        }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted.isEmpty)
        #expect(rig.runner.enters == 0)
    }

    @Test func retirementDuringFinalBindingCheckCompletesTheSubmission() async throws {
        let rig = try await TmuxAuthorityRig.make(.verification)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        try await rig.runner.gate.finish(sending)
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.input.isEmpty)
        #expect(rig.runner.enters == 1)
    }

    @Test(arguments: [false, true])
    func retirementBeforeRetryKeepsTheSingleRetryBudget(framed: Bool) async throws {
        let rig = try await TmuxAuthorityRig.make(.enter)
        rig.runner.requireRetry()
        defer { rig.runner.gate.fire() }
        let text = framed ? try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
            : "synthetic input"
        let sending = Task {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver(text, to: "codex", binding: TmuxAuthorityRig.binding, authority: rig.authority)
        }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: PolicyRetiredDelivery.possiblySubmitted) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.enters == 2)
        #expect(rig.runner.calls.filter { $0.joined(separator: " ").contains("send-keys") }.count == 2)
        #expect(!rig.log.all.contains { $0.event == "tmux_policy_retired_unsent" })
    }

    @Test func collapsedAgentPasteCompletesAfterRetirement() async throws {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let text = try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
        let sending = Task {
            try await rig.adapter.deliver(
                text, to: "codex", binding: TmuxAuthorityRig.binding, authority: rig.authority
            )
        }
        try await rig.runner.gate.waitUntilSuspended()
        rig.runner.collapsePaste()
        try await rig.retire()
        try await rig.runner.gate.finish(sending)
        #expect(rig.runner.enters == 1)
        #expect(!rig.log.all.contains { $0.event == "tmux_policy_retired_unsent" })
    }

    @Test func retirementAfterPasteCompletesBeforeTheNextTerminalRefusal() async throws {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: TmuxAuthorityRig.target))))
        let frame = sessionFrame(target: TmuxAuthorityRig.target, payload: .text(TextPayload(text: "synthetic input")))
        let sending = Task {
            let input = try await authorizedInput(session, frame, device: "test")
            return await session.deliver(input)
        }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        let outcome = try await rig.runner.gate.finish(sending)
        #expect(outcome == HostDeliveryOutcome.delivered(request: nil))
        let calls = rig.runner.calls.count
        let control = try onlyControl(await session.receive(frame))
        guard case ControlPayload.error(code: .notAllowed, message: _, turn: _) = control else {
            Issue.record("retired authority must refuse the next submission")
            return
        }
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.calls.count == calls)
        #expect(rig.runner.enters == 1)
        #expect(rig.runner.input.isEmpty)
    }
}
