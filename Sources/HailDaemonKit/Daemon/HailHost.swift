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
    public let registry: Registry
    private let sanitizing: SanitizePolicy
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
        let lines: [String]
        do {
            lines = try Sanitizer.sanitize(text, policy: sanitizing)
        } catch let error as SanitizeError {
            throw HostError.refused(error)
        }
        let listed = try await dispatchListing(dispatch, lineCount: lines.count)
        // Commit the first dispatch attempt after policy I/O, before consuming one-shot confirmation.
        // No further cancellation observation occurs before its adapter handoff; later lines may stop.
        try Task.checkCancellation()
        var request = DeliveryRequest(target: id, binding: listed.binding, lines: lines, device: dispatch.device)
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
}
