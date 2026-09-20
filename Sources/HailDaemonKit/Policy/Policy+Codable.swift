public import Foundation

/// The on-disk form of `Policy` (#41 item 1): versioned, unknown keys refused, default guard list omitted,
/// sorted keys. The signature (host key, #39) covers these bytes.
extension Policy {
    /// The encoder for the signed file: sorted keys, stable output.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// A minimal document (`{"version":1}`) decodes with the defaults; the version is required and anything
    /// unknown is refused.
    public init(from decoder: any Decoder) throws {
        try decoder.refuseUnknownKeys(besides: CodingKeys.self)
        let known = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try known.decodeIfPresent(Int.self, forKey: .version) else {
            throw PolicyFormatError.missingVersion
        }
        guard version == Self.version else { throw PolicyFormatError.unsupportedVersion(version) }
        targets = try known.decodeIfPresent([String: TargetPolicy].self, forKey: .targets) ?? [:]
        if known.contains(.guardPatterns) {
            guardPatterns = try known.decode([GuardPattern].self, forKey: .guardPatterns)
            guard !guardPatterns.isEmpty else { throw PolicyFormatError.emptyGuardPatterns }
        } else {
            guardPatterns = DangerousPatternGuard.defaults
        }
        deliveriesPerMinute = try known.decodeIfPresent(Int.self, forKey: .deliveriesPerMinute) ?? 30
        guard deliveriesPerMinute > 0 else { throw PolicyFormatError.invalidRateLimit(deliveriesPerMinute) }
        guard !targets.keys.contains("") else { throw PolicyFormatError.emptyTargetID }
        if let blank = targets.first(where: { !$0.value.binding.contains(where: { !$0.isWhitespace }) }) {
            throw PolicyFormatError.emptyBinding(blank.key)
        }
        _ = try PolicyEvaluator(policy: self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(targets, forKey: .targets)
        if guardPatterns != DangerousPatternGuard.defaults {
            try container.encode(guardPatterns, forKey: .guardPatterns)
        }
        try container.encode(deliveriesPerMinute, forKey: .deliveriesPerMinute)
    }
}

/// Every object in the policy file refuses keys it does not know, so a future key with security meaning
/// can never be dropped by an older daemon and honoured only in part.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// Throws `PolicyFormatError.unknownKeys` for any key at this level outside `known`.
    func refuseUnknownKeys<Key: CodingKey & CaseIterable>(besides known: Key.Type) throws {
        let present = try container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let unknown = present.filter { Key(stringValue: $0) == nil }.sorted()
        guard unknown.isEmpty else { throw PolicyFormatError.unknownKeys(unknown) }
    }
}

extension TargetPolicy {
    enum CodingKeys: String, CodingKey, CaseIterable { case tier, capture, binding }

    public init(from decoder: any Decoder) throws {
        try decoder.refuseUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decode(Tier.self, forKey: .tier)
        capture = try container.decode(Bool.self, forKey: .capture)
        binding = try container.decode(String.self, forKey: .binding)
    }
}

extension GuardPattern {
    enum CodingKeys: String, CodingKey, CaseIterable { case name, regex }

    public init(from decoder: any Decoder) throws {
        try decoder.refuseUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        regex = try container.decode(String.self, forKey: .regex)
    }
}
