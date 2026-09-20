import Foundation

/// Who acted: the device's name as it calls itself (external, cleaned, marked untrusted) and, once #39
/// pairs devices by key, the id of the key that signed (the daemon's own, what repudiation rests on).
/// A string literal is a name alone, so the CLI's `"keyboard"` reads as before.
public struct AuditDevice: Sendable, Equatable, ExpressibleByStringLiteral {
    public var name: String
    public var keyID: String?

    public init(name: String, keyID: String? = nil) {
        self.name = name
        self.keyID = keyID
    }

    public init(stringLiteral value: String) {
        self.init(name: value)
    }
}

/// What happened, in the vocabulary of #42 item 2. One case per event type the daemon records; the
/// coverage test asserts every case produces a record that parses and verifies.
public enum AuditEvent: Sendable, Equatable {
    /// `day` is the file's date (`YYYY-MM-DD`), so a day file cannot be swapped for another day's.
    case chainOpened(day: String)
    case paired(device: AuditDevice)
    case revoked(device: AuditDevice)
    case rotated(keyID: String)
    case connected(device: AuditDevice)
    case disconnected(device: AuditDevice, reason: String)
    case allowed(target: String, tier: String, capture: Bool)
    case denied(target: String)
    case tierChanged(target: String, tier: String)
    /// `text` is the sanitised line as delivered; only its salted hash and length are stored.
    case delivered(target: String, device: AuditDevice, text: String, confirmed: Bool, guardHits: [String],
                   stripped: Int)
    case deliveryRefused(target: String, device: AuditDevice, reason: String)
    case captured(target: String, device: AuditDevice)
    case pushed(tool: String, target: String, bytes: Int)
    case lockdown(on: Bool, reason: String)
    case doctorFailed(check: String, reason: String)

    /// Every kind a v1 record may carry; `verify` refuses any other.
    public static let kinds: Set<String> = [
        "chain_opened", "paired", "revoked", "rotated", "connected", "disconnected", "allowed", "denied",
        "tier_changed", "delivered", "delivery_refused", "captured", "pushed", "lockdown", "doctor_failed"
    ]

    public var kind: String {
        switch self {
        case .chainOpened: return "chain_opened"
        case .paired: return "paired"
        case .revoked: return "revoked"
        case .rotated: return "rotated"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .allowed: return "allowed"
        case .denied: return "denied"
        case .tierChanged: return "tier_changed"
        case .delivered: return "delivered"
        case .deliveryRefused: return "delivery_refused"
        case .captured: return "captured"
        case .pushed: return "pushed"
        case .lockdown: return "lockdown"
        case .doctorFailed: return "doctor_failed"
        }
    }
}

/// One line of the audit log (#42 item 1). Every string that came from outside the daemon (a device
/// name, a tmux session name, a tool name, an adapter's error text) is cleaned by `AuditField.clean` and
/// listed in `untrusted`, so a reader can never mistake it for the daemon's own words. Payload text is
/// never stored: `textHash` is a per-chain salted SHA-256 (threat model B3, B4, #50).
public struct AuditRecord: Codable, Sendable, Equatable {
    public static let version = 1
    public var version: Int = AuditRecord.version
    public var seq: UInt64
    /// RFC 3339 UTC with milliseconds; the daemon's clock, recorded, not trusted by `verify`.
    public var at: String
    public var kind: String
    public var fields: [String: AuditValue]
    /// Names of the keys in `fields` whose strings came from outside the daemon.
    public var untrusted: [String]
    /// Hex SHA-256 of the previous record's `hash`; `AuditChain.genesis` for the first record.
    public var prev: String
    /// Hex SHA-256 over the canonical encoding of this record without `hash` (see `AuditChain`).
    public var hash: String

    enum CodingKeys: String, CodingKey, CaseIterable { case version, seq, at, kind, fields, untrusted, prev, hash }

    /// Unknown keys are refused, so a key planted in a past line cannot ride through `verify` unhashed.
    public init(from decoder: any Decoder) throws {
        try decoder.refuseUnknownKeys(besides: CodingKeys.self)
        let known = try decoder.container(keyedBy: CodingKeys.self)
        version = try known.decode(Int.self, forKey: .version)
        seq = try known.decode(UInt64.self, forKey: .seq)
        at = try known.decode(String.self, forKey: .at)
        kind = try known.decode(String.self, forKey: .kind)
        fields = try known.decode([String: AuditValue].self, forKey: .fields)
        untrusted = try known.decode([String].self, forKey: .untrusted)
        prev = try known.decode(String.self, forKey: .prev)
        hash = try known.decode(String.self, forKey: .hash)
    }

    init(seq: UInt64, at: String, kind: String, fields: [String: AuditValue], untrusted: [String], prev: String,
         hash: String) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.fields = fields
        self.untrusted = untrusted
        self.prev = prev
        self.hash = hash
    }
}

/// A field value: strings, numbers, booleans, or a list of strings; nothing nested, nothing free-form.
public enum AuditValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])

    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try single.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let value): try single.encode(value)
        case .int(let value): try single.encode(value)
        case .bool(let value): try single.encode(value)
        case .strings(let value): try single.encode(value)
        }
    }
}

public enum AuditField {
    /// Longest stored string, in scalars; longer input keeps this many and a marker with the dropped count.
    public static let maxScalars = 256

    /// Control, format, and line-separator scalars become visible `\u{XXXX}` text, as do the backslash
    /// and the ellipsis, so a literal `\u{A}` or `…[+3]` in the input can never pass for an escape or
    /// the truncation marker; anything else is kept; the result is capped. Applied to every external
    /// string before it enters a record, so a device name cannot carry a newline, a terminal escape, or
    /// a bidi override into the log or the reader's screen (threat model B3 log injection, #44).
    public static func clean(_ raw: String) -> String {
        var out = ""
        var kept = 0
        var dropped = 0
        for scalar in raw.unicodeScalars {
            let escape: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                escape = true
            default:
                escape = scalar == "\\" || scalar == "…"
            }
            guard kept < maxScalars else {
                dropped += 1
                continue
            }
            if escape {
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
            kept += 1
        }
        if dropped > 0 { out += "…[+\(dropped)]" }
        return out
    }
}
