import Synchronization
@testable import HailDaemonKit

/// Records every argv and answers from a scripted responder (#11 tests). No process is ever spawned.
actor FakeCommandRunner: CommandRunner {
    typealias Responder = @Sendable ([String]) -> CommandResult

    private(set) var calls: [[String]] = []
    private let responder: Responder
    private let delay: Duration?
    private let gate: TypingGate?

    init(delay: Duration? = nil, gate: TypingGate? = nil, _ responder: @escaping Responder) {
        self.responder = responder
        self.delay = delay
        self.gate = gate
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append([executable] + arguments)
        if let delay { try await Task.sleep(for: delay) }
        await gate?.pass(arguments)
        return responder(arguments)
    }

    /// The listing tmux would print for `sessions`, everything else succeeds silently.
    static func serving(
        _ sessions: SessionListing, delay: Duration? = nil, gate: TypingGate? = nil
    ) -> FakeCommandRunner {
        FakeCommandRunner(delay: delay, gate: gate) { arguments in
            guard arguments.contains("list-sessions") else { return CommandResult(exitCode: 0, stdout: "") }
            let listing = sessions.get()
            guard !listing.isEmpty else {
                let missing = "error connecting to /private/tmp/tmux-501/default (No such file or directory)\n"
                return CommandResult(exitCode: 1, stdout: "", stderr: missing)
            }
            return CommandResult(exitCode: 0, stdout: listing)
        }
    }
}

/// Lets the first `allowed` `send-keys` calls through, then parks the rest until `open()` (#208). A test can hold
/// a delivery mid-typing by structure instead of racing a wall-clock deadline against runner speed.
final class TypingGate: Sendable {
    private struct State {
        var seen = 0
        var isOpen = false
        var parked: [CheckedContinuation<Void, Never>] = []
    }
    private let allowed: Int
    private let state = Mutex(State())

    init(allowing allowed: Int) {
        self.allowed = allowed
    }

    func pass(_ arguments: [String]) async {
        guard arguments.contains("send-keys") else { return }
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state -> Bool in
                state.seen += 1
                guard !state.isOpen, state.seen > allowed else { return true }
                state.parked.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let parked = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.parked = [] }
            return state.parked
        }
        parked.forEach { $0.resume() }
    }
}

/// Mutable `list-sessions` output shared with a running fake; a class because `Mutex` is noncopyable.
final class SessionListing: Sendable {
    private let storage: Mutex<String>

    init(_ listing: String) {
        storage = Mutex(listing)
    }

    func get() -> String { storage.withLock { $0 } }
    func set(_ listing: String) { storage.withLock { $0 = listing } }
}

let twoSessions = "$1|1758230000|%1|501|claude-hail\n$2|1758230001|%2|502|codex\n"
