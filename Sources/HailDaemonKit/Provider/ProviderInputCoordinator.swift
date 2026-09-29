public import Foundation

public enum ProviderInputCoordinatorError: Error, Sendable, Equatable {
    case dispatchInProgress, invalidTimeout, invalidBinding
}

public enum ProviderInputOutcome: Sendable, Equatable {
    case sent(ProviderTurnContext)
    case needsConfirmation(ReadBack)
}

public enum ProviderInputDeliveryMode: Sendable {
    case legacy, contextual
}

/// Executes guarded host dispatch and owns bounded correlation for one immutable generation (#140).
/// `binding.sessionID` is the exact opaque AdapterTarget.binding, never a display/session name.
/// This actor owns no observer or publisher. Contextual dispatch explicitly opts into adapter handoff.
public actor ProviderInputCoordinator {
    public static let maxTimeout: Duration = .seconds(86_400)

    public struct Configuration: Sendable {
        public let timeout: Duration
        public let maxTurns: Int
        public let maxEvents: Int
        public let deliveryMode: ProviderInputDeliveryMode

        public init(
            timeout: Duration = .seconds(120), maxTurns: Int = 128,
            maxEvents: Int = ProviderEventLimits.maxRetainedEvents, deliveryMode: ProviderInputDeliveryMode = .legacy
        ) {
            self.timeout = timeout
            self.maxTurns = maxTurns
            self.maxEvents = maxEvents
            self.deliveryMode = deliveryMode
        }
    }

    public let binding: ProviderSessionBinding
    public let connectionID: UUID
    private let host: HailHost
    private let timeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let deliveryMode: ProviderInputDeliveryMode
    private var correlator: ProviderTurnCorrelator
    private var deadlines: [UUID: ContinuousClock.Instant] = [:]
    private var dispatching = false

    public init(
        host: HailHost, binding: ProviderSessionBinding, connectionID: UUID,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) throws {
        guard configuration.timeout > .zero, configuration.timeout <= Self.maxTimeout else {
            throw ProviderInputCoordinatorError.invalidTimeout
        }
        let prefix = binding.providerID + ":"
        guard !binding.providerID.contains(":"), binding.targetID.hasPrefix(prefix),
              binding.targetID.count > prefix.count else {
            throw ProviderInputCoordinatorError.invalidBinding
        }
        self.host = host
        self.binding = binding
        self.connectionID = connectionID
        timeout = configuration.timeout
        self.now = now
        deliveryMode = configuration.deliveryMode
        correlator = try ProviderTurnCorrelator(
            binding: binding, connectionID: connectionID,
            maxTurns: configuration.maxTurns, maxEvents: configuration.maxEvents
        )
    }

    /// Capacity is admitted before side effects; only a complete successful dispatch creates a sent turn.
    /// Confirmation and partial/failed writes preserve the host's outcome/error, with no sent turn.
    public func submit(
        _ text: String, utteranceID: UUID, from device: String = "keyboard", confirmedHash: String? = nil
    ) async throws -> ProviderInputOutcome {
        try Task.checkCancellation()
        guard !dispatching else { throw ProviderInputCoordinatorError.dispatchInProgress }
        let context = ProviderTurnContext(utteranceID: utteranceID, connectionID: connectionID, binding: binding)
        try correlator.validateSent(context)
        dispatching = true
        defer { dispatching = false }
        let outcome = try await dispatch(text, context: context, from: device, confirmedHash: confirmedHash)
        switch outcome {
        case .needsConfirmation(let readBack):
            return .needsConfirmation(readBack)
        case .delivered:
            try correlator.recordSent(context)
            deadlines[context.id] = now().advanced(by: timeout)
            return .sent(context)
        }
    }

    private func dispatch(
        _ text: String, context: ProviderTurnContext, from device: String, confirmedHash: String?
    ) async throws -> SendOutcome {
        switch deliveryMode {
        case .legacy:
            try await host.send(text, to: binding.targetID, from: device,
                                confirmedHash: confirmedHash, expectedBinding: binding.sessionID)
        case .contextual:
            try await host.send(text, context: context, from: device, confirmedHash: confirmedHash)
        }
    }

    /// The caller retries early events after dispatch completes. Rejection here consumes no sequence.
    /// Context handoff does not supply stream ownership or a bounded early-event retry owner.
    public func ingest(_ event: ProviderSessionEvent) throws -> ProviderEventCorrelation {
        guard !dispatching else { throw ProviderInputCoordinatorError.dispatchInProgress }
        expireDueTurns()
        let result = correlator.observe(event)
        if case .associated(let context, let state) = result, state.isTerminal { deadlines[context.id] = nil }
        return result
    }

    /// A future owner schedules this with a monotonic clock; ingestion also expires due turns.
    /// Expired identity remains retained, so late output cannot complete a later request.
    @discardableResult
    public func expireDueTurns() -> [UUID] {
        let instant = now()
        let expired = deadlines.filter { $0.value <= instant }.map(\.key).sorted { $0.uuidString < $1.uuidString }
        for turnID in expired {
            // A deadline is installed only for a sent turn and removed whenever it becomes terminal.
            try? correlator.timeOut(turnID)
            deadlines[turnID] = nil
        }
        return expired
    }

    public func state(for turnID: UUID) -> ProviderTurnState? { correlator.state(for: turnID) }
}
