import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic tmux only. A command can finish its side effect, then park its reply on a dedicated executor.
final class AuthorityTmuxRunner: CommandRunner {
    enum Checkpoint { case none, fill, prePaste, paste, verification, enter, enterRefusal }
    private struct State {
        var calls: [[String]] = []
        var buffers: [String: String] = [:]
        var input: String
        var pasted: [String] = []
        var entered = 0
        var stopped = false
        var rebound = false
        var collapsed = false
        var agent = true
        var retry = false
        var enterFails = false
    }
    private let state: Mutex<State>
    let gate = PolicyWriteGate()
    private let checkpoint: Checkpoint
    private let delivery: Int

    init(_ checkpoint: Checkpoint = .none, input: String = "", delivery: Int = 1) {
        self.delivery = delivery
        self.checkpoint = checkpoint
        state = Mutex(State(input: input))
    }

    var calls: [[String]] { state.withLock { $0.calls } }
    var pasted: [String] { state.withLock { $0.pasted } }
    var input: String { state.withLock { $0.input } }
    var enters: Int { state.withLock { $0.entered } }
    func collapsePaste() { state.withLock { $0.collapsed = true } }
    func requireRetry() { state.withLock { $0.retry = true } }
    func leaveAgent() { state.withLock { $0.agent = false } }
    func rebind() { state.withLock { $0.rebound = true } }
    func setInput(_ text: String) { state.withLock { $0.input = text } }
    func failEnter() { state.withLock { $0.enterFails = true } }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let reply = state.withLock { state -> (CommandResult, Bool) in
            let argv = arguments.first == "-L" ? Array(arguments.dropFirst(2)) : arguments
            state.calls.append(argv)
            let refusesEnter = checkpoint == .enterRefusal && argv.first == "if-shell"
                && argv[5].hasPrefix("send-keys") && (!state.retry || state.entered > 0)
            if argv.first == "if-shell", !state.agent || refusesEnter {
                let marker = argv.last?.components(separatedBy: " ").last ?? ""
                let pause = refusesEnter && !state.stopped
                if pause { state.stopped = true }
                return (CommandResult(exitCode: 0, stdout: marker), pause)
            }
            let command = argv.first == "if-shell" ? argv[5].components(separatedBy: " ") : argv
            let response = respond(command, state: &state)
            let ordinal = state.pasted.count + ([Checkpoint.fill, .prePaste].contains(checkpoint) ? 1 : 0)
            let pause = response.1 && !state.stopped && ordinal >= delivery
            if pause { state.stopped = true }
            return (response.0, pause)
        }
        if reply.1 {
            await Task(executorPreference: gate.executor) { self.gate.suspend() }.value
        }
        return reply.0
    }

    private func respond(_ arguments: [String], state: inout State) -> (CommandResult, Bool) {
        var output = "", reached = false
        switch arguments.first {
        case "list-sessions":
            output = state.rebound ? ScriptedPane.rebound : twoSessions
            reached = checkpoint == .verification && !state.pasted.isEmpty
        case "set-buffer":
            fillBuffer(arguments, state: &state)
            reached = checkpoint == .fill
        case "paste-buffer":
            if let flag = arguments.firstIndex(of: "-b") {
                let text = state.buffers[arguments[flag + 1]] ?? ""
                state.input += text
                state.pasted.append(text)
            }
            reached = checkpoint == .paste
        case "send-keys":
            press(arguments, state: &state)
            reached = checkpoint == .enter && arguments.last == "Enter"
            if state.enterFails, state.pasted.count >= delivery {
                return (CommandResult(exitCode: 1, stdout: ""), reached)
            }
        case "capture-pane":
            let input = state.collapsed ? "[Pasted text #1]" : state.input
            output = ScriptedPane.render("> " + input + "▌")
            reached = checkpoint == .prePaste && !state.buffers.isEmpty
        default: break
        }
        return (CommandResult(exitCode: 0, stdout: output), reached)
    }

    private func fillBuffer(_ arguments: [String], state: inout State) {
        guard let flag = arguments.firstIndex(of: "-b") else { return }
        let name = arguments[flag + 1]
        state.buffers[name] = (arguments.contains("-a") ? state.buffers[name] ?? "" : "") + (arguments.last ?? "")
    }

    private func press(_ arguments: [String], state: inout State) {
        switch arguments.last {
        case "Enter":
            state.entered += 1
            state.input = state.retry && state.pasted.count >= delivery ? state.input + "\n  " : ""
        default: break
        }
    }
}

struct TmuxAuthorityRig {
    static let target = "tmux:codex"
    static let binding = "$2@1758230001/%2:502"
    let runner: AuthorityTmuxRunner
    let adapter: TmuxAdapter
    let host: HailHost
    let authority: DeliveryAuthority
    let log: EvidenceLog

    static func make(
        _ checkpoint: AuthorityTmuxRunner.Checkpoint = .none, input: String = "", delivery: Int = 1
    ) async throws -> Self {
        let runner = AuthorityTmuxRunner(checkpoint, input: input, delivery: delivery)
        let log = EvidenceLog()
        let adapter = TmuxAdapter(
            runner: runner, socket: "hail-authority-\(UUID().uuidString)", chunkSize: 4, pollInterval: nil,
            submitTiming: TmuxSubmitTiming(
                settleFloor: .milliseconds(1), pollInterval: .milliseconds(1), quiet: .milliseconds(2),
                settleLimit: .milliseconds(10), confirmLimit: .milliseconds(10)
            ), submitClock: ManualSubmitClock().clock, evidenceObserver: { log.append($0) }
        )
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow(target, binding: binding, tier: .open)
        let host = try HailHost(
            registry: registry, sanitizing: .init(newlines: .split), store: InMemoryPolicyStore(policy)
        )
        return Self(runner: runner, adapter: adapter, host: host,
                    authority: host.targetPolicy.snapshot(for: target).deliveryAuthority, log: log)
    }

    func send() async throws {
        // Exercise the Adapter witness, not a statically resolved convenience overload.
        let adapter: any Adapter = adapter
        try await adapter.deliver("synthetic input", to: "codex", binding: Self.binding, authority: authority)
    }

    func retire() async throws {
        _ = try await host.setTier(.open, for: Self.target)
        #expect(throws: HostError.denied(.notAllowed(Self.target))) { try authority.requireCurrent() }
    }
}
