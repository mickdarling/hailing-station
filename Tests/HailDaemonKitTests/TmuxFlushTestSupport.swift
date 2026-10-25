import Synchronization
import Testing
@testable import HailDaemonKit

/// A scripted agent prompt for #894's flush: a one-line editor behind `❯ ` that takes `End` and `BSpace` as a line
/// editor does (or ignores BSpace), and records every key it is sent. `Escape` or `C-c` would be recorded as an interrupt. Its captures
/// drop trailing blanks, as `capture-pane -p` does. `agent` is what tmux reports for the pane's foreground command:
/// false refuses the probe and the server-side gate alike. `onEnd` changes the screen when the End arrives.
final class FlushPane: Sendable {
    struct State {
        var input: [Character]
        var cursor: Int
        var agent = true
        var prompt = "❯ "
        var hint = ""
        var ignoresBackspace = false
        var below: [String] = ["────"]
        var listing = twoSessions
        var keys: [String] = []
        var onEnd: (@Sendable (inout State) -> Void)?
    }

    let state: Mutex<State>

    init(_ input: String, cursor: Int? = nil) {
        state = Mutex(State(input: Array(input), cursor: cursor ?? input.count))
    }

    var keys: [String] { state.withLock { $0.keys } }

    func respond(_ arguments: [String]) -> CommandResult {
        state.withLock { state in
            switch arguments.first {
            case "list-sessions": return CommandResult(exitCode: 0, stdout: state.listing)
            case "capture-pane": return CommandResult(exitCode: 0, stdout: Self.render(state))
            case "display-message": return CommandResult(exitCode: 0, stdout: state.agent ? "1\n" : "0\n")
            case "if-shell":
                guard state.agent else { return CommandResult(exitCode: 0, stdout: "hail-flush-not-agent\n") }
                for key in arguments[5].split(separator: " ").dropFirst(3).map(String.init) {
                    Self.press(key, &state)
                }
                return CommandResult(exitCode: 0, stdout: "")
            case "send-keys":
                for key in arguments.dropFirst(3) { Self.press(key, &state) }
                return CommandResult(exitCode: 0, stdout: "")
            default:
                return CommandResult(exitCode: 1, stdout: "", stderr: "unexpected")
            }
        }
    }

    private static func press(_ key: String, _ state: inout State) {
        state.keys.append(key)
        switch key {
        case "End":
            state.cursor = state.input.count
            state.onEnd?(&state)
        case "BSpace" where state.cursor > 0 && !state.ignoresBackspace:
            state.input.remove(at: state.cursor - 1)
            state.cursor -= 1
        default:
            break
        }
    }

    /// The rows, trailing blanks dropped, and the cursor line (ASCII input, so characters are columns).
    private static func render(_ state: State) -> String {
        let shown = state.input.isEmpty ? state.hint : String(state.input)
        let row = String((state.prompt + shown).reversed().drop(while: \.isWhitespace).reversed())
        return ([row] + state.below).joined(separator: "\n") + "\n\(state.prompt.count + state.cursor),0,80\n"
    }
}

/// A tmux adapter over a flush pane, with the evidence it reported (a flush reports none).
struct FlushHarness {
    let pane: FlushPane
    let runner: FakeCommandRunner
    let adapter: TmuxAdapter
    let evidence = EvidenceLog()
    static let binding = "$1@1758230000/%1:501"

    init(_ pane: FlushPane) {
        self.pane = pane
        runner = FakeCommandRunner { pane.respond($0) }
        let evidence = evidence
        adapter = TmuxAdapter(runner: runner, pollInterval: nil, evidenceObserver: { evidence.append($0) })
    }

    /// Every call that could reach the pane: `send-keys`, `if-shell`, `paste-buffer`, `set-buffer`.
    var sends: [[String]] {
        get async {
            await runner.calls.filter { call in
                ["send-keys", "if-shell", "paste-buffer", "set-buffer"].contains { call.contains($0) }
            }
        }
    }

    /// Escape, C-c or any other interrupt never appears in any argument of any call, whatever the path.
    func expectNoInterrupt(sourceLocation: SourceLocation = #_sourceLocation) async {
        for call in await runner.calls {
            for argument in call where ["Escape", "C-c", "C-[", "\u{1B}"].contains(where: argument.contains) {
                Issue.record("interrupt key sent: \(call)", sourceLocation: sourceLocation)
            }
        }
        #expect(pane.keys.allSatisfy { ["End", "BSpace"].contains($0) }, sourceLocation: sourceLocation)
    }

    /// The exact gated command for `keys` to pane `%1`.
    static func gated(_ keys: [String]) -> [String] {
        ["tmux", "if-shell", "-F", "-t", "%1", TmuxAdapter.isAgentFormat,
         (["send-keys", "-t", "%1"] + keys).joined(separator: " "), "display-message -p hail-flush-not-agent"]
    }
}
