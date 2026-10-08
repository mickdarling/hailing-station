import Synchronization
import Testing
@testable import HailDaemonKit

/// A scripted pane for #83 and #304. Screens are written with `▌` where the cursor is. Before the first Enter,
/// observation 1 is the baseline (taken before any text); the next `stale` observations still show it (a busy
/// TUI that has not drawn the paste); the next `settling` observations each show a different frame; after that,
/// `typed`. After an Enter: the first `absorbed` Enters turn into a newline in the input, the next `swallowed`
/// leave the screen as it was, and a later one shows `submitted` (or `lineEnded`, a terminal ending the line).
final class ScriptedPane: Sendable {
    static let oldScreen = "> ▌"
    static let typedScreen = "> synthetic input▌"
    static let absorbedScreen = "> synthetic input\n  ▌"
    /// The prompt echoed above an empty input, as a TUI transcript shows it.
    static let submittedScreen = "> synthetic input\n\n> ▌"
    static let lineEndedScreen = "> synthetic input\n▌"
    static let rebound = "$1|1758230000|%1|501|claude-hail\n$2|1758230001|%8|808|codex\n"
    private struct State {
        var captures = 0
        var enters = 0
        var listing = twoSessions
        var baseline: String
    }
    private let state: Mutex<State>
    private let stale: Int
    private let settling: Int
    private let typed: String
    private let absorbed: Int
    private let swallowed: Int
    private let submitted: String
    private let readableAfterEnter: Bool
    private let rebindAfterEnter: Bool

    init(
        baseline: String = oldScreen, stale: Int = 0, settling: Int = 0, typed: String = typedScreen,
        absorbed: Int = 0, swallowed: Int = 0, submitted: String = submittedScreen,
        readableAfterEnter: Bool = true, rebindAfterEnter: Bool = false
    ) {
        state = Mutex(State(baseline: baseline))
        self.stale = stale
        self.settling = settling
        self.typed = typed
        self.absorbed = absorbed
        self.swallowed = swallowed
        self.submitted = submitted
        self.readableAfterEnter = readableAfterEnter
        self.rebindAfterEnter = rebindAfterEnter
    }

    var enters: Int { state.withLock { $0.enters } }
    func restoreListing() { state.withLock { $0.listing = twoSessions } }
    /// What the next delivery's baseline shows; the capture count restarts.
    func reset(baseline: String) { state.withLock { $0.baseline = baseline; $0.captures = 0; $0.enters = 0 } }

    func respond(_ arguments: [String]) -> CommandResult {
        state.withLock { state in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: state.listing) }
            if arguments.contains("capture-pane") {
                guard state.enters == 0 || readableAfterEnter else {
                    return CommandResult(exitCode: 1, stdout: "", stderr: "can't find pane")
                }
                state.captures += 1
                return CommandResult(exitCode: 0, stdout: Self.render(screen(state)))
            }
            if arguments.last == "Enter" {
                state.enters += 1
                if rebindAfterEnter { state.listing = Self.rebound }
            }
            return CommandResult(exitCode: 0, stdout: "")
        }
    }

    private func screen(_ state: State) -> String {
        if state.enters > 0 {
            if state.enters <= absorbed { return Self.absorbedScreen }
            return state.enters - absorbed <= swallowed ? (absorbed > 0 ? Self.absorbedScreen : typed) : submitted
        }
        let afterBaseline = state.captures - 1
        if afterBaseline <= stale { return state.baseline }
        if afterBaseline - stale <= settling { return "> synthetic inp (frame \(state.captures))▌" }
        return typed
    }

    /// `capture-pane -p` rows followed by the `display-message` cursor line, as the adapter's observation reads.
    static func render(_ marked: String) -> String {
        let rows = marked.components(separatedBy: "\n")
        let y = rows.firstIndex { $0.contains("▌") } ?? 0
        let x = rows[y].prefix { $0 != "▌" }.count
        let plain = rows.map { $0.replacingOccurrences(of: "▌", with: "") }
        return plain.joined(separator: "\n") + "\n\(x),\(y)\n"
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

    /// Pasted texts and keys, in order.
    var keys: [String] { get async { await runner.delivered } }

    func capturesBeforeFirstEnter() async throws -> Int {
        let calls = await runner.calls
        let enter = try #require(calls.firstIndex { $0.last == "Enter" })
        return calls[..<enter].filter { $0.contains("capture-pane") }.count
    }
}
