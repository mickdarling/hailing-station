import Testing
@testable import HailDaemonKit

/// #917: the Part 12 repro's stalled tmux calls must not spend a scripted probe's deadlines.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TmuxSubmitClockTests {
    @Test(arguments: ["confirmed", "retried", "failed"])
    func aStalledRunnerKeepsTheScriptedOutcome(outcome: String) async throws {
        let after: [String]
        switch outcome {
        case "retried": after = [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen]
        case "failed": after = [ScriptedPane.absorbedScreen, ScriptedPane.absorbedTwiceScreen]
        default: after = [ScriptedPane.submittedScreen]
        }
        let pane = ScriptedPane(afterEnter: after)
        let runner = FakeCommandRunner(delay: .milliseconds(600)) { pane.respond($0) }
        // Three polls per confirm window keep this deliberately slow regression bounded in real time too.
        let timing = TmuxSubmitTiming(
            settleFloor: .milliseconds(50), pollInterval: .milliseconds(200), quiet: .milliseconds(150),
            settleLimit: .seconds(4), confirmLimit: .milliseconds(500)
        )
        let harness = EvidenceHarness(runner, timing: timing)
        if outcome == "failed" {
            await #expect(throws: AdapterError.self) {
                try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
            }
            await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
                try await harness.adapter.deliver("later input", to: "codex", binding: nil)
            }
        } else {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(harness.outcomes.all.map(\.rawValue) == [outcome])
        #expect(harness.evidence.lines("tmux_submit") == ["tmux_submit pane=p1 outcome=\(outcome)"])
        let enters = outcome == "confirmed" ? ["Enter"] : ["Enter", "Enter"]
        #expect(await harness.keys == ["synthetic input"] + enters)
    }
}
