public import Foundation
public import Observation

/// App-owned local capture admission, held across permission/startup/retirement waits (#266).
@MainActor @Observable
public final class CoachingCaptureExclusion {
    private var owner: UUID?
    public var isClaimed: Bool { owner != nil }
    public init() {}

    /// The same owner's repeated reservation is idempotent; another owner cannot replace it.
    @discardableResult
    public func claim(_ token: UUID) -> Bool {
        guard owner == nil || owner == token else { return false }
        owner = token
        return true
    }

    /// A delayed cleanup cannot release a successor's admission.
    public func release(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
    }
}
