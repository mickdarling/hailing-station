public import Foundation

public enum ProviderTurnState: Sendable, Equatable {
    case sent, accepted, running, finished, interrupted, failed, timedOut

    var isTerminal: Bool {
        switch self {
        case .finished, .interrupted, .failed, .timedOut: true
        default: false
        }
    }
}

public enum ProviderUnassociatedReason: Sendable, Equatable {
    case noTurn, unknownTurn, timedOut
}

public enum ProviderEventRejection: Sendable, Equatable {
    case wrongBinding, duplicateEvent, staleSequence, sequenceGap, capacityExceeded
    case wrongTurnContext, turnEnded, invalidTransition
}

public enum ProviderEventCorrelation: Sendable, Equatable {
    case associated(ProviderTurnContext, state: ProviderTurnState)
    case unassociated(ProviderUnassociatedReason)
    case rejected(ProviderEventRejection)
}

/// Deterministic host-local state for one observation and one terminal connection generation (#137, #94).
/// The owner serializes access. No timer, I/O, authorization, publication, or speech policy lives here.
/// Bounds include terminal tombstones: exhaustion fails visibly, never evicts active or expired identity.
public struct ProviderTurnCorrelator: Sendable {
    public let binding: ProviderSessionBinding
    public let connectionID: UUID
    private let maxTurns: Int
    private let maxEvents: Int
    private var contexts: [UUID: ProviderTurnContext] = [:]
    private var states: [UUID: ProviderTurnState] = [:]
    private var seenEvents: Set<UUID> = []
    private var lastSequence: Int?

    public init(
        binding: ProviderSessionBinding, connectionID: UUID,
        maxTurns: Int = 128, maxEvents: Int = ProviderEventLimits.maxRetainedEvents
    ) throws {
        guard (1...ProviderEventLimits.maxRetainedTurns).contains(maxTurns),
              (1...ProviderEventLimits.maxRetainedEvents).contains(maxEvents) else {
            throw ProviderContractError.invalidCapacity
        }
        self.binding = binding
        self.connectionID = connectionID
        self.maxTurns = maxTurns
        self.maxEvents = maxEvents
    }

    /// Checks admission before dispatch without claiming sent or consuming retention capacity.
    /// The owner must reserve exclusive submission across awaited I/O until `recordSent` completes.
    public func validateSent(_ context: ProviderTurnContext) throws {
        guard context.binding == binding, context.connectionID == connectionID else {
            throw ProviderContractError.wrongContext
        }
        guard contexts[context.id] == nil else { throw ProviderContractError.duplicateTurn }
        guard contexts.count < maxTurns else { throw ProviderContractError.capacityExceeded }
        guard seenEvents.count < maxEvents else { throw ProviderContractError.capacityExceeded }
    }

    /// Call only after authorized dispatch reports a successful write. This claims sent, not accepted.
    public mutating func recordSent(_ context: ProviderTurnContext) throws {
        try validateSent(context)
        contexts[context.id] = context
        states[context.id] = .sent
    }

    public func state(for turnID: UUID) -> ProviderTurnState? { states[turnID] }

    /// The owner supplies a tested monotonic deadline. Late events cannot reverse this terminal state.
    public mutating func timeOut(_ turnID: UUID) throws {
        guard let state = states[turnID] else { throw ProviderContractError.unknownTurn }
        guard !state.isTerminal else { throw ProviderContractError.turnEnded }
        states[turnID] = .timedOut
    }

    public mutating func observe(_ event: ProviderSessionEvent) -> ProviderEventCorrelation {
        guard event.binding == binding else { return .rejected(.wrongBinding) }
        if let rejection = orderingRejection(event) { return .rejected(rejection) }
        // Consume valid stream ordering even when the turn is unknown or the lifecycle claim is invalid.
        // Wrong-binding, duplicate, gap, and capacity failures never advance it.
        seenEvents.insert(event.id)
        lastSequence = event.sequence
        guard let turn = event.turn else { return .unassociated(.noTurn) }
        let turnID = turn.id
        guard let context = contexts[turnID], let state = states[turnID] else {
            return .unassociated(.unknownTurn)
        }
        guard context == turn else { return .rejected(.wrongTurnContext) }
        guard state != .timedOut else { return .unassociated(.timedOut) }
        guard !state.isTerminal else { return .rejected(.turnEnded) }
        guard let next = transition(from: state, event: event.kind) else {
            return .rejected(.invalidTransition)
        }
        states[turnID] = next
        return .associated(context, state: next)
    }

    private func orderingRejection(_ event: ProviderSessionEvent) -> ProviderEventRejection? {
        if seenEvents.contains(event.id) { return .duplicateEvent }
        if let lastSequence, event.sequence <= lastSequence { return .staleSequence }
        let expected = lastSequence.map { $0 + 1 } ?? 0
        // lastSequence cannot reach Int.max: its predecessor cannot be received within maxEvents.
        if event.sequence != expected { return .sequenceGap }
        if seenEvents.count >= maxEvents { return .capacityExceeded }
        return nil
    }

    private func transition(from state: ProviderTurnState, event: ProviderEventKind) -> ProviderTurnState? {
        switch event {
        case .accepted: state == .sent ? .accepted : nil
        case .running: .running
        case .text: state // A final text chunk is not an explicit lifecycle completion.
        case .finished: .finished
        case .interrupted: .interrupted
        case .failed: .failed
        }
    }
}
