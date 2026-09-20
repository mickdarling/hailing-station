import CryptoKit

/// A read-back the caller must complete before the same utterance can go out (#41 item 2). `hash` binds
/// the confirmation to these lines, this target and binding, and this device; the host accepts it once,
/// within `HailHost.confirmationWindow`, and re-evaluates policy when it comes back.
public struct ReadBack: Sendable, Equatable {
    public var reason: String
    public var guardHits: [String]
    public var lines: [String]
    public var hash: String
}

public enum SendOutcome: Sendable, Equatable {
    case delivered([String])
    case needsConfirmation(ReadBack)
}

extension DeliveryRequest {
    /// What a confirmation binds to: these exact lines, to this target at this binding, from this device
    /// (#80 design). Domain-separated and length-prefixed, so no two requests collide by concatenation;
    /// a caller that read back one utterance can confirm only that utterance.
    public var confirmationHash: String {
        var bytes = Array("hail/confirm/1".utf8)
        for field in [target, binding ?? "", device] { bytes += Self.lengthPrefixed(Array(field.utf8)) }
        bytes += Self.lengthPrefixed(lines.flatMap { Self.lengthPrefixed(Array($0.utf8)) })
        return SHA256.hash(data: bytes).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
    }

    private static func lengthPrefixed(_ payload: [UInt8]) -> [UInt8] {
        let count = UInt64(payload.count)
        return (0..<8).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) } + payload
    }
}

extension Denial: CustomStringConvertible {
    /// The reason in words the CLI prints and the terminal speaks (#41 acceptance: "with a spoken reason").
    public var description: String {
        switch self {
        case .lockdown: return "the host is in lockdown"
        case .notAllowed(let id): return "target \(id) is not allowed"
        case .unbound(let id): return "target \(id) reported no binding, so it cannot be matched"
        case .rebound(let id): return "target \(id) changed since it was allowed; allow it again"
        case .locked(let id): return "target \(id) is locked"
        case .emptyRequest: return "delivery contains no lines"
        case .rateLimited(let retryAfter):
            let parts = retryAfter.components
            let seconds = parts.seconds + (parts.attoseconds > 0 ? 1 : 0)
            return "rate limit reached, retry in \(seconds) second\(seconds == 1 ? "" : "s")"
        }
    }
}
