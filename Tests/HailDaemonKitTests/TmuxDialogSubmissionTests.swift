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
        await #expect(throws: mode.refusal) {
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
        await #expect(throws: mode.refusal) {
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
        let refusal = DialogSubmissionFixture.Mode.beforeRetry.refusal
        await #expect(throws: refusal) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.outcomes.all == [.failed])
        let calls = await harness.runner.calls
        #expect(calls.filter { $0.last == "Enter" }.count == 1)
        #expect(!calls.contains { $0.last == "Escape" })
        #expect(calls.filter(DialogSubmissionFixture.isInspection).count == 3)
    }

    // Public delivery forbids line breaks; the pane wraps the question and option onto separate rows.
    @Test(arguments: [
        (DialogSubmissionFixture.Mode.footerAtPrompt, "please mention esc to cancel"),
        (.questionAtPrompt, "Do you want to proceed? 1. Yes")
    ])
    func pastedDialogShapesVetoEnterAndTaintPane(_ mode: DialogSubmissionFixture.Mode, _ payload: String) async {
        let harness = DialogSubmissionFixture(mode, payload: payload).harness()
        await #expect(throws: mode.refusal) {
            try await harness.adapter.deliver(payload, to: "codex", binding: nil)
        }
        #expect(await harness.keys == [payload])
        #expect(harness.outcomes.all == [.failed])
        #expect(await harness.runner.calls.filter { $0.contains("send-keys") }.isEmpty)
        // Accepted availability cost: own dialog-shaped input leaves the pane tainted until haild restarts.
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == [payload])
    }

    @Test(arguments: [DialogSubmissionFixture.Mode.sameDialogAbovePrompt, .replacedPrompt])
    func realDialogStillVetoesEnter(_ mode: DialogSubmissionFixture.Mode) async {
        await assertDialogVeto(mode)
    }

    @Test func oldTranscriptPromptAboveReplacementDialogStillVetoesEnter() async {
        await assertDialogVeto(.oldPromptAboveReplacement)
    }

    private func assertDialogVeto(_ mode: DialogSubmissionFixture.Mode) async {
        let payload = "Do you want to proceed? 1. Yes"
        let harness = DialogSubmissionFixture(mode, payload: payload).harness()
        await #expect(throws: mode.refusal) {
            try await harness.adapter.deliver(payload, to: "codex", binding: nil)
        }
        #expect(await harness.keys == [payload])
        #expect(harness.outcomes.all == [.failed])
        #expect(await harness.runner.calls.filter { $0.contains("send-keys") }.isEmpty)
    }
}

/// Separate visible-screen captures do not consume cursor-observation frames in the existing scripted pane.
final class DialogSubmissionFixture: Sendable {
    enum Mode: Sendable {
        case clear, beforePaste, captureFailure, afterPaste, captureFailureAfterPaste, beforeRetry
        case footerAtPrompt, questionAtPrompt, sameDialogAbovePrompt, replacedPrompt, oldPromptAboveReplacement

        var refusal: AdapterError {
            let cause: DialogBlock.Cause
            switch self {
            case .captureFailure, .captureFailureAfterPaste: cause = .uninspectable
            case .questionAtPrompt, .sameDialogAbovePrompt, .replacedPrompt, .oldPromptAboveReplacement:
                cause = .known(title: "a tool permission dialog")
            case .footerAtPrompt: cause = .known(title: "a dialog")
            default: cause = .known(title: "Computer Use needs macOS permissions")
            }
            let effects: DialogBlock.Effects
            switch self {
            case .clear, .beforePaste, .captureFailure: effects = .none
            case .beforeRetry: effects = .enterMayHaveExecuted
            default: effects = .pasteMayHaveExecuted
            }
            return .blockedByDialog(DialogBlock(cause: cause, effects: effects))
        }
    }
    private let inspections = Mutex(0)
    private let mode: Mode
    private let pane: ScriptedPane
    private let payload: String

    init(_ mode: Mode, payload: String = "synthetic input") {
        self.mode = mode
        self.payload = payload
        if mode == .beforeRetry {
            pane = ScriptedPane(afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen])
        } else {
            let neverDrawn = mode == .afterPaste || mode == .captureFailureAfterPaste
            let typed = Self.inputBox(payload.replacingOccurrences(of: "? 1.", with: "?\n1.") + "▌")
            pane = ScriptedPane(stale: neverDrawn ? .max : 0, typed: typed)
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
            if count == 2, let capture = self.payloadCapture() { return capture }
            return CommandResult(exitCode: 0, stdout: Self.inputBox("ordinary prompt"))
        }
        return EvidenceHarness(runner, timing: EvidenceHarness.timing(settleLimit: .milliseconds(40)))
    }

    // Claude Code 2.1.319 uses a ❯ prompt between rules spanning the full pane width.
    private static func inputBox(_ text: String) -> String {
        let rule = String(repeating: "─", count: 80)
        return "\(rule)\n❯ \(text)\n\(rule)\n"
    }

    private func payloadCapture() -> CommandResult? {
        let wrapped = payload.replacingOccurrences(of: "? 1.", with: "?\n1.")
        let input = Self.inputBox(wrapped)
        let screen: String
        switch mode {
        case .footerAtPrompt, .questionAtPrompt: screen = input
        case .sameDialogAbovePrompt: screen = wrapped + "\n" + input
        case .replacedPrompt: screen = wrapped
        case .oldPromptAboveReplacement: screen = "> old user prompt\n" + wrapped
        default: return nil
        }
        return CommandResult(exitCode: 0, stdout: screen)
    }
}
