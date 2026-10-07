import Synchronization
import Testing
@testable import HailDaemonKit

/// A scripted pane for #83. Before the first Enter, capture 1 is the baseline (taken before any text) and
/// shows `oldScreen`; the next `stale` captures still show it (a busy TUI that has not redrawn); the next
/// `settling` captures each show a different frame (the paste still being drawn); after that, `typedScreen`.
/// The first `swallowed` Enters leave the screen exactly as it was; a later one shows `submittedScreen`.
final class ScriptedPane: Sendable {
    static let oldScreen = "> "
    static let typedScreen = "> synthetic input"
    static let submittedScreen = "> synthetic input\n\n> "
    static let rebound = "$1|1758230000|%1|501|claude-hail\n$2|1758230001|%8|808|codex\n"
    private struct State {
        var captures = 0
        var enters = 0
        var listing = twoSessions
    }
    private let state = Mutex(State())
    private let stale: Int
    private let settling: Int
    private let swallowed: Int
    private let readableAfterEnter: Bool
    private let rebindAfterEnter: Bool

    init(
        stale: Int = 0, settling: Int = 0, swallowed: Int = 0,
        readableAfterEnter: Bool = true, rebindAfterEnter: Bool = false
    ) {
        self.stale = stale
        self.settling = settling
        self.swallowed = swallowed
        self.readableAfterEnter = readableAfterEnter
        self.rebindAfterEnter = rebindAfterEnter
    }

    var enters: Int { state.withLock { $0.enters } }
    func restoreListing() { state.withLock { $0.listing = twoSessions } }

    func respond(_ arguments: [String]) -> CommandResult {
        state.withLock { state in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: state.listing) }
            if arguments.contains("capture-pane") {
                guard state.enters == 0 || readableAfterEnter else {
                    return CommandResult(exitCode: 1, stdout: "", stderr: "can't find pane")
                }
                state.captures += 1
                return CommandResult(exitCode: 0, stdout: screen(state))
            }
            if arguments.last == "Enter" {
                state.enters += 1
                if rebindAfterEnter { state.listing = Self.rebound }
            }
            return CommandResult(exitCode: 0, stdout: "")
        }
    }

    private func screen(_ state: State) -> String {
        guard state.enters == 0 else { return state.enters > swallowed ? Self.submittedScreen : Self.typedScreen }
        let afterBaseline = state.captures - 1
        if afterBaseline <= stale { return Self.oldScreen }
        if afterBaseline - stale <= settling { return "> synthetic inp (frame \(state.captures))" }
        return Self.typedScreen
    }
}

/// Collects the adapter's submit outcomes.
final class OutcomeLog: Sendable {
    private let storage = Mutex<[TmuxSubmitOutcome]>([])
    var all: [TmuxSubmitOutcome] { storage.withLock { $0 } }
    func append(_ outcome: TmuxSubmitOutcome) { storage.withLock { $0.append(outcome) } }
}

/// A tmux adapter over a scripted pane, with its runner and the outcomes it reported.
struct SubmitHarness {
    let adapter: TmuxAdapter
    let runner: FakeCommandRunner
    let log: OutcomeLog

    init(_ pane: ScriptedPane, timing: TmuxSubmitTiming) {
        let runner = FakeCommandRunner { pane.respond($0) }
        let log = OutcomeLog()
        self.runner = runner
        self.log = log
        adapter = TmuxAdapter(
            runner: runner, pollInterval: nil, submitTiming: timing, submitObserver: { log.append($0) }
        )
    }

    var keys: [String] {
        get async { await runner.calls.compactMap { $0.contains("send-keys") ? $0.last : nil } }
    }

    func capturesBeforeFirstEnter() async throws -> Int {
        let calls = await runner.calls
        let enter = try #require(calls.firstIndex { $0.last == "Enter" })
        return calls[..<enter].filter { $0.contains("capture-pane") }.count
    }
}
