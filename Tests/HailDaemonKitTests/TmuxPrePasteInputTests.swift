import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #306 review (Codex, on 12001cdf): text at the cursor that the pre-check alone would miss.
@Suite struct TmuxPrePasteInputTests {
    private static let timing = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
        settleLimit: .milliseconds(50), confirmLimit: .milliseconds(60), clearLimit: .milliseconds(120)
    )

    /// A pane whose screen the test sets; `-J` captures of the rows around the cursor answer `joined`.
    private final class Pane: Sendable {
        let screen: Mutex<String>
        let joined: Mutex<String>
        let showAfterFill = Mutex<String?>(nil)
        init(_ screen: String, joined: String = "") {
            self.screen = Mutex(screen)
            self.joined = Mutex(joined)
        }
        func respond(_ arguments: [String]) -> CommandResult {
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("set-buffer"), let later = showAfterFill.withLock({ $0 }) {
                screen.withLock { $0 = later }
            }
            if arguments.contains("-J") { return CommandResult(exitCode: 0, stdout: joined.withLock { $0 }) }
            if arguments.contains("capture-pane") { return CommandResult(exitCode: 0, stdout: screen.withLock { $0 }) }
            return CommandResult(exitCode: 0, stdout: "")
        }
    }

    @Test func textThatAppearsAtTheCursorWhileTheBufferFillsIsNeverPastedAfter() async throws {
        // Clear before the fill; while the buffer fills, the same text shows up at the cursor (a late echo of an
        // earlier attempt, or a draft). The look right before the paste refuses it.
        let pane = Pane("> \n2,0,80\n")
        pane.showAfterFill.withLock { $0 = "> synthetic input\n17,0,80\n" }
        let runner = FakeCommandRunner { pane.respond($0) }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: Self.timing)

        await #expect(throws: AdapterError.self) {
            try await adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        let calls = await runner.calls
        #expect(calls.contains { $0.contains("set-buffer") }, "the refusal came after the fill")
        #expect(!calls.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })
        #expect(calls.last?.contains("delete-buffer") == true, "the filled buffer is deleted")
        // Nothing was pasted, so the pane is not tainted: once clear, it takes the next delivery.
        pane.showAfterFill.withLock { $0 = nil }
        pane.screen.withLock { $0 = "> \n2,0,80\n" }
        try await adapter.deliver("other words", to: "codex", binding: nil)
        #expect(await runner.delivered == ["other words", "Enter"])
    }

    /// Pending input that exactly fills a 20-column row: readline leaves the cursor in column 0 of the next row.
    private static let filled = "$ echo 1234567890abc\n\n0,1,20\n"

    @Test func aTailWrappedToAColumnZeroCursorIsPendingAndRefusedWithNothingPasted() async throws {
        // tmux joins the full row into the cursor row: a soft wrap, so the text is still pending.
        let pane = Pane(Self.filled, joined: "$ echo 1234567890abc \n")
        let runner = FakeCommandRunner { pane.respond($0) }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: Self.timing)

        await #expect(throws: AdapterError.self) {
            try await adapter.deliver("echo 1234567890abc", to: "codex", binding: nil)
        }
        #expect(await runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
    }

    @Test func aCompletedLineThatExactlyFilledItsRowIsNotPending() async throws {
        // The same screen, but tmux keeps the rows apart: the line was ended (as `cat` or a shell leaves it).
        let pane = Pane(Self.filled, joined: "$ echo 1234567890abc\n\n")
        let runner = FakeCommandRunner { pane.respond($0) }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: Self.timing)

        try await adapter.deliver("echo 1234567890abc", to: "codex", binding: nil)

        #expect(await runner.delivered == ["echo 1234567890abc", "Enter"])
    }
}
