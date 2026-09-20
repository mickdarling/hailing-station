/// A sliding one-minute window per key (a target id, or a device id), value semantics (#41 item 4).
/// Timestamps are monotonic instants, so a wall-clock step can neither extend nor void the window. The
/// caller records an admitted attempt before awaiting the adapter, so concurrent sends share one budget
/// and an adapter failure spends its slot (fail closed); policy refusals do not.
public struct RateLimiter: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    private var deliveries: [String: [Instant]] = [:]

    public init() {}

    /// The keys one request spends: the target's and the device's, in their own namespaces. Both the
    /// evaluator and the caller that records a delivery use this, so the format lives in one place.
    public static func keys(for request: DeliveryRequest) -> [String] {
        ["target:" + request.target, "device:" + request.device]
    }

    /// Records a delivery under every key the request spends.
    public mutating func record(_ request: DeliveryRequest, at now: Instant) {
        for key in Self.keys(for: request) { record(key, at: now) }
    }

    /// Time until `count` deliveries would fit within the limit, or `nil` when all are allowed now. A
    /// nonpositive limit or a request larger than the limit is refused for the full window.
    public func retryAfter(
        for key: String, now: Instant, limitPerMinute: Int, consuming count: Int = 1
    ) -> Duration? {
        guard count >= 0 else { return .seconds(60) }
        guard count > 0 else { return nil }
        guard limitPerMinute > 0, count <= limitPerMinute else { return .seconds(60) }
        let recent = (deliveries[key] ?? []).filter { $0.duration(to: now) < .seconds(60) }.sorted()
        let capacityBeforeRequest = limitPerMinute - count
        guard recent.count > capacityBeforeRequest else { return nil }
        let excess = recent.count - capacityBeforeRequest
        // Enough entries must expire to fit the whole request, not only its first delivery.
        let blocking = recent[excess - 1]
        return min(.seconds(60), max(.zero, .seconds(60) - blocking.duration(to: now)))
    }

    /// Records a delivery and forgets every entry, under any key, older than the window.
    public mutating func record(_ key: String, at now: Instant) {
        deliveries[key, default: []].append(now)
        for (each, stamps) in deliveries {
            let kept = stamps.filter { $0.duration(to: now) < .seconds(60) }
            deliveries[each] = kept.isEmpty ? nil : kept
        }
    }
}
