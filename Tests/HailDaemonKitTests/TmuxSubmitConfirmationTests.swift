import Synchronization
import Testing
@testable import HailDaemonKit

/// A scripted pane for #83: shows the typed text until an Enter is accepted, then the submitted screen. The
/// first `swallowed` Enters leave the screen exactly as it was, the way a TUI still handling a paste does.
/// `settling` captures before the first Enter return a screen still being redrawn.
final class ScriptedPane: Sendable {
    static let typedScreen = "> synthetic input"
    static let submittedScreen = "> synthetic input\n\n> "
    private struct State {
        var enters = 0
        var settling: Int
        var swallowed: Int
    }
    private let state: Mutex<State>
    private let readable: Bool

    init(swallowed: Int = 0, settling: Int = 0, readable: Bool = true) {
        state = Mutex(State(settling: settling, swallowed: swallowed))
        self.readable = readable
    }

    var enters: Int { state.withLock { $0.enters } }

    func respond(_ arguments: [String]) -> CommandResult {
        if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
        if arguments.contains("capture-pane") {
            guard readable else { return CommandResult(exitCode: 1, stdout: "", stderr: "can't find pane") }
            return CommandResult(exitCode: 0, stdout: screen())
        }
        if arguments.last == "Enter" { state.withLock { $0.enters += 1 } }
        return CommandResult(exitCode: 0, stdout: "")
    }

    private func screen() -> String {
        state.withLock { state in
            if state.enters == 0, state.settling > 0 {
                state.settling -= 1
                return "> synthetic inp" + String(repeating: ".", count: state.settling)
            }
            return state.enters > state.swallowed ? Self.submittedScreen : Self.typedScreen
        }
    }
}

@Suite struct TmuxSubmitConfirmationTests {
    private static let fast = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
    )

    private func adapter(_ pane: ScriptedPane) -> (TmuxAdapter, FakeCommandRunner) {
        let runner = FakeCommandRunner { pane.respond($0) }
        return (TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: Self.fast), runner)
    }

    private func keys(_ runner: FakeCommandRunner) async -> [String] {
        await runner.calls.compactMap { $0.contains("send-keys") ? $0.last : nil }
    }

    @Test func anAcceptedEnterIsSentOnceAfterThePaneIsCaptured() async throws {
        let pane = ScriptedPane()
        let (adapter, runner) = adapter(pane)

        try await adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await keys(runner) == ["synthetic input", "Enter"])
        let calls = await runner.calls
        let enter = try #require(calls.firstIndex { $0.last == "Enter" })
        #expect(calls[..<enter].contains(["tmux", "capture-pane", "-p", "-t", "%2"]))
    }

    @Test func theEnterWaitsUntilThePaneStopsChanging() async throws {
        let pane = ScriptedPane(settling: 4)
        let (adapter, runner) = adapter(pane)

        try await adapter.deliver("synthetic input", to: "codex", binding: nil)

        let calls = await runner.calls
        let enter = try #require(calls.firstIndex { $0.last == "Enter" })
        // Four captures of a screen still being redrawn, then two identical ones before the Enter.
        #expect(calls[..<enter].filter { $0.contains("capture-pane") }.count == 6)
        #expect(await keys(runner) == ["synthetic input", "Enter"])
    }

    @Test func aSwallowedEnterIsRetriedOnceAfterReverifyingTheTarget() async throws {
        let pane = ScriptedPane(swallowed: 1)
        let (adapter, runner) = adapter(pane)

        try await adapter.deliver("synthetic input", to: "codex", binding: "$2@1758230001/%2:502")

        #expect(await keys(runner) == ["synthetic input", "Enter", "Enter"])
        let calls = await runner.calls
        let enters = calls.indices.filter { calls[$0].last == "Enter" }
        let between = calls[enters[0]..<enters[1]]
        #expect(between.contains { $0.contains("list-sessions") }, "identity re-checked before the retry")
        #expect(between.contains { $0.contains("capture-pane") }, "the retry follows an observed unchanged pane")
    }

    @Test func noRetryWhenTheFirstEnterWasAccepted() async throws {
        let pane = ScriptedPane()
        let (adapter, runner) = adapter(pane)

        try await adapter.deliver("synthetic input", to: "codex", binding: nil)
        // Well past the confirm window: nothing else is sent once the pane has reacted.
        try await Task.sleep(for: .milliseconds(150))

        #expect(pane.enters == 1)
        #expect(await keys(runner) == ["synthetic input", "Enter"])
    }

    @Test func anEnterNeverObservedFailsAfterOneRetryAndTaintsThePane() async throws {
        let pane = ScriptedPane(swallowed: .max)
        let (adapter, runner) = adapter(pane)

        await #expect(throws: AdapterError.self) {
            try await adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        await #expect(throws: AdapterError.self) {
            try await adapter.deliver("later input", to: "codex", binding: nil)
        }
        #expect(await keys(runner) == ["synthetic input", "Enter", "Enter"])
    }

    @Test func anUnreadablePaneKeepsTheSingleEnter() async throws {
        let pane = ScriptedPane(swallowed: 1, readable: false)
        let (adapter, runner) = adapter(pane)

        try await adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await keys(runner) == ["synthetic input", "Enter"])
    }
}
