import Foundation

/// What haild does with an APNs answer (#609, `docs/proactive-notifications.md`, "Failures"). Reasons are Apple's fixed
/// tokens; anything else is reported as `unknown`, so no response text reaches a log or the audit.
enum APNsOutcome: Sendable, Equatable {
    case delivered
    /// The device token is dead or wrong for this environment: forget the token, keep the key's approval.
    case removeToken(reason: String)
    /// The provider token was refused: refresh it once if Apple's 20-minute limit allows, never touch device tokens.
    case refreshProviderToken(reason: String)
    /// Too many provider-token refreshes: a signing bug to report, not a reason to retry.
    case signingBug
    /// Try again later. The retry re-runs the delivery ladder, so privacy or quiet that began since cancels it.
    case retry(after: TimeInterval, reason: String)
    /// Refused for good: report it, no retry.
    case failed(status: Int, reason: String)

    static let retryDelay: TimeInterval = 15 * 60

    /// The outcome for `status` and the JSON response `body`, whose only field read is `reason`.
    static func classify(status: Int, body: Data?) -> APNsOutcome {
        let reason = reasonToken(body)
        switch (status, reason) {
        case (200, _): return .delivered
        case (410, _), (400, "BadDeviceToken"): return .removeToken(reason: reason)
        case (403, "InvalidProviderToken"), (403, "ExpiredProviderToken"), (403, "MissingProviderToken"):
            return .refreshProviderToken(reason: reason)
        case (429, "TooManyProviderTokenUpdates"): return .signingBug
        case (429, _), (500...599, _): return .retry(after: retryDelay, reason: reason)
        default: return .failed(status: status, reason: reason)
        }
    }

    /// Apple's reason token, or `unknown` when the body is missing, malformed, or not a short ASCII word.
    private static func reasonToken(_ body: Data?) -> String {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reason = object["reason"] as? String, (1...64).contains(reason.utf8.count),
              reason.utf8.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) })
        else { return "unknown" }
        return reason
    }
}
