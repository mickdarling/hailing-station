public import Foundation

/// Proposed held ambient requests (#1120). A capable device advertises this only once it can show the hold,
/// its reasons and Send / Discard. Hosts must gate notices and resolutions on it; neither end advertises it yet.
/// IDs are fresh opaque UUIDs, never text, hashes or bindings. Decisions grant no authority: Send must recheck
/// policy, scope and expiry on the host. A hold must keep the stream alive and never deliver unchecked.
public enum HeldRequests {
    public static let capability = "held_requests"
    public static let maxRules = 16
    public static let maxRuleTokenBytes = 32
    /// Remaining lifetime from notice issuance, in whole seconds, not a wall-clock timestamp.
    public static let expirySeconds = 1...3_600

    static func container<Key: CodingKey>(
        _ type: Key.Type, command: String, allowed: [String], from decoder: any Decoder
    ) throws -> KeyedDecodingContainer<Key> {
        let raw = try decoder.container(keyedBy: DiagnosticCodingKey.self)
        guard raw.allKeys.allSatisfy({ DiagnosticLimits.isOne(of: allowed, $0.stringValue) }),
              try raw.decode(String.self, forKey: DiagnosticCodingKey(stringValue: "command")) == command else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid held request command or key"))
        }
        return try decoder.container(keyedBy: type)
    }

    static func decode(from decoder: any Decoder) throws -> ControlPayload {
        let container = try decoder.container(keyedBy: DiagnosticCodingKey.self)
        switch try container.decode(String.self, forKey: DiagnosticCodingKey(stringValue: "command")) {
        case "request_held": return .requestHeld(try RequestHeld(from: decoder))
        case "held_decision": return .heldDecision(try HeldDecision(from: decoder))
        default: return .heldResolution(try HeldResolution(from: decoder))
        }
    }
}

/// Closed hold causes (#1120); a notice can retain both a match and a timeout from one evaluation.
public enum HeldRequestReason: String, Codable, Sendable, CaseIterable {
    case ruleMatch = "rule_match", guardTimeout = "guard_timeout", confirmTier = "confirm_tier"
    case rateLimited = "rate_limited"
}

/// Built-in guard names as wire tokens, or `custom` for every configured rule (#1120). Never send a custom
/// name or pattern. Space/punctuation-bearing built-in display names are normalized to these snake_case tokens.
public enum HeldRequestRule: String, Codable, Sendable, CaseIterable {
    case rmRF = "rm_rf", sudo, forcePush = "force_push", gitResetHard = "git_reset_hard"
    case gitClean = "git_clean", destructiveGit = "destructive_git", branchDelete = "branch_delete", delete
    case diskWrite = "disk_write", permissions, shell, forkBomb = "fork_bomb", credential, custom
}

/// The device's explicit choice for one held UUID (#1120); Send is a request for host revalidation.
public enum HeldRequestAction: String, Codable, Sendable, CaseIterable {
    case send, discard
}

/// Closed Send revalidation failures (#1120). Never carry identities, request fragments, hashes or policy detail.
public enum HeldRequestRefusalReason: String, Codable, Sendable, CaseIterable {
    case policyChanged = "policy_changed", targetUnavailable = "target_unavailable", bindingChanged = "binding_changed"
    case selectionChanged = "selection_changed", lockdown, denied, rateLimited = "rate_limited", capacity
    case connectionLost = "connection_lost"
}

/// The host's final disposition of a held UUID (#1120), with a closed reason only for refusal.
public enum HeldRequestOutcome: String, Codable, Sendable, CaseIterable {
    case sent, discarded, expired, refused, stale
}

/// Proposed host → device `request_held` notice (#1120), containing no request text or delivery authority.
/// Optional `turn` correlates the existing #923 heard entry and additionally requires `HeardTurns.capability`.
public struct RequestHeld: Codable, Sendable, Equatable {
    public var held: UUID
    public var turn: UUID?
    public var reasons: [HeldRequestReason]
    public var rules: [HeldRequestRule]
    public var expiresIn: Int

    public init(held: UUID, turn: UUID? = nil, reasons: [HeldRequestReason], rules: [HeldRequestRule], expiresIn: Int) {
        self.held = held
        self.turn = turn
        self.reasons = reasons
        self.rules = rules
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case command, held, turn, reasons, rules, expiresIn = "expires_in"
    }

    public init(from decoder: any Decoder) throws {
        let container = try HeldRequests.container(CodingKeys.self, command: "request_held",
            allowed: ["command", "held", "turn", "reasons", "rules", "expires_in"], from: decoder)
        held = try container.decode(UUID.self, forKey: .held)
        turn = container.contains(.turn) ? try container.decode(UUID.self, forKey: .turn) : nil
        reasons = try container.decode([HeldRequestReason].self, forKey: .reasons)
        rules = try container.decode([HeldRequestRule].self, forKey: .rules)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid request_held bounds"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "invalid request_held bounds"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("request_held", forKey: .command)
        try container.encode(held, forKey: .held)
        try container.encodeIfPresent(turn, forKey: .turn)
        try container.encode(reasons, forKey: .reasons)
        try container.encode(rules, forKey: .rules)
        try container.encode(expiresIn, forKey: .expiresIn)
    }

    private var isValid: Bool {
        (1...HeldRequestReason.allCases.count).contains(reasons.count)
            && Set(reasons).count == reasons.count
            && rules.count <= HeldRequests.maxRules
            && rules.allSatisfy { $0.rawValue.utf8.count <= HeldRequests.maxRuleTokenBytes }
            && HeldRequests.expirySeconds.contains(expiresIn)
    }
}

/// Proposed device → host `held_decision` (#1120). Only an opaque held UUID and Send / Discard are carried.
public struct HeldDecision: Codable, Sendable, Equatable {
    public var held: UUID
    public var action: HeldRequestAction

    public init(held: UUID, action: HeldRequestAction) {
        self.held = held
        self.action = action
    }

    private enum CodingKeys: String, CodingKey { case command, held, action }

    public init(from decoder: any Decoder) throws {
        let container = try HeldRequests.container(CodingKeys.self, command: "held_decision",
            allowed: ["command", "held", "action"], from: decoder)
        held = try container.decode(UUID.self, forKey: .held)
        action = try container.decode(HeldRequestAction.self, forKey: .action)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("held_decision", forKey: .command)
        try container.encode(held, forKey: .held)
        try container.encode(action, forKey: .action)
    }
}

/// Proposed host → device `held_resolution` (#1120). `reason` is required only for `refused`, and forbidden
/// otherwise. Its closed vocabulary carries no request text or policy detail.
public struct HeldResolution: Codable, Sendable, Equatable {
    public var held: UUID
    public var outcome: HeldRequestOutcome
    public var reason: HeldRequestRefusalReason?

    public init(held: UUID, outcome: HeldRequestOutcome, reason: HeldRequestRefusalReason? = nil) {
        self.held = held
        self.outcome = outcome
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case command, held, outcome, reason }

    public init(from decoder: any Decoder) throws {
        let container = try HeldRequests.container(CodingKeys.self, command: "held_resolution",
            allowed: ["command", "held", "outcome", "reason"], from: decoder)
        held = try container.decode(UUID.self, forKey: .held)
        outcome = try container.decode(HeldRequestOutcome.self, forKey: .outcome)
        reason = container.contains(.reason)
            ? try container.decode(HeldRequestRefusalReason.self, forKey: .reason) : nil
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid held_resolution reason"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "invalid held_resolution reason"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("held_resolution", forKey: .command)
        try container.encode(held, forKey: .held)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(reason, forKey: .reason)
    }

    private var isValid: Bool {
        outcome == .refused ? reason != nil : reason == nil
    }
}
