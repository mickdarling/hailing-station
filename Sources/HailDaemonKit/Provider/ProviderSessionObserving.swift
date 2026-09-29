/// Capability declarations are not authorization or evidence that any particular event occurred.
public enum ProviderObservationCapability: Sendable, Hashable {
    case userVisibleText, explicitAcceptance, explicitCompletion
}

public enum ProviderObservationError: Error, Sendable, Equatable {
    case unavailable, interrupted, bufferOverflow
}

/// Optional output side of a provider adapter, separate from the legacy target-list/delivery Adapter.
/// Implementations must honor the binding, use bounded buffering, surface lost observation/overflow,
/// and cancel their observation work when the consumer terminates. No implementation is registered yet.
public protocol ProviderSessionObserving: Sendable {
    var observationCapabilities: Set<ProviderObservationCapability> { get }
    func observe(_ binding: ProviderSessionBinding) async throws -> AsyncThrowingStream<ProviderSessionEvent, any Error>
}

/// Bounded channel for observer implementations. Overflow ends the observation with an explicit error;
/// it cannot silently discard a final/failure event and continue claiming a complete stream.
public struct ProviderEventChannel: Sendable {
    public let stream: AsyncThrowingStream<ProviderSessionEvent, any Error>
    private let continuation: AsyncThrowingStream<ProviderSessionEvent, any Error>.Continuation

    public init(capacity: Int = 64, onTermination: @escaping @Sendable () -> Void = {}) throws {
        guard (1...ProviderEventLimits.maxBufferedEvents).contains(capacity) else {
            throw ProviderContractError.invalidCapacity
        }
        let pair = AsyncThrowingStream<ProviderSessionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { _ in onTermination() }
    }

    @discardableResult
    public func yield(_ event: ProviderSessionEvent) -> Bool {
        switch continuation.yield(event) {
        case .enqueued: return true
        case .dropped:
            continuation.finish(throwing: ProviderObservationError.bufferOverflow)
            return false
        case .terminated: return false
        @unknown default:
            continuation.finish(throwing: ProviderObservationError.bufferOverflow)
            return false
        }
    }

    public func finish(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }
}
