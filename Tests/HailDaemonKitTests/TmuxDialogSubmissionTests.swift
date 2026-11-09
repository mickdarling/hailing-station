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
        let refusal = AdapterError.deliveryFailed("target is blocked by Computer Use needs macOS permissions")
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
        "please mention esc to cancel", "Do you want to proceed? 1. Yes"
    ])
    func payloadDialogTextAtPromptStillGetsEnter(_ payload: String) async throws {
        let harness = DialogSubmissionFixture(.payloadAtPrompt, payload: payload).harness()
        try await harness.adapter.deliver(payload, to: "codex", binding: nil)
        #expect(await harness.keys == [payload, "Enter"])
        #expect(harness.outcomes.all == [.confirmed])
    }

    @Test(arguments: [DialogSubmissionFixture.Mode.sameDialogAbovePrompt, .replacedPrompt, .missingCursorAfterPaste])
    func realDialogOrMissingCursorStillVetoesEnter(_ mode: DialogSubmissionFixture.Mode) async {
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
        case payloadAtPrompt, sameDialogAbovePrompt, replacedPrompt, missingCursorAfterPaste

        var refusal: AdapterError {
            switch self {
            case .captureFailure, .captureFailureAfterPaste, .missingCursorAfterPaste:
                .deliveryFailed("target dialog state could not be inspected")
            case .sameDialogAbovePrompt, .replacedPrompt:
                .deliveryFailed("target is blocked by a tool permission dialog")
            default: .deliveryFailed("target is blocked by Computer Use needs macOS permissions")
            }
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
            let typed = "> " + payload.replacingOccurrences(of: "? 1.", with: "?\n1.") + "▌"
            pane = ScriptedPane(stale: neverDrawn ? .max : 0, typed: typed)
        }
    }

    static func isInspection(_ arguments: [String]) -> Bool {
        arguments.contains("capture-pane") && arguments.last == "#{cursor_x},#{cursor_y}"
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
                return CommandResult(exitCode: 0, stdout: "Computer Use needs macOS permissions\n0,0\n")
            }
            if count == 2, let capture = self.payloadCapture() { return capture }
            return CommandResult(exitCode: 0, stdout: "> ordinary prompt\n0,0\n")
        }
        return EvidenceHarness(runner, timing: EvidenceHarness.timing(settleLimit: .milliseconds(40)))
    }

    private func payloadCapture() -> CommandResult? {
        let wrapped = payload.replacingOccurrences(of: "? 1.", with: "?\n1.")
        let input = "> " + wrapped
        let row = wrapped.components(separatedBy: "\n").count - 1
        let screen: String
        switch mode {
        case .payloadAtPrompt: screen = input + "\n0,\(row)\n"
        case .sameDialogAbovePrompt: screen = wrapped + "\n" + input + "\n0,\(2 * row + 1)\n"
        case .replacedPrompt: screen = wrapped + "\n0,\(row)\n"
        case .missingCursorAfterPaste: screen = input + "\n"
        default: return nil
        }
        return CommandResult(exitCode: 0, stdout: screen)
    }
}
