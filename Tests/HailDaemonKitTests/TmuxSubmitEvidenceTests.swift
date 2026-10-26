import Testing
@testable import HailDaemonKit

/// #894: every submit outcome reaches the error log as a token, with the pane named by an opaque ordinal.
@Suite(.timeLimit(.minutes(1))) struct TmuxSubmitEvidenceTests {
    private static let synthetic = "synthetic input"
    private static func timing(settleLimit: Duration = .seconds(5)) -> TmuxSubmitTiming {
        EvidenceHarness.timing(settleLimit: settleLimit)
    }

    /// The confirmation scripts, with virtual deadlines including both retry paths (#910, #917).
    private static func script(for outcome: TmuxSubmitOutcome) -> (ScriptedPane, TmuxSubmitTiming) {
        let (absorbed, typed) = (ScriptedPane.absorbedScreen, ScriptedPane.typedScreen)
        switch outcome {
        case .confirmed: return (ScriptedPane(), timing())
        case .retried: return (ScriptedPane(afterEnter: [absorbed, ScriptedPane.submittedScreen]), timing())
        case .unverifiable: return (ScriptedPane(afterEnter: [typed]), timing())
        case .unsettled:
            let pane = ScriptedPane(baseline: ScriptedPane.submittedScreen, stale: .max)
            return (pane, timing(settleLimit: .milliseconds(40)))
        case .failed: return (ScriptedPane(afterEnter: [absorbed, ScriptedPane.absorbedTwiceScreen]), timing())
        }
    }

    @Test(arguments: ["confirmed", "retried", "unverifiable", "unsettled", "failed"])
    func everySubmitOutcomeIsLogged(outcome: String) async throws {
        let (pane, timing) = Self.script(for: try #require(TmuxSubmitOutcome(rawValue: outcome)))
        let harness = EvidenceHarness(pane, timing: timing)

        _ = try? await harness.adapter.deliver(Self.synthetic, to: "codex", binding: nil)

        #expect(harness.evidence.lines == ["tmux_submit pane=p1 outcome=\(outcome)"])
        #expect(harness.outcomes.all.map(\.rawValue) == [outcome], "the submit observer hears it as before")
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic])
    }

    @Test func eachPaneGetsItsOwnOpaqueOrdinal() async throws {
        let pane = ScriptedPane()
        let harness = EvidenceHarness(pane, timing: Self.timing())

        // The scripted pane answers for both sessions (%2, then %1, then %2 again); each starts from an empty input.
        for target in ["codex", "claude-hail", "codex"] {
            pane.reset(baseline: ScriptedPane.oldScreen)
            try await harness.adapter.deliver(Self.synthetic, to: target, binding: nil)
        }

        #expect(harness.evidence.lines == [
            "tmux_submit pane=p1 outcome=confirmed", "tmux_submit pane=p2 outcome=confirmed",
            "tmux_submit pane=p1 outcome=confirmed"
        ])
        harness.evidence.expectTokensOnly(excluding: [Self.synthetic, "codex", "claude", "hail"])
    }
}
