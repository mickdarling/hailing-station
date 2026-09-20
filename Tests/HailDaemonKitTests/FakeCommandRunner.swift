import Synchronization
@testable import HailDaemonKit

/// Records every argv and answers from a scripted responder (#11 tests). No process is ever spawned.
actor FakeCommandRunner: CommandRunner {
    typealias Responder = @Sendable ([String]) -> CommandResult

    private(set) var calls: [[String]] = []
    private let responder: Responder
    private let delay: Duration?

    init(delay: Duration? = nil, _ responder: @escaping Responder) {
        self.responder = responder
        self.delay = delay
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append([executable] + arguments)
        if let delay { try await Task.sleep(for: delay) }
        return responder(arguments)
    }

    /// The listing tmux would print for `sessions`, everything else succeeds silently.
    static func serving(_ sessions: SessionListing, delay: Duration? = nil) -> FakeCommandRunner {
        FakeCommandRunner(delay: delay) { arguments in
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

/// Mutable `list-sessions` output shared with a running fake; a class because `Mutex` is noncopyable.
final class SessionListing: Sendable {
    private let storage: Mutex<String>

    init(_ listing: String) {
        storage = Mutex(listing)
    }

    func get() -> String { storage.withLock { $0 } }
    func set(_ listing: String) { storage.withLock { $0 = listing } }
}

let twoSessions = "$1\t1758230000\t%1\t501\tclaude-hail\n$2\t1758230001\t%2\t502\tcodex\n"
