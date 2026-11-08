import Synchronization
import Testing
@testable import HailDaemonKit

extension TmuxRefusalEvidenceTests {
    @Test func rebindingAfterPasteKeepsUnsubmittedEvidenceAndStickyRefusal() async throws {
        let pane = ScriptedPane()
        let rebound = Mutex(false)
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions"), rebound.withLock({ $0 }) {
                return CommandResult(exitCode: 0, stdout: ScriptedPane.rebound)
            }
            let result = pane.respond(arguments)
            if arguments.contains("paste-buffer") { rebound.withLock { $0 = true } }
            return result
        }
        let harness = EvidenceHarness(runner, timing: EvidenceHarness.timing())
        await #expect(throws: AdapterError.rebound("codex")) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: "$2@1758230001/%2:502")
        }
        #expect(harness.outcomes.all.isEmpty)
        #expect(harness.evidence.lines.isEmpty)
        rebound.withLock { $0 = false }
        pane.reset(baseline: ScriptedPane.oldScreen)
        let calls = await runner.calls.count
        for _ in 0..<2 {
            await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
                try await harness.adapter.deliver("later input", to: "codex", binding: nil)
            }
        }
        let lines = harness.evidence.lines
        try #require(lines.count == 2)
        for line in lines {
            #expect(line.hasPrefix(
                "tmux_input_pending reason=tainted pane=p1 pending_chars=none placeholder=none own_insert=unobserved"
                    + " own_age_s="
            ))
            #expect(line.hasSuffix(" own_submitted=false last_submit=none"))
        }
        let later = await runner.calls.dropFirst(calls)
        #expect(later.count == 2)
        #expect(later.allSatisfy { $0.contains("list-sessions") })
        #expect(await harness.keys == ["synthetic input"])
        harness.evidence.expectTokensOnly(excluding: ["synthetic input", "later input"])
    }
}
