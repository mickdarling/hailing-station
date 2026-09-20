/// How much friction a target gets (#41 item 2).
public enum Tier: String, Codable, Sendable, CaseIterable {
    /// Deliver immediately, unless the guard escalates the utterance to `confirm`.
    case open
    /// The terminal reads the utterance back and waits for "send" or a tap. The default for a new allow.
    case confirm
    /// Capture only, if capture is allowed; never deliver.
    case locked
}

/// What one target is allowed to do, decided at the Mac keyboard (#41 items 1, 2, 5).
public struct TargetPolicy: Codable, Sendable, Equatable {
    public var tier: Tier
    public var capture: Bool
    /// The binding the target had when it was allowed. Delivery to the same id with another binding is a
    /// different program under the same name and is refused until re-allowed (threat model B3). Never
    /// optional: an allow without an identity would deliver to whatever holds the name.
    public var binding: String

    public init(tier: Tier = .confirm, capture: Bool = false, binding: String) {
        self.tier = tier
        self.capture = capture
        self.binding = binding
    }
}

/// The policy file's shape is wrong for this daemon.
public enum PolicyFormatError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case unknownKeys([String])
    case invalidGuardPattern(String)
    case emptyGuardPatterns
    case duplicateGuardName(String)
    case emptyTargetID
    case emptyBinding(String)
    case missingVersion
    case invalidRateLimit(Int)
}

/// The whole policy (#41). Serialised to `policy.json` and signed by the host key in a later slice;
/// nothing here reads or writes files. The on-disk form is versioned, refuses unknown keys (a future key
/// with security meaning must never be dropped by an older daemon), omits the guard list when it is the
/// default (so a fix to the defaults reaches every install without a re-sign), and is encoded with
/// sorted keys so the signed bytes are reproducible. A rule that does not compile is refused on decode.
public struct Policy: Codable, Sendable, Equatable {
    public static let version = 1

    public var targets: [String: TargetPolicy]
    /// The guard rules in force: `DangerousPatternGuard.defaults` unless the policy file lists its own.
    public var guardPatterns: [GuardPattern]
    public var deliveriesPerMinute: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case version, targets, guardPatterns, deliveriesPerMinute }

    public init(
        targets: [String: TargetPolicy] = [:], guardPatterns: [GuardPattern] = DangerousPatternGuard.defaults,
        deliveriesPerMinute: Int = 30
    ) {
        self.targets = targets
        self.guardPatterns = guardPatterns
        self.deliveriesPerMinute = deliveriesPerMinute
    }

    /// Allow `id` at its current `binding`; a fresh allow always starts at `confirm` unless said otherwise.
    /// A blank binding is refused: it would match nothing an adapter reports and everything it does not.
    public mutating func allow(_ id: String, binding: String, tier: Tier = .confirm, capture: Bool = false) throws {
        guard !id.isEmpty else { throw PolicyFormatError.emptyTargetID }
        guard binding.contains(where: { !$0.isWhitespace }) else { throw PolicyFormatError.emptyBinding(id) }
        targets[id] = TargetPolicy(tier: tier, capture: capture, binding: binding)
    }

    public mutating func deny(_ id: String) {
        targets[id] = nil
    }

    /// Returns false if `id` is not allowed; the tier of an unknown target cannot be set.
    @discardableResult
    public mutating func setTier(_ tier: Tier, for id: String) -> Bool {
        guard targets[id] != nil else { return false }
        targets[id]?.tier = tier
        return true
    }
}

/// Why delivery was refused, in words the terminal speaks (#41 item 7 feeds these to #42 as well).
public enum Denial: Sendable, Equatable {
    case lockdown
    case notAllowed(String)
    /// The caller's listing reported no binding, so the allow cannot be matched against anything.
    case unbound(String)
    /// Allowed under another binding: the program behind the name changed since the allow.
    case rebound(String)
    case locked(String)
    case emptyRequest
    case rateLimited(retryAfter: Duration)
}

/// The outcome of asking whether an utterance may go to a target now. `guardHits` names every rule
/// that fired, for the read-back and the audit record (#42), whether or not the tier already required
/// confirmation.
public enum Decision: Sendable, Equatable {
    case deliver
    /// Read back first; `reason` is spoken ("confirm tier", "guarded: rm -rf, sudo").
    case confirm(reason: String, guardHits: [String])
    case denied(Denial)
}

/// One utterance headed for one target: the id, the binding the caller's listing reported, the lines the
/// sanitizer produced (guards run on those, never on the frame text), and the device it came from, so
/// the rate limit applies per device as well as per target (#41 item 4).
public struct DeliveryRequest: Sendable, Equatable {
    public var target: String
    public var binding: String?
    public var lines: [String]
    /// Every frame that reaches policy came from a paired device; the CLI passes its own name.
    public var device: String

    public init(target: String, binding: String?, lines: [String], device: String) {
        self.target = target
        self.binding = binding
        self.lines = lines
        self.device = device
    }
}

/// Decides delivery and capture from a `Policy` plus the moment's state (#41). Pure: the caller supplies
/// the monotonic instant and the rate-limit history, so every rule is testable without time or files.
public struct PolicyEvaluator: Sendable {
    public let policy: Policy
    private let guards: CompiledGuards

    /// Compiles the guard rules once; a rule that does not compile is refused here, by name.
    public init(policy: Policy) throws {
        guard !policy.targets.keys.contains("") else { throw PolicyFormatError.emptyTargetID }
        guard !policy.guardPatterns.isEmpty else { throw PolicyFormatError.emptyGuardPatterns }
        var names = Set<String>()
        if let duplicate = policy.guardPatterns.first(where: { !names.insert($0.name).inserted }) {
            throw PolicyFormatError.duplicateGuardName(duplicate.name)
        }
        self.policy = policy
        do {
            guards = try CompiledGuards(policy.guardPatterns)
        } catch let error as InvalidGuardPattern {
            throw PolicyFormatError.invalidGuardPattern(error.name)
        }
    }

    /// Order: lockdown, nonempty request, allow list, binding, tier, rate limit (target then device), guard. The
    /// first refusal wins. The rate limit is consulted before the guard so a refused utterance costs no
    /// guard work; the caller records an admitted attempt before awaiting the adapter, and re-evaluates at
    /// the moment of delivery (a `Decision` is never cached across a confirmation, #43 lockdown races).
    public func evaluate(
        _ request: DeliveryRequest, lockdown: Bool, limiter: RateLimiter, now: RateLimiter.Instant
    ) -> Decision {
        let id = request.target
        if lockdown { return .denied(.lockdown) }
        guard !request.lines.isEmpty else { return .denied(.emptyRequest) }
        guard let target = policy.targets[id] else { return .denied(.notAllowed(id)) }
        guard let binding = request.binding, binding.contains(where: { !$0.isWhitespace }) else {
            return .denied(.unbound(id))
        }
        guard target.binding == binding else { return .denied(.rebound(id)) }
        if target.tier == .locked { return .denied(.locked(id)) }
        let waits = RateLimiter.keys(for: request).compactMap {
            limiter.retryAfter(
                for: $0, now: now, limitPerMinute: policy.deliveriesPerMinute, consuming: request.lines.count
            )
        }
        if let longest = waits.max() { return .denied(.rateLimited(retryAfter: longest)) }
        let hits = guards.matches(in: request.lines)
        if target.tier == .confirm { return .confirm(reason: "confirm tier", guardHits: hits) }
        if !hits.isEmpty { return .confirm(reason: "guarded: " + hits.joined(separator: ", "), guardHits: hits) }
        return .deliver
    }

    /// Capture is its own permission (#41 item 5) and never bypasses lockdown or the binding.
    public func mayCapture(target id: String, binding: String?, lockdown: Bool) -> Bool {
        guard !lockdown, let binding, binding.contains(where: { !$0.isWhitespace }),
              let target = policy.targets[id] else { return false }
        return target.binding == binding && target.capture
    }
}
