import Foundation
import Synchronization

/// Every tmux session on one server is a target (#11). Delivery goes through `send-keys -l --`, so text is
/// never interpreted as key names. The binding is session id, creation time, and the active pane's pid,
/// re-verified by exact name immediately before the first send and again before the Enter, and every
/// send addresses the pane id itself, so neither a reused name nor an active-pane switch can redirect
/// text (threat model B3).
/// Sanitization (single line, no control characters) is #44's layer above this; the adapter only refuses
/// line breaks, which `send-keys` would turn into extra Enter presses.
public actor TmuxAdapter: Adapter {
    public static let defaultChunkSize = 400
    /// Use a printable separator: tmux can replace tabs with underscores under launchd. The first four
    /// fields cannot contain `|`; the session name is last and may contain any additional separators.
    static let listFormat = "#{session_id}|#{session_created}|#{pane_id}|#{pane_pid}|#{session_name}"

    public nonisolated let kind = "tmux"
    private let runner: any CommandRunner
    private let tmuxPath: String
    private let socket: String?
    private let chunkSize: Int
    private let pollInterval: Duration?
    /// Deliveries run one at a time: actor reentrancy at each await would otherwise let two deliveries
    /// interleave their chunks and Enters into one concatenated command.
    private var lastDelivery: Task<Void, Never>?

    /// - Parameters:
    ///   - tmux: executable path. A LaunchAgent's PATH lacks Homebrew, so #10's config passes the full path.
    ///   - socket: `tmux -L <socket>` when set; the default server otherwise.
    ///   - chunkSize: characters per `send-keys`; paste handling truncated ~1,400-character sends in practice.
    ///   - pollInterval: how often `events` re-lists sessions; `nil` disables polling (an empty stream).
    public init(
        runner: any CommandRunner, tmux: String = "tmux", socket: String? = nil,
        chunkSize: Int = defaultChunkSize, pollInterval: Duration? = .seconds(3)
    ) {
        self.runner = runner
        self.tmuxPath = tmux
        self.socket = socket
        self.chunkSize = max(1, chunkSize)
        self.pollInterval = pollInterval
    }

    /// A fresh polling stream per access; nothing runs until a caller asks, and the poll task ends when the
    /// consumer stops iterating. Buffering is lossless: a consumer that lags sees every event in order, and
    /// the only way the buffer grows without bound is a holder that never iterates, which is a daemon bug
    /// rather than a condition to mask by dropping events.
    public nonisolated var events: AsyncStream<TargetEvent> {
        Self.pollingStream(
            runner: runner, tmux: tmuxPath, baseArguments: Self.baseArguments(socket: socket), interval: pollInterval
        )
    }

    public func listTargets() async throws -> [AdapterTarget] {
        try await sessions().map { AdapterTarget(name: $0.name, binding: $0.binding) }
    }

    public func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard !text.contains(where: \.isNewline) else {
            throw AdapterError.deliveryFailed("text contains a line break")
        }
        // A bare Enter would accept whatever prompt is pending in an agent's pane.
        guard text.contains(where: { !$0.isWhitespace }) else { throw AdapterError.deliveryFailed("empty text") }
        let previous = lastDelivery
        let abandoned = DeliveryAbandonment()
        let delivery = Task<Void, any Error> {
            await previous?.value
            try await self.performDelivery(text, to: target, binding: binding, abandoned: abandoned)
        }
        lastDelivery = Task { _ = await delivery.result }
        // The caller's cancellation (a timed-out socket submission, #200) abandons a delivery that has not yet
        // committed to its Enter: no further chunk and no Enter. One that already committed completes, and its
        // outcome is returned to a caller that may no longer be listening.
        try await withTaskCancellationHandler { try await delivery.value } onCancel: { abandoned.abandon() }
    }

    public func escape(_ target: String, binding: String?) async throws {
        let session = try await verified(target, binding: binding)
        try await tmux(["send-keys", "-t", session.paneID, "Escape"], failure: AdapterError.deliveryFailed)
    }

    private func performDelivery(
        _ text: String, to target: String, binding: String?, abandoned: DeliveryAbandonment
    ) async throws {
        // A delivery abandoned while queued behind another types nothing.
        try abandoned.check()
        let session = try await verified(target, binding: binding)
        for chunk in Self.chunks(text, size: chunkSize) {
            try abandoned.check()
            let send = ["send-keys", "-t", session.paneID, "-l", "--", chunk]
            try await tmux(send, failure: AdapterError.deliveryFailed)
        }
        // The Enter is what runs the text; the identity is checked once more right before it.
        _ = try await verified(target, binding: session.binding)
        // The commit point: abandonment and commitment are one atomic decision, so either nothing is
        // submitted (typed text, if any, stays unsubmitted in the input line; there is no rollback) or the
        // Enter is sent whatever the caller does afterwards.
        guard abandoned.commit() else { throw CancellationError() }
        try await tmux(["send-keys", "-t", session.paneID, "Enter"], failure: AdapterError.deliveryFailed)
    }

    /// The session behind `name` now, refused unless its binding is the one the caller holds.
    private func verified(_ name: String, binding: String?) async throws -> Session {
        let session = try await session(named: name)
        if let binding, binding != session.binding { throw AdapterError.rebound(name) }
        return session
    }

    public func capture(_ target: String) async throws -> String {
        let id = try await session(named: target).paneID
        let arguments = ["capture-pane", "-p", "-J", "-t", id, "-S", "-200"]
        let result = try await tmux(arguments, failure: AdapterError.captureFailed)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessions() async throws -> [Session] {
        try await Self.listSessions(runner: runner, tmux: tmuxPath, baseArguments: Self.baseArguments(socket: socket))
    }

    private func session(named name: String) async throws -> Session {
        guard let session = try await sessions().first(where: { $0.name == name }) else {
            throw AdapterError.unknownTarget(name)
        }
        return session
    }

    @discardableResult
    private func tmux(_ arguments: [String], failure: (String) -> AdapterError) async throws -> CommandResult {
        let result = try await runner.run(tmuxPath, Self.baseArguments(socket: socket) + arguments)
        guard result.exitCode == 0 else { throw failure(result.errorText) }
        return result
    }
}

/// One delivery's submit decision: the caller's cancellation and the Enter race for it under one lock.
final class DeliveryAbandonment: Sendable {
    private enum State { case pending, abandoned, committed }
    private let state = Mutex(State.pending)
    /// Abandons a delivery that has not committed; a committed one is unaffected.
    func abandon() { state.withLock { if $0 == .pending { $0 = .abandoned } } }
    func check() throws { if state.withLock({ $0 == .abandoned }) { throw CancellationError() } }
    /// True exactly once, for a delivery not yet abandoned; from then on abandonment cannot stop the Enter.
    func commit() -> Bool {
        state.withLock {
            guard $0 == .pending else { return false }
            $0 = .committed
            return true
        }
    }
}
