import CryptoKit
import Darwin
import Foundation

/// One rule's positive evidence, from the evaluation that gated delivery (#1120). Contains no request text.
public struct GuardHit: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case match, timeout }
    public let name: String
    public let outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}

/// A decision and the guard evidence produced by that same evaluation (#1120). Legacy callers can
/// keep using `evaluate`; read-back and refusal consumers can use `evaluateWithEvidence` without rescanning.
public struct PolicyEvaluation: Sendable, Equatable {
    public let decision: Decision
    public let guardOutcomes: [GuardHit]
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
    /// What the guard reads when it is not `lines`: for a framed paste (#608), only the spoken request's sanitized
    /// lines (empty for a paste sent on its own). The paste body is screened for a validation flag instead. Only the
    /// host's paste path sets it (#635 review): outside this module a request is always guarded on its `lines`.
    var guardLines: [String]?

    public init(target: String, binding: String?, lines: [String], device: String) {
        self.target = target
        self.binding = binding
        self.lines = lines
        self.device = device
    }

    init(target: String, binding: String?, lines: [String], device: String, guardLines: [String]?) {
        self.init(target: target, binding: binding, lines: lines, device: device)
        self.guardLines = guardLines
    }
}

/// A read-back the caller must complete before the same utterance can go out (#41 item 2). `hash` binds
/// the confirmation to these lines, this target and binding, and this device; the host accepts it once,
/// within `HailHost.confirmationWindow`, and re-evaluates policy when it comes back.
public struct ReadBack: Sendable, Equatable {
    public var reason: String
    public var guardHits: [String]
    /// Same-evaluation evidence (#1120); names retain the policy's privacy boundary, just like `guardHits`.
    public var guardOutcomes: [GuardHit] = []
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

/// Internal synchronous enumeration seam: tests control callback ordering without depending on ICU progress cadence.
enum GuardMatchDriver {
    typealias Callback = (Bool) -> Bool
    typealias Enumeration = @Sendable (NSRegularExpression, String, Callback) -> Void
    @TaskLocal static var enumerate: Enumeration = { regex, line, callback in
        let range = NSRange(line.startIndex..., in: line)
        regex.enumerateMatches(in: line, options: .reportProgress, range: range) { result, _, stop in
            if callback(result != nil) { stop.pointee = true }
        }
    }
}

/// Injectable wall and thread CPU clocks (#208, #1120). Matching is synchronous: CPU readings stay on
/// one thread. The legacy wall-only test initializer freezes CPU time; production binds neither clock.
struct GuardBudgetClock: Sendable {
    @TaskLocal static var current = GuardBudgetClock(now: { ContinuousClock.now }, cpuNow: threadCPUTime)
    let now: @Sendable () -> ContinuousClock.Instant
    let cpuNow: @Sendable () -> Duration?

    init(_ now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.init(now: now, cpuNow: { .zero })
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant, cpuNow: @escaping @Sendable () -> Duration?) {
        self.now = now
        self.cpuNow = cpuNow
    }

    static func threadCPUTime() -> Duration? {
        var sample = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &sample) == 0 else { return nil }
        return .seconds(sample.tv_sec) + .nanoseconds(sample.tv_nsec)
    }
}
