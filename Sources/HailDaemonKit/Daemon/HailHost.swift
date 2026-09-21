// The host's policy transaction helpers intentionally remain beside the actor state they protect.
// swiftlint:disable file_length
import Foundation
public import HailProtocol
public enum HostError: Error, Equatable, Sendable {
    case unknownTarget(String)
    case adapterUnavailable(kind: String, reason: String)
    case refused(SanitizeError)
    case denied(Denial)
    case partial(delivered: [String], reason: String)
    case policyUnavailable(String)
}
/// Host composition root (#10): registry, policy (#41), and a sanitised path re-evaluated before every line.
public actor HailHost {
    public static let confirmationWindow: Duration = .seconds(120)
    /// Read-backs outstanding at once; past this the oldest is dropped, so asking is never a way to grow memory.
    public static let pendingLimit = 64
    public let registry: Registry
    private let sanitizing: SanitizePolicy
    private let store: any PolicyStore
    private let clock = ContinuousClock()
    private let window: Duration
    private var policy: Policy
    private var policyRevision = UUID()
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
    /// Sanitises `text`, asks the policy, and delivers line by line to `id`. A `needsConfirmation` outcome
    /// carries the read-back; send the same text again with its `hash` as `confirmedHash` to deliver.
    @discardableResult
    public func send(
        _ text: String, to id: String, from device: String = "keyboard", confirmedHash: String? = nil
    ) async throws -> SendOutcome {
        try requireSendPreflight()
        let lines: [String]
        do {
            lines = try Sanitizer.sanitize(text, policy: sanitizing)
        } catch let error as SanitizeError {
            throw HostError.refused(error)
        }
        let listed = try await listed(id)
        // Refresh after listing before consuming a confirmation that may have waited on a policy change.
        if confirmedHash != nil { try refreshPolicy() }
        var request = DeliveryRequest(target: id, binding: listed.binding, lines: lines, device: device)
        // No suspension from here to the first evaluation: the consumed token cannot go stale in between.
        let confirmed = consume(confirmedHash, for: request)
        let confirmedRevision = policyRevision
        var delivered: [String] = []
        for (index, line) in lines.enumerated() {
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
                try await registry.deliver(line, to: id, binding: listed.binding)
            } catch let error as AdapterError where !delivered.isEmpty {
                throw HostError.partial(delivered: delivered, reason: "\(error)")
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
    func requirePolicy() throws {
        if policyFailure != nil { try refreshPolicy() }
    }
    /// One store transaction: applied to what is stored now (not this process's snapshot), compiled
    /// before it is written, then adopted here; memory never holds a policy the store does not.
    private func commit(_ change: (inout Policy) throws -> Void) throws {
        let update = try store.update { policy in
            try change(&policy)
            _ = try PolicyEvaluator(policy: policy)
        }
        let compiled: PolicyEvaluator
        do {
            compiled = try PolicyEvaluator(policy: update.policy)
        } catch {
            revokeAuthority()
            policyFailure = "\(error)"
            throw error
        }
        policy = update.policy
        evaluator = compiled
        revokeAuthority()
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
    func revokeAuthority() { (pending, policyRevision) = ([:], UUID()) }
}
