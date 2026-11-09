import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic outcomes shared by admitted submissions, genuine failures and partial handoffs.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct HostSessionRetirementOutcomeTests {
    @Test(arguments: [AuthorityTmuxRunner.Checkpoint.paste, .enter], [(false, 1), (false, 2), (true, 1), (true, 2)])
    func admittedRetirementAndFailureOutcomesStayStable(
        checkpoint: AuthorityTmuxRunner.Checkpoint, scenario: (fails: Bool, lineCount: Int)
    ) async throws {
        let (fails, lineCount) = scenario
        let rig = try await TmuxAuthorityRig.make(checkpoint)
        defer { rig.runner.gate.fire() }
        if fails { rig.runner.failEnter() }
        let session = await session(rig.host, target: TmuxAuthorityRig.target)
        let text = lineCount == 1 ? "one" : "one\ntwo"
        let sending = Task { try await deliver(session, text: text, target: TmuxAuthorityRig.target) }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        let outcome = try await rig.runner.gate.finish(sending)
        let expected: HostDeliveryOutcome = !fails && lineCount == 1
            ? .delivered(request: nil) : .refused(.notAllowed, "target action was refused")
        #expect(outcome == expected)
        #expect(rig.runner.pasted == ["one"])
        #expect(rig.runner.enters == 1)
        rig.runner.setInput("")
        let next = try await deliver(session, text: "later input", target: TmuxAuthorityRig.target)
        let nextExpected: HostDeliveryOutcome = fails
            ? .inputPending(reason: "the target's input already holds unsent text") : .delivered(request: nil)
        #expect(next == nextExpected)
        if fails {
            let frame = sessionFrame(target: TmuxAuthorityRig.target, payload: .text(TextPayload(text: "phone input")))
            let control = try onlyControl(await session.receive(frame))
            #expect(control == .error(code: .notAllowed, message: "the target's input already holds unsent text"))
            #expect(rig.runner.pasted == ["one"])
            #expect(rig.runner.enters == 1)
        }
    }

    @Test(arguments: [0, 1])
    func genuineFailureAndPartialFailureKeepTheSameRefusal(delivered: Int) async throws {
        let adapter = FakeAdapter(
            kind: "tmux", targets: [AdapterTarget(name: "a", binding: "b1")], failAfter: delivered
        )
        let host = try await HostSendTests().host(adapter, sanitizing: SanitizePolicy(newlines: .split))
        let session = await session(host, target: "tmux:a")
        let outcome = try await deliver(session, text: "one\ntwo", target: "tmux:a")
        #expect(outcome == .refused(.notAllowed, "target action was refused"))
        #expect(await adapter.deliveries.map(\.text) == (delivered == 0 ? [] : ["one"]))
    }

    private func session(_ host: HailHost, target: String) async -> HostSession {
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        await session.forceSelection(target)
        return session
    }

    private func deliver(_ session: HostSession, text: String, target: String) async throws -> HostDeliveryOutcome {
        let frame = sessionFrame(target: target, payload: .text(TextPayload(text: text)))
        let input = try await authorizedInput(session, frame, device: "test")
        return await session.deliver(input)
    }
}
