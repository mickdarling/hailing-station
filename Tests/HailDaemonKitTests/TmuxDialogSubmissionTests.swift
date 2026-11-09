import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct TmuxDialogSubmissionTests {
    @Test func filledBufferIsInspectedImmediatelyBeforeBracketedPaste() async throws {
        let harness = DialogSubmissionFixture(.clear).harness()
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        let calls = await harness.runner.calls
        let fill = try #require(calls.lastIndex { $0.contains("set-buffer") })
        let paste = try #require(calls.firstIndex { $0.contains("paste-buffer") })
        #expect(fill < paste - 1)
        #expect(DialogSubmissionFixture.isInspection(calls[paste - 1]))
        #expect(calls[paste].contains("-p"))
        let enter = try #require(calls.firstIndex { $0.last == "Enter" })
        #expect(paste < enter)
        #expect(DialogSubmissionFixture.isInspection(calls[enter - 1]))
        #expect(harness.outcomes.all == [.confirmed])
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test(arguments: [DialogSubmissionFixture.Mode.beforePaste, .captureFailure])
    func blockedPasteDeletesBufferAndSendsNoKeys(_ mode: DialogSubmissionFixture.Mode) async throws {
        let harness = DialogSubmissionFixture(mode).harness()
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        let calls = await harness.runner.calls
        #expect(calls.contains { $0.contains("set-buffer") })
        #expect(calls.contains { $0.contains("delete-buffer") })
        #expect(!calls.contains { $0.contains("paste-buffer") })
        #expect(!calls.contains { $0.contains("send-keys") })
        #expect(await harness.keys.isEmpty)
        #expect(harness.outcomes.all.isEmpty)
    }

    @Test(arguments: [DialogSubmissionFixture.Mode.afterPaste, .captureFailureAfterPaste])
    func timedOutAcceptanceCannotSendEnterAndInsertRemainsUnsubmitted(_ mode: DialogSubmissionFixture.Mode) async {
        let harness = DialogSubmissionFixture(mode).harness()
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input"])
        #expect(harness.outcomes.all == [.failed])
        let calls = await harness.runner.calls
        #expect(!calls.contains { $0.contains("send-keys") })
        // Sticky taint preserves the possible paste; there is no rollback, flush or speculative resubmission.
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }
        let evidence = harness.evidence.lines("tmux_input_pending")
        #expect(evidence.count == 1)
        #expect(evidence.first?.contains("own_submitted=false") == true)
        #expect(evidence.first?.contains("last_submit=none") == true)
        #expect(await harness.keys == ["synthetic input"])
    }

    @Test func dialogBeforeRetrySendsNoSecondEnter() async {
        let harness = DialogSubmissionFixture(.beforeRetry).harness()
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.outcomes.all == [.failed])
        let calls = await harness.runner.calls
        #expect(calls.filter { $0.last == "Enter" }.count == 1)
        #expect(!calls.contains { $0.last == "Escape" })
        #expect(calls.filter(DialogSubmissionFixture.isInspection).count == 3)
    }
}

/// Separate visible-screen captures do not consume cursor-observation frames in the existing scripted pane.
final class DialogSubmissionFixture: Sendable {
    enum Mode: Sendable { case clear, beforePaste, captureFailure, afterPaste, captureFailureAfterPaste, beforeRetry }
    private let inspections = Mutex(0)
    private let mode: Mode
    private let pane: ScriptedPane

    init(_ mode: Mode) {
        self.mode = mode
        if mode == .beforeRetry {
            pane = ScriptedPane(afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen])
        } else {
            let neverDrawn = mode == .afterPaste || mode == .captureFailureAfterPaste
            pane = ScriptedPane(stale: neverDrawn ? .max : 0)
        }
    }

    static func isInspection(_ arguments: [String]) -> Bool {
        arguments.contains("capture-pane") && !arguments.contains("display-message") && !arguments.contains("-J")
    }

    func harness() -> EvidenceHarness {
        let runner = FakeCommandRunner { arguments in
            guard Self.isInspection(arguments) else { return self.pane.respond(arguments) }
            let count = self.inspections.withLock { $0 += 1; return $0 }
            if self.mode == .captureFailure || self.mode == .captureFailureAfterPaste && count == 2 {
                return CommandResult(exitCode: 1, stdout: "")
            }
            let blocked = self.mode == .beforePaste || self.mode == .afterPaste && count == 2
            if blocked || self.mode == .beforeRetry && count == 3 {
                return CommandResult(exitCode: 0, stdout: "Computer Use needs macOS permissions\n")
            }
            return CommandResult(exitCode: 0, stdout: "> ordinary prompt\n")
        }
        return EvidenceHarness(runner, timing: EvidenceHarness.timing(settleLimit: .milliseconds(40)))
    }
}
