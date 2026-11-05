import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TmuxCurrentAuthorityTests {
    private static let timing = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(1), quiet: .milliseconds(2),
        settleLimit: .milliseconds(10), confirmLimit: .milliseconds(10), clearLimit: .milliseconds(10)
    )

    @Test func currentAuthorityConfirmsAndRetriesSubmit() async throws {
        let rig = try await TmuxAuthorityRig.make()
        for retry in [false, true] {
            let pane = ScriptedPane(afterEnter: retry
                ? [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen] : [ScriptedPane.submittedScreen])
            let harness = SubmitHarness(pane, timing: Self.timing)
            let adapter: any Adapter = harness.adapter
            try await adapter.deliver("synthetic input", to: "codex", binding: TmuxAuthorityRig.binding,
                                      authority: rig.authority)
            #expect(pane.enters == (retry ? 2 : 1))
            #expect(harness.log.all == [retry ? .retried : .confirmed])
        }
    }

    @Test func currentAuthorityCannotSubmitAfterARebindBetweenEnters() async throws {
        let rig = try await TmuxAuthorityRig.make()
        let pane = ScriptedPane(
            afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen], rebindAfterEnter: true
        )
        let harness = SubmitHarness(pane, timing: Self.timing)
        let adapter: any Adapter = harness.adapter
        await #expect(throws: AdapterError.rebound("codex")) {
            try await adapter.deliver("synthetic input", to: "codex", binding: TmuxAuthorityRig.binding,
                                      authority: rig.authority)
        }
        #expect(pane.enters == 1)
        pane.restoreListing()
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await adapter.deliver("later input", to: "codex", binding: TmuxAuthorityRig.binding,
                                      authority: rig.authority)
        }
    }

    @Test func currentAuthorityStillRefusesPendingInput() async throws {
        let rig = try await TmuxAuthorityRig.make()
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen)
        let harness = SubmitHarness(pane, timing: Self.timing)
        let adapter: any Adapter = harness.adapter
        await #expect(throws: AdapterError.inputPending(reason: .staleInput)) {
            try await adapter.deliver("synthetic input", to: "codex", binding: TmuxAuthorityRig.binding,
                                      authority: rig.authority)
        }
        #expect(await harness.keys.isEmpty)
    }

    @Test func currentAuthorityStillRefusesAgentOnlyPasteToAShell() async throws {
        let rig = try await TmuxAuthorityRig.make()
        rig.runner.leaveAgent()
        let text = try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
        let adapter: any Adapter = rig.adapter
        await #expect(throws: AdapterError.deliveryFailed(PastedContent.agentOnlyRefusal)) {
            try await adapter.deliver(text, to: "codex", binding: TmuxAuthorityRig.binding, authority: rig.authority)
        }
        #expect(rig.runner.pasted.isEmpty)
        #expect(rig.runner.enters == 0)
        try await rig.send()
        #expect(rig.runner.enters == 1)
    }

    @Test func unchangedAuthorityDeliversEverySanitizedLine() async throws {
        let rig = try await TmuxAuthorityRig.make()
        let outcome = try await rig.host.sendAuthorized(
            "one\ntwo", policyGeneration: rig.host.targetPolicy.snapshot(for: TmuxAuthorityRig.target),
            from: "test", expectedBinding: nil, context: nil
        )
        #expect(outcome == .delivered(["one", "two"]))
        #expect(rig.runner.pasted == ["one", "two"])
        #expect(rig.runner.enters == 2)
    }
}
