/// A state change for the audit and spoken-notification layers that follow in #43.
public struct LockdownTransition: Sendable, Equatable {
    public var on: Bool
    public var reason: String

    public init(on: Bool, reason: String) {
        self.on = on
        self.reason = reason
    }
}

/// The host kill switch (#43). Repeating the state already in force is idempotent and produces no
/// transition, so callers neither duplicate an audit record nor replace the original lockdown reason.
public struct LockdownState: Sendable, Equatable {
    public static let unspecifiedReason = "unspecified lockdown trigger"

    public private(set) var isOn = false
    public private(set) var reason: String?

    public init() {}

    @discardableResult
    public mutating func engage(reason: String) -> LockdownTransition? {
        guard !isOn else { return nil }
        let recordedReason = reason.contains(where: { !$0.isWhitespace }) ? reason : Self.unspecifiedReason
        isOn = true
        self.reason = recordedReason
        return LockdownTransition(on: true, reason: recordedReason)
    }
}
