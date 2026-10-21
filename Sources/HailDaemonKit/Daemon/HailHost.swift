// The host's policy transaction helpers intentionally remain beside the actor state they protect.
// swiftlint:disable file_length
import Foundation
import Synchronization
public import HailProtocol
public enum HostError: Error, Equatable, Sendable {
    case unknownTarget(String)
    case adapterUnavailable(kind: String, reason: String)
    case refused(SanitizeError)
    case denied(Denial)
    case partial(delivered: [String], reason: String)
    case policyUnavailable(String)
}
final class ObservationCleanup: Sendable {
    private let lease: Mutex<ProviderObservation?>
    private let stopping = Mutex(false)
    init(_ lease: ProviderObservation) { self.lease = Mutex(lease) }
    var isStopping: Bool { stopping.withLock { $0 } }
    func cancel(stopping: Bool = false) {
        if stopping { self.stopping.withLock { $0 = true } }
        lease.withLock { value in let old = value; value = nil; return old }?.cancel()
    }
}
/// Host composition root (#10): registry, policy (#41), and a sanitised path re-evaluated before every line.
public actor HailHost {
    public static let confirmationWindow: Duration = .seconds(120)
    /// Read-backs outstanding at once; past this the oldest is dropped, so asking is never a way to grow memory.
    public static let pendingLimit = 64
    /// The whole-prompt cap for a local RightyO request (#183, #200): the direct `haild rightyo` host and the
    /// daemon's local-socket dispatch path both sanitise under this one policy. Phone text frames never do.
    public static let localPromptSanitizing = SanitizePolicy(maxCharacters: 1_200_000, maxUTF8Bytes: 1_200_000)
    /// Bound to true only by `HostSession.dispatch` (the owner-only local socket, #188) for its own handoff,
    /// so that send alone sanitises under `dispatchSanitizing`. Every other caller, phone frames included,
    /// keeps the host's `sanitizing` policy. Only the cap changes: newline rule, guard, tier, lockdown,
    /// binding and rate limit run exactly as on any other send.
    @TaskLocal static var localDispatchIngress = false
    /// The line cap for a phone request that carries a paste (#608): the whole framed line from `PastedContent`.
    public static let pastedSanitizing = PastedContent.lineCap
    /// Bound to true only by `HostSession` for a phone request whose text `PastedContent` framed, so that send alone
    /// sanitises under `pasteSanitizing`. As with a dispatch, only the cap changes.
    @TaskLocal static var pastedIngress = false
    public let registry: Registry
    private let sanitizing: SanitizePolicy
    private let dispatchSanitizing: SanitizePolicy
    private let pasteSanitizing: SanitizePolicy
    private let store: any PolicyStore
    private let clock = ContinuousClock()
    private let window: Duration
    private var policy: Policy
    private var policyRevision = UUID()
    private let replyPublicationAuthority = ReplyPublicationAuthority()
    private var evaluator: PolicyEvaluator
    private var limiter = RateLimiter()
    private var pending: [String: ContinuousClock.Instant] = [:]
    var lockdown = LockdownState()
    public private(set) var policyFailure: String?
    public init(
        registry: Registry, sanitizing: SanitizePolicy = SanitizePolicy(), store: any PolicyStore,
        confirmationWindow: Duration = HailHost.confirmationWindow
    ) throws {
        self.registry = registry
        self.sanitizing = sanitizing
        // The host's own newline rule stands; a dispatch or a paste only gets its own length caps.
        dispatchSanitizing = sanitizing.widened(to: Self.localPromptSanitizing)
        pasteSanitizing = sanitizing.widened(to: Self.pastedSanitizing)
        self.store = store
        window = confirmationWindow
        var loaded = Policy()
        do {
            loaded = try store.load()
        } catch {
            policyFailure = "\(error)"
            loaded = Policy()
        }
        policy = loaded
        evaluator = try PolicyEvaluator(policy: loaded)
    }
    /// Every adapter's targets, merged and sorted (#10 item 2).
    public func targets() async throws -> [TargetInfo] { try await registry.targets() }
    /// Kinds that failed to list on the most recent `targets()` call, with the reason.
    public func listingFailures() async -> [String: String] { await registry.lastFailures }
    public var currentPolicy: Policy { policy }
    public nonisolated var policySummary: String { store.summary }
    /// In-memory policy only, not a registry/binding lease or recipient grant. No suspension occurs
    /// between this coherent actor-state check and issuance; later publication must execute under it.
    package func replyPublicationPermit(for binding: ProviderSessionBinding) -> ReplyPublicationPermit? {
        guard policyFailure == nil, !lockdown.isOn,
              let allowed = policy.targets[binding.targetID], allowed.binding == binding.sessionID,
              allowed.tier != .locked else { return nil }
        return replyPublicationAuthority.issuePermit()
    }
    /// Sanitises `text`, asks the policy, and delivers line by line to `id`. A `needsConfirmation` outcome
    /// carries the read-back; send the same text again with its `hash` as `confirmedHash` to deliver.
    @discardableResult
    public func send(
        _ text: String, to id: String, from device: String = "keyboard", confirmedHash: String? = nil,
        expectedBinding: String? = nil
    ) async throws -> SendOutcome {
        try await dispatch(text, request: DispatchRequest(
            target: id, device: device, confirmedHash: confirmedHash, expectedBinding: expectedBinding, turn: nil
        ))
    }

    /// Explicit structured dispatch; capabilities and context do not bypass any delivery policy.
    public func send(
        _ text: String, context: ProviderTurnContext, from device: String = "keyboard", confirmedHash: String? = nil
    ) async throws -> SendOutcome {
        try await dispatch(text, request: DispatchRequest(
            target: context.binding.targetID, device: device, confirmedHash: confirmedHash,
            expectedBinding: context.binding.sessionID, turn: context
        ))
    }

    private struct DispatchRequest {
        let target: String
        let device: String
        let confirmedHash: String?
        let expectedBinding: String?
        let turn: ProviderTurnContext?
    }

    private func dispatch(_ text: String, request dispatch: DispatchRequest) async throws -> SendOutcome {
        let id = dispatch.target
        try requireSendPreflight()
        var lines = try sanitizedLines(text)
        let listed = try await dispatchListing(dispatch, lineCount: lines.count)
        // Commit the first dispatch attempt after policy I/O, before consuming one-shot confirmation.
        // No further cancellation observation occurs before its adapter handoff; later lines may stop.
        try Task.checkCancellation()
        let guardLines = try screenPaste(&lines)
        var request = DeliveryRequest(
            target: id, binding: listed.binding, lines: lines, device: dispatch.device, guardLines: guardLines
        )
        // No suspension from here to the first evaluation: the consumed token cannot go stale in between.
        let confirmed = consume(dispatch.confirmedHash, for: request)
        let confirmedRevision = policyRevision
        var delivered: [String] = []
        for (index, line) in lines.enumerated() {
            try requireUncancelledLaterLine(delivered, index: index)
            request.lines = Array(lines[index...])
            var decision = evaluator.evaluate(request, lockdown: lockdown.isOn, limiter: limiter, now: clock.now)
            // A confirmation turns a read-back into delivery and nothing else: every denial stands.
            if confirmed, confirmedRevision == policyRevision, case .confirm = decision { decision = .deliver }
            switch decision {
            case .deliver:
                break
            case .confirm(let reason, let hits):
                guard delivered.isEmpty else { throw HostError.partial(delivered: delivered, reason: reason) }
                return .needsConfirmation(issue(request, reason: reason, guardHits: hits))
            case .denied(let denial):
                guard delivered.isEmpty else { throw HostError.partial(delivered: delivered, reason: "\(denial)") }
                throw HostError.denied(denial)
            }
            // Recorded before the suspension, so concurrent sends cannot all pass admission on one history;
            // an attempt the adapter then refuses still spent its slot (fail closed).
            limiter.record(request, at: clock.now)
            do {
                try await registry.deliver(line, to: id, binding: listed.binding, context: dispatch.turn)
            } catch {
                throw preservingPartial(error, delivered: delivered)
            }
            delivered.append(line)
        }
        return .delivered(delivered)
    }
    /// Sends one literal Escape to an allowed, still-bound target. Escape is a safety control rather
    /// than content delivery, so an explicit tap remains available at the confirm tier; locked targets
    /// and host lockdown still refuse it.
    public func escape(_ id: String) async throws {
        try requireSendPreflight()
        let listed = try await listed(id)
        guard let allowed = policy.targets[id] else { throw HostError.denied(.notAllowed(id)) }
        guard let binding = listed.binding, !binding.isEmpty else { throw HostError.denied(.unbound(id)) }
        guard allowed.binding == binding else { throw HostError.denied(.rebound(id)) }
        guard allowed.tier != .locked else { throw HostError.denied(.locked(id)) }
        try await registry.escape(id, binding: binding)
    }
    /// Drops a read-back the user declined, so "cancel" ends it now rather than at the window (#41 item 2).
    @discardableResult
    public func cancel(_ hash: String) -> Bool { pending.removeValue(forKey: hash) != nil }
    /// Allows `id` at the binding its adapter reports now (#41 item 1); an unlisted or unbound target cannot
    /// be allowed. Saved before it takes effect. Re-allowing re-pins the binding (the answer to a rebound).
    public func allow(_ id: String, tier: Tier = .confirm, capture: Bool = false) async throws -> TargetPolicy {
        try requirePolicy()
        guard let binding = try await listed(id).binding else { throw HostError.denied(.unbound(id)) }
        try commit { try $0.allow(id, binding: binding, tier: tier, capture: capture) }
        return TargetPolicy(tier: tier, capture: capture, binding: binding)
    }
    /// Returns false when `id` was not allowed, so a CLI can say so; a deny of the unknown is not an error.
    public func deny(_ id: String) throws -> Bool {
        try requirePolicy()
        var wasAllowed = false
        try commit { policy in
            wasAllowed = policy.targets[id] != nil
            policy.deny(id)
        }
        return wasAllowed
    }
    public func setTier(_ tier: Tier, for id: String) throws -> Bool {
        try requirePolicy()
        var wasAllowed = false
        try commit { wasAllowed = $0.setTier(tier, for: id) }
        return wasAllowed
    }
}
extension HailHost {
    /// The policy as stored now, for a device's target list: a CLI `targets allow` (another process) is
    /// seen without a restart (#386). Nil when the stored policy cannot be trusted, so the list fails closed.
    public func refreshedPolicy() -> Policy? {
        do { try refreshPolicy() } catch { return nil }
        return policy
    }
    /// A trusted local scope. Consumer return always ends capture; no listener path calls this API.
    public func withObservedSession<Result: Sendable>(
        target: String, configuration: ProviderObservedSession.Configuration = .init(),
        operation: @escaping @Sendable (ProviderObservedSession) async throws -> Result
    ) async throws -> Result {
        guard case .contextual = configuration.input.deliveryMode else {
            throw ProviderObservedSessionError.legacyInputUnsupported
        }
        guard configuration.pollInterval > .zero, configuration.pollInterval <= .seconds(1),
              (1...ProviderEventLimits.maxBufferedEvents).contains(configuration.maxQueuedEvents),
              (1...4_194_304).contains(configuration.maxQueuedTextBytes) else {
            throw ProviderContractError.invalidCapacity
        }
        let (binding, lease) = try await openObservation(target, hostID: configuration.hostID)
        let cleanup = ObservationCleanup(lease)
        defer { cleanup.cancel() }
        let owner = try ProviderObservedSession(host: self, binding: binding, config: configuration, cleanup: cleanup)
        return try await withTaskCancellationHandler {
            try await owner.run(lease, operation: operation)
        } onCancel: { cleanup.cancel(stopping: true); Task { await owner.stop() } }
    }

    /// Host-local acquisition only. No caller-supplied session binding or cached capture grant.
    package func openObservation(
        _ id: String, hostID: String
    ) async throws -> (ProviderSessionBinding, ProviderObservation) {
        let target = try await captureListing(id)
        guard let sessionID = target.binding else { throw ProviderObservedSessionError.captureDenied }
        let binding = try ProviderSessionBinding(hostID: hostID, providerID: target.info.kind,
                                                targetID: id, sessionID: sessionID)
        let lease = try await registry.observe(binding)
        do {
            // Startup may suspend through revocation, cancellation or replacement.
            try await validateObservation(binding)
            return (binding, lease)
        } catch {
            lease.cancel()
            throw error
        }
    }

    package func validateObservation(_ binding: ProviderSessionBinding) async throws {
        let target = try await captureListing(binding.targetID)
        guard target.binding == binding.sessionID, target.info.kind == binding.providerID else {
            throw ProviderObservedSessionError.captureDenied
        }
    }

    private func captureListing(_ id: String) async throws -> Registry.Listed {
        try Task.checkCancellation()
        let target = try await listed(id)
        try refreshPolicy() // Unlike requirePolicy, every observation check reads current authority.
        try Task.checkCancellation()
        guard evaluator.mayCapture(target: id, binding: target.binding, lockdown: lockdown.isOn) else {
            throw ProviderObservedSessionError.captureDenied
        }
        return target
    }

    private func dispatchListing(_ request: DispatchRequest, lineCount: Int) async throws -> Registry.Listed {
        let listed = try await listed(request.target)
        try Task.checkCancellation()
        // Context and capability are checked before consuming confirmation or making an adapter attempt.
        try requireExpectedBinding(request.expectedBinding, for: listed)
        do {
            try await registry.requireInputDelivery(to: request.target, context: request.turn, lineCount: lineCount)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        // Every mode now checks registered shape across an actor hop: never carry cached authority through it.
        try refreshPolicy()
        return listed
    }

    private func requireUncancelledLaterLine(_ delivered: [String], index: Int) throws {
        guard index > 0, Task.isCancelled else { return }
        throw preservingPartial(CancellationError(), delivered: delivered)
    }

    private func preservingPartial(_ error: any Error, delivered: [String]) -> any Error {
        guard !delivered.isEmpty else { return error }
        if error is CancellationError {
            return HostError.partial(delivered: delivered, reason: "delivery cancelled")
        }
        if error is AdapterError { return HostError.partial(delivered: delivered, reason: "\(error)") }
        return HostError.partial(delivered: delivered, reason: "adapter delivery failed")
    }

    private func requireExpectedBinding(_ expectedBinding: String?, for listed: Registry.Listed) throws {
        if let expectedBinding, listed.binding != expectedBinding {
            throw HostError.denied(.rebound(listed.info.id))
        }
    }

    func requirePolicy() throws {
        if policyFailure != nil { try refreshPolicy() }
    }
    /// One store transaction: applied to what is stored now (not this process's snapshot), compiled
    /// before it is written, then adopted here; memory never holds a policy the store does not.
    private func commit(_ change: (inout Policy) throws -> Void) throws {
        let update: PolicyUpdate
        do {
            update = try store.update { policy in
                try change(&policy)
                _ = try PolicyEvaluator(policy: policy)
            }
        } catch {
            // Unknown transaction phases cannot prove continuous authority, even after a repair.
            // Retire reply permits conservatively; unchanged save failures keep generic confirmations.
            // Reconcile the current view and preserve the original transaction diagnostic.
            replyPublicationAuthority.invalidate()
            _ = try? refreshPolicy()
            throw error
        }
        let compiled: PolicyEvaluator
        do {
            compiled = try PolicyEvaluator(policy: update.policy)
        } catch {
            revokeAuthority()
            policyFailure = "\(error)"
            throw error
        }
        revokeAuthority()
        policy = update.policy
        evaluator = compiled
        if let failure = update.durabilityFailure { throw failure }
    }
    private func refreshPolicy() throws {
        do {
            let next = try store.load()
            let compiled = try PolicyEvaluator(policy: next)
            if next != policy { revokeAuthority() }
            policy = next
            evaluator = compiled
            policyFailure = nil
        } catch {
            revokeAuthority()
            policyFailure = "\(error)"
            throw HostError.policyUnavailable("\(error)")
        }
    }
    private func listed(_ id: String) async throws -> Registry.Listed {
        // One refresh gives both the target and its binding; two calls could straddle another refresh.
        let listing = try await registry.listing()
        guard let listed = listing.first(where: { $0.info.id == id }) else {
            let kind = String(id.prefix { $0 != ":" })
            if let reason = await registry.lastFailures[kind] {
                throw HostError.adapterUnavailable(kind: kind, reason: reason)
            }
            throw HostError.unknownTarget(id)
        }
        return listed
    }
    private func issue(_ request: DeliveryRequest, reason: String, guardHits: [String]) -> ReadBack {
        let now = clock.now
        pending = pending.filter { now - $0.value < window }
        let hash = request.confirmationHash
        pending[hash] = now
        while pending.count > Self.pendingLimit,
              let oldest = pending.min(by: { $0.value < $1.value }) {
            pending[oldest.key] = nil
        }
        return ReadBack(reason: reason, guardHits: guardHits, lines: request.lines, hash: hash)
    }
    /// True once for a hash this host issued, still within the window, for exactly this request; then it
    /// is forgotten. Anything else (unknown, expired, already used, other utterance) confirms nothing, and
    /// a hash presented with the wrong utterance is left for the right one: it cannot be burnt by a guess.
    private func consume(_ hash: String?, for request: DeliveryRequest) -> Bool {
        guard let hash, hash == request.confirmationHash,
              let issued = pending.removeValue(forKey: hash) else {
            return false
        }
        return clock.now - issued < window
    }
    /// The synchronized invalidation is the reply revocation boundary. A completed policy/lockdown
    /// mutation has invalidated every earlier permit; publication already inside its gate finishes first.
    func revokeAuthority() {
        replyPublicationAuthority.invalidate()
        (pending, policyRevision) = ([:], UUID())
    }

    /// The sanitized lines under this ingress's caps: a local dispatch's, a framed paste's, or the host's own.
    private func sanitizedLines(_ text: String) throws -> [String] {
        do {
            let policy = Self.localDispatchIngress ? dispatchSanitizing
                : Self.pastedIngress ? pasteSanitizing : sanitizing
            return try Sanitizer.sanitize(text, policy: policy)
        } catch let error as SanitizeError {
            throw HostError.refused(error)
        }
    }

    /// A framed paste (#608) is screened, not guarded: the guard reads only its spoken part (returned), and the paste
    /// body's matches become a validation flag on the block, under the policy this dispatch evaluates. Nil otherwise.
    private func screenPaste(_ lines: inout [String]) throws -> [String]? {
        guard Self.pastedIngress else { return nil }
        let screened = try PastedContent.screen(lines, with: evaluator, spoken: sanitizing)
        lines = screened.lines
        return screened.guardLines
    }
}

extension SanitizePolicy {
    /// This policy with the larger of its own and `cap`'s length caps; the newline rule and line count stay.
    func widened(to cap: SanitizePolicy) -> SanitizePolicy {
        var policy = self
        policy.maxCharacters = max(maxCharacters, cap.maxCharacters)
        policy.maxUTF8Bytes = max(maxUTF8Bytes, cap.maxUTF8Bytes)
        return policy
    }
}

/// Mick's decision (#608): a paste is screened, not guarded. Guarded words inside it do not stop delivery. They are
/// named in an advisory validation note right after the begin marker, outside the body, so the receiving session
/// knows what the paste contains. The spoken request is still guarded exactly as on its own. A paste is never
/// executed or treated as a command: it reaches only agent sessions, as shell-inert data inside its block.
extension PastedContent {
    struct Screened: Equatable {
        /// The framed line, with the validation note when anything matched.
        var lines: [String]
        /// The spoken request's sanitized lines, for the guard; empty for a paste on its own.
        var guardLines: [String]
    }

    /// Bytes every framed line keeps free for the validation note (#635 review), which `flagged` never exceeds.
    static let validationReserve = 160

    /// Splits the one sanitized framed line into its spoken part and paste body, guards the former's sanitized form
    /// under `spoken`, and screens the latter. Anything that does not parse as a frame from `frame` is refused.
    static func screen(_ lines: [String], with evaluator: PolicyEvaluator, spoken: SanitizePolicy) throws -> Screened {
        guard lines.count == 1, let parts = parts(of: lines[0]) else {
            throw HostError.refused(.hiddenCharacters("unreadable paste frame"))
        }
        let guardLines: [String]
        do {
            guardLines = parts.spoken.isEmpty ? [] : try Sanitizer.sanitize(parts.spoken, policy: spoken)
        } catch let error as SanitizeError {
            throw HostError.refused(error)
        }
        let body = parts.body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
        return Screened(lines: [flagged(lines[0], evaluator.pasteFlags(in: body))], guardLines: guardLines)
    }

    /// The decoded body and the spoken request of a line from `frame`. The body ends at the first end marker after
    /// the notice: it holds no raw `-`, so it cannot contain one.
    static func parts(of line: String) -> (spoken: String, body: String)? {
        guard let token = token(of: line), let start = line.range(of: " " + notice(token) + " "),
              let stop = line.range(of: " " + end(token), range: start.upperBound..<line.endIndex) else { return nil }
        let inner = String(line[start.upperBound..<stop.lowerBound])
        guard let body = try? JSONDecoder().decode(String.self, from: Data("\"\(inner)\"".utf8)) else { return nil }
        let rest = line[stop.upperBound...]
        if rest.isEmpty { return ("", body) }
        guard rest.hasPrefix(" \(request) ") else { return nil }
        return (String(rest.dropFirst(request.count + 2)), body)
    }

    /// The line with a validation note after the begin marker: `Validation: contains <rules>.` for rules that match,
    /// and `Validation: not fully checked: <rules>.` for rules that ran out of budget, so an unchecked paste never
    /// looks like a clean one (#635 review). Rule names are reduced to plain ASCII words of at most 40 characters, so
    /// a policy file cannot add markup or shell syntax, and the note stays within `validationReserve`. A clause whose
    /// names do not all fit ends in its own "and more"; a clause with no printable name still appears ("contains
    /// unnamed rules", "not fully checked"), so a matched or unchecked rule never leaves the paste looking clean.
    static func flagged(_ line: String, _ flags: (matched: [String], unchecked: [String])) -> String {
        guard !flags.matched.isEmpty || !flags.unchecked.isEmpty, let token = token(of: line) else { return line }
        // Plain words: allowed characters only, runs of spaces collapsed (a name left as spaces counts as unnamed).
        let plain = { (names: [String]) in
            names.map { name in
                let kept = String(name.unicodeScalars.filter(isPlainNameScalar).map(Character.init))
                return String(kept.split(separator: " ").joined(separator: " ").prefix(40))
                    .trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        let names = NoteNames(matched: plain(flags.matched), unchecked: plain(flags.unchecked),
                              matchedCount: flags.matched.count, uncheckedCount: flags.unchecked.count)
        var shown = names
        (shown.matched, shown.unchecked) = ([], [])
        for (index, name) in (names.matched + names.unchecked).enumerated() {
            var next = shown
            if index < names.matched.count { next.matched.append(name) } else { next.unchecked.append(name) }
            guard note(next, of: names).utf8.count <= validationReserve else { break }
            shown = next
        }
        let begin = begin(token)
        return begin + " " + note(shown, of: names) + line.dropFirst(begin.count + 1)
    }

    struct NoteNames {
        var matched: [String]
        var unchecked: [String]
        /// Every rule in the clause, named or not, so an unnamed one still counts towards "and more".
        var matchedCount: Int
        var uncheckedCount: Int
    }

    /// `shown` out of `all`: each clause lists its shown names and ends in its own "and more" when it holds any back.
    private static func note(_ shown: NoteNames, of all: NoteNames) -> String {
        func list(_ names: [String], named: [String], count: Int, none: String) -> String {
            guard !named.isEmpty else { return none }
            let shown = names.isEmpty ? "rules" : names.joined(separator: ", ")
            return shown + (names.count < count ? ", and more" : "")
        }
        var parts: [String] = []
        if all.matchedCount > 0 {
            parts.append("contains " + list(shown.matched, named: all.matched, count: all.matchedCount,
                                            none: "unnamed rules"))
        }
        if all.uncheckedCount > 0 {
            let label = parts.isEmpty ? "not fully checked" : "Not fully checked"
            let names = list(shown.unchecked, named: all.unchecked, count: all.uncheckedCount, none: "")
            parts.append(all.unchecked.isEmpty ? label : label + ": " + names)
        }
        return "Validation: " + parts.joined(separator: ". ") + ". "
    }

    /// The 16-hex token of a line that starts with a begin marker, else nil.
    static func token(of line: String) -> String? {
        let prefix = begin("")
        guard line.hasPrefix(prefix) else { return nil }
        let token = line.dropFirst(prefix.count).prefix(17)
        guard token.count == 17, token.last == " ", token.dropLast().allSatisfy(\.isHexDigit) else { return nil }
        return String(token.dropLast())
    }

    private static func isPlainNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || " _.-".unicodeScalars
            .contains(scalar))
    }
}
