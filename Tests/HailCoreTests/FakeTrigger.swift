import HailCore

/// Test double every higher-level test uses instead of a real trigger (#5).
struct FakeTrigger: Trigger {
    let events: AsyncStream<TriggerEvent>

    init(_ scripted: [TriggerEvent]) {
        events = AsyncStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }
}
