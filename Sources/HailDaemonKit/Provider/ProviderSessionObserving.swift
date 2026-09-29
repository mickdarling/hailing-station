/// Capability declarations are not authorization or evidence that any particular event occurred.
public enum ProviderObservationCapability: Sendable, Hashable {
    case userVisibleText, explicitAcceptance, explicitCompletion
}

public enum ProviderObservationError: Error, Sendable, Equatable {
    case unavailable, interrupted, bufferOverflow
}

/// Optional output side of a provider adapter, separate from the legacy target-list/delivery Adapter.
/// Implementations must honor the binding, use bounded buffering, surface lost observation/overflow,
/// and cancel upstream work when the lease ends. Consumers must `defer { observation.cancel() }`
/// around iteration, including early exit or rebinding; breaking a stream alone does not end it.
/// No implementation is registered yet.
public protocol ProviderSessionObserving: Sendable {
    var observationCapabilities: Set<ProviderObservationCapability> { get }
    func observe(_ binding: ProviderSessionBinding) async throws -> ProviderObservation
}

/// Consumer lease with explicit, idempotent cleanup independent of task cancellation.
public struct ProviderObservation: Sendable {
    public let events: AsyncThrowingStream<ProviderSessionEvent, any Error>
    private let cancelObservation: @Sendable () -> Void

    init(
        events: AsyncThrowingStream<ProviderSessionEvent, any Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        cancelObservation = cancel
    }

    /// Ends upstream observation. Consumers must stop reading the old lease after cancellation.
    public func cancel() { cancelObservation() }
}

/// Bounded channel for observer implementations. Overflow ends the observation with an explicit error;
/// it cannot silently discard a final/failure event and continue claiming a complete stream.
public struct ProviderEventChannel: Sendable {
    public let stream: AsyncThrowingStream<ProviderSessionEvent, any Error>
    private let continuation: AsyncThrowingStream<ProviderSessionEvent, any Error>.Continuation

    public var observation: ProviderObservation {
        ProviderObservation(events: stream) { continuation.finish(throwing: ProviderObservationError.interrupted) }
    }

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
