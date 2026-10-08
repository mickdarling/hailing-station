import Foundation

/// Every tmux session on one server is a target (#11). Text reaches the pane as one tmux paste (#304): it is
/// assembled in a uniquely named buffer by argv (never interpreted as key names) and pasted with `paste-buffer
/// -p`, bracketed when the target asked for it, so a target reads it as one piece however late its event loop
/// runs. The binding is session id, creation time, and the active pane's pid, re-verified by exact name before
/// the paste and again before the Enter, and every command addresses the pane id itself, so neither a reused
/// name nor an active-pane switch can redirect text (threat model B3).
/// Sanitization (single line, no control characters, so no paste-end marker) is #44's layer above this; the
/// adapter only refuses line breaks, which a paste would turn into extra Enter presses.
public actor TmuxAdapter: Adapter {
    public static let defaultChunkSize = 400
    /// Use a printable separator: tmux can replace tabs with underscores under launchd. The first four
    /// fields cannot contain `|`; the session name is last and may contain any additional separators.
    static let listFormat = "#{session_id}|#{session_created}|#{pane_id}|#{pane_pid}|#{session_name}"

    public nonisolated let kind = "tmux"
    let runner: any CommandRunner
    let tmuxPath: String
    let socket: String?
    let chunkSize: Int
    private let pollInterval: Duration?
    let submitTiming: TmuxSubmitTiming
    private let submitObserver: (@Sendable (TmuxSubmitOutcome) -> Void)?
    /// Deliveries run one at a time, or reentrancy at each await would interleave two of them into one command.
    private var lastDelivery: Task<Void, Never>?
    /// Panes holding pasted text from a delivery that never reached a known submit (abandoned or failed after
    /// the paste). No later delivery types into them. Cleared only by a new adapter (a `haild` restart).
    private var tainted: Set<String> = []
    /// The tail of the last text pasted into each pane, so a later delivery can see it still pending (#304).
    private var lastTails: [String: PayloadTail] = [:]

    /// - Parameters:
    ///   - tmux: executable path. A LaunchAgent's PATH lacks Homebrew, so #10's config passes the full path.
    ///   - socket: `tmux -L <socket>` when set; the default server otherwise.
    ///   - chunkSize: characters per `set-buffer` call while the paste buffer is filled.
    ///   - pollInterval: how often `events` re-lists sessions; `nil` disables polling (an empty stream).
    ///   - submitTiming, submitObserver: the bounded waits around the Enter, and who hears each outcome (#83, #304).
    public init(
        runner: any CommandRunner, tmux: String = "tmux", socket: String? = nil,
        chunkSize: Int = defaultChunkSize, pollInterval: Duration? = .seconds(3),
        submitTiming: TmuxSubmitTiming = .standard, submitObserver: (@Sendable (TmuxSubmitOutcome) -> Void)? = nil
    ) {
        self.runner = runner
        self.tmuxPath = tmux
        self.socket = socket
        self.chunkSize = max(1, chunkSize)
        self.pollInterval = pollInterval
        self.submitTiming = submitTiming
        self.submitObserver = submitObserver
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
        // A delivery abandoned while queued pastes nothing.
        try abandoned.check()
        let session = try await verified(target, binding: binding)
        guard !tainted.contains(session.paneID) else {
            throw AdapterError.deliveryFailed(
                "unsubmitted text left in pane \(target); clear it and restart haild before delivering again"
            )
        }
        let tail = PayloadTail(text)
        // The screen before any text, which the Enter waits for a change from. Text pending at the cursor (this
        // tail, the last one's, or a placeholder; nil checks only placeholders) is never appended to: a frozen
        // target may still submit it, so it gets up to `clearLimit` to leave (two clear looks in a row, #304).
        // Still there, the delivery is refused untainted, since nothing was pasted.
        var baseline = await observePane(session.paneID)
        let pending = [tail, lastTails[session.paneID]]
        if let seen = baseline, let stale = pending.first(where: { seen.input($0) == .holding }) {
            var wait = submitTiming
            wait.confirmLimit = submitTiming.clearLimit
            let observe: TmuxSubmitProbe.Observe = { await self.observePane(session.paneID) }
            let left = await TmuxSubmitProbe.reaction(
                wait, tail: stale, before: seen, wasHolding: true, observe: observe
            )
            guard left == .submitted else {
                throw AdapterError.deliveryFailed("unsubmitted text is already in the input of pane \(target)")
            }
            baseline = await observePane(session.paneID)
        }
        var typed = false
        do {
            try await paste(text, into: session.paneID, abandoned: abandoned) {
                typed = true
                lastTails[session.paneID] = tail
            }
            let observe: TmuxSubmitProbe.Observe = { await self.observePane(session.paneID) }
            let acceptance = await TmuxSubmitProbe.acceptance(
                submitTiming, baseline: baseline, tail: tail, observe: observe
            )
            // The Enter is what runs the text; the identity is checked once more right before it.
            _ = try await verified(target, binding: session.binding)
            // The commit point, one atomic decision: either nothing is submitted (pasted text stays unsubmitted
            // in the input; no rollback) or the Enter is sent whatever the caller does afterwards.
            guard abandoned.commit() else { throw CancellationError() }
            try await submit(session, target: target, tail: tail, acceptance: acceptance)
        } catch {
            // Abandonment before the paste leaves the pane clean; anything pasted and not known to be submitted
            // (a failed Enter included) taints it.
            if typed { tainted.insert(session.paneID) }
            throw error
        }
    }

    /// Submits and records what was observed, a failure included.
    private func submit(
        _ session: Session, target: String, tail: PayloadTail, acceptance: TmuxSubmitProbe.Acceptance
    ) async throws {
        do {
            try await attemptSubmit(session, target: target, tail: tail, acceptance: acceptance)
                .record(target: target, observer: submitObserver)
        } catch {
            TmuxSubmitOutcome.failed.record(target: target, observer: submitObserver)
            throw error
        }
    }

    /// tmux reads an argument that ends in `;` as a command separator and drops that `;` (a lone `;` is then "no
    /// data specified"); a `\` right before it escapes it, and is dropped instead. So one `\` goes before a trailing
    /// `;`, which tmux removes again: `x;` is sent as `x\;`, and `x\;` as `x\\;` (#307 item 1).
    static func bufferArgument(_ chunk: String) -> String {
        guard chunk.hasSuffix(";") else { return chunk }
        return chunk.dropLast() + "\\;"
    }

    /// The session behind `name` now, refused unless its binding is the one the caller holds.
    func verified(_ name: String, binding: String?) async throws -> Session {
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
    func tmux(_ arguments: [String], failure: (String) -> AdapterError) async throws -> CommandResult {
        let result = try await runner.run(tmuxPath, Self.baseArguments(socket: socket) + arguments)
        guard result.exitCode == 0 else { throw failure(result.errorText) }
        return result
    }
}
