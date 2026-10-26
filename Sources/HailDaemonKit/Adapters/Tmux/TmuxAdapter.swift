// The delivery sequence and each of its refusals stay together in one file; the evidence ledger is its own (#894).
// swiftlint:disable file_length
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
    /// Deliveries run one at a time, or reentrancy at each await would interleave two of them into one command.
    private var lastDelivery: Task<Void, Never>?
    /// Panes holding pasted text from a delivery that never reached a known submit (abandoned or failed after
    /// the paste). No later delivery types into them. Cleared only by a new adapter (a `haild` restart).
    private var tainted: Set<String> = []
    /// The tail of the last text pasted into each pane, so a later delivery can see it still pending (#304).
    var lastTails: [String: PayloadTail] = [:]
    /// haild's own last insert per pane, and who hears each submit outcome and pending-input refusal (#894).
    var evidence: TmuxEvidenceLedger

    /// - Parameters:
    ///   - tmux: executable path. A LaunchAgent's PATH lacks Homebrew, so #10's config passes the full path.
    ///   - socket: `tmux -L <socket>` when set; the default server otherwise.
    ///   - chunkSize: characters per `set-buffer` call while the paste buffer is filled.
    ///   - pollInterval: how often `events` re-lists sessions; `nil` disables polling (an empty stream).
    ///   - submitTiming, submitObserver: the bounded waits around the Enter, and who hears each outcome (#83, #304).
    ///   - evidenceObserver: who hears each submit and each pending-input refusal, as tokens only (#894).
    public init(
        runner: any CommandRunner, tmux: String = "tmux", socket: String? = nil,
        chunkSize: Int = defaultChunkSize, pollInterval: Duration? = .seconds(3),
        submitTiming: TmuxSubmitTiming = .standard, submitObserver: (@Sendable (TmuxSubmitOutcome) -> Void)? = nil,
        evidenceObserver: (@Sendable (TmuxDeliveryEvidence) -> Void)? = nil
    ) {
        self.runner = runner
        self.tmuxPath = tmux
        self.socket = socket
        self.chunkSize = max(1, chunkSize)
        self.pollInterval = pollInterval
        self.submitTiming = submitTiming
        self.evidence = TmuxEvidenceLedger(submitObserver: submitObserver, observer: evidenceObserver)
    }

    /// A fresh polling stream per access, idle until iterated and ended when the consumer stops. Buffering is
    /// lossless; only a holder that never iterates grows it without bound, a daemon bug not masked by dropping.
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
        // The caller's cancellation (a timed-out socket submission, #200) abandons a delivery not yet committed to
        // its Enter (no paste or Enter follows); a committed one completes for a caller that may have left.
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
            // Named, not generic (#894); clearing the pane by hand still needs a haild restart to lift the taint.
            evidence.inputPending(.tainted, in: session.paneID, seen: nil, own: lastTails[session.paneID])
            throw AdapterError.inputPending(reason: .tainted)
        }
        let tail = PayloadTail(text)
        let pending = [tail, lastTails[session.paneID]]
        let baseline = try await clearedBaseline(session, target: target, pending: pending, abandoned: abandoned)
        var typed = false
        do {
            let fresh = try await paste(text, into: session, target: target, abandoned: abandoned) {
                typed = true
                lastTails[session.paneID] = tail
                evidence.pasted(text, into: session.paneID)
            }
            let observe: TmuxSubmitProbe.Observe = { await self.observePane(session.paneID) }
            let acceptance = await TmuxSubmitProbe.acceptance(
                submitTiming, baseline: fresh ?? baseline, tail: tail, observe: observe
            )
            // The Enter is what runs the text; the identity is checked once more right before it.
            _ = try await verified(target, binding: session.binding)
            // The commit point: nothing is submitted (pasted text stays, no rollback), or the Enter is sent regardless.
            guard abandoned.commit() else { throw CancellationError() }
            try await submit(session, target: target, tail: tail, acceptance: acceptance)
        } catch AdapterError.deliveryFailed(let message) where !typed && message == Self.appearedRefusal(target) {
            // Text appeared before the paste, so nothing was typed and the pane stays untainted; named (#894).
            throw AdapterError.inputPending(reason: .appeared)
        } catch {
            // Abandonment before the paste leaves the pane clean; pasted and not known submitted taints it.
            if typed { tainted.insert(session.paneID) }
            throw error
        }
    }

    /// The screen before any text (#304). Text pending at the cursor (this tail, the last one's, or a placeholder) is
    /// never appended to: held text gets up to `clearLimit` to leave (two clear looks in a row), a tail wrapped to a
    /// column-0 cursor is refused at once; refusals are untainted, and an abandoned delivery leaves as cancelled.
    private func clearedBaseline(
        _ session: Session, target: String, pending: [PayloadTail?], abandoned: DeliveryAbandonment
    ) async throws -> PaneObservation? {
        let baseline = await observePane(session.paneID)
        guard let seen = baseline, let index = await pendingIndex(seen, pending, in: session.paneID) else {
            return baseline
        }
        var (stale, wait) = (pending[index], submitTiming)
        wait.confirmLimit = submitTiming.clearLimit
        let observe: TmuxSubmitProbe.Observe = {
            (try? abandoned.check()) == nil ? nil : await self.observePane(session.paneID)
        }
        let left: TmuxSubmitProbe.Reaction = seen.input(stale) != .holding ? .ambiguous
            : await TmuxSubmitProbe.reaction(wait, tail: stale, before: seen, wasHolding: true, observe: observe)
        try abandoned.check()
        guard left == .submitted else {
            evidence.inputPending(.staleInput, in: session.paneID, seen: seen, own: pending[1])
            throw AdapterError.inputPending(reason: .staleInput)
        }
        return await observePane(session.paneID)
    }

    /// Submits and records what was observed, a failure included.
    private func submit(
        _ session: Session, target: String, tail: PayloadTail, acceptance: TmuxSubmitProbe.Acceptance
    ) async throws {
        do {
            let outcome = try await attemptSubmit(session, target: target, tail: tail, acceptance: acceptance)
            evidence.submitted(outcome, in: session.paneID, target: target)
        } catch {
            evidence.submitted(.failed, in: session.paneID, target: target)
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

extension TmuxAdapter {
    /// The paste step's own refusal for text that appeared while its buffer filled, word for word as
    /// `TmuxAdapter+Paste.swift` throws it; `performDelivery` names it `inputPending(.appeared)` (#894). Tests pin
    /// the pair, so a reworded refusal there fails them rather than falling back to a generic delivery failure.
    static func appearedRefusal(_ target: String) -> String {
        "unsubmitted text appeared in the input of pane \(target)"
    }
}
