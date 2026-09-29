public import Foundation
import HailProtocol

/// Host-local contracts (#137), not protocol v1 payloads or evidence of authorization.
public enum ProviderContractError: Error, Sendable, Equatable {
    case invalidIdentifier, invalidSequence, oversizedText, invalidCapacity
    case wrongContext, duplicateTurn, unknownTurn, turnEnded, capacityExceeded
}

public enum ProviderEventLimits {
    public static let maxIdentifiers = ReplyLimits.maxIdentifierBytes
    public static let maxTextBytes = PayloadLimits.maxTextBytes
    public static let maxRetainedTurns = 256
    public static let maxRetainedEvents = 4_096
    public static let maxBufferedEvents = 256
}

/// A fresh observation ID is required on observer restart or replacement of a session/target binding.
/// These identifiers are opaque host-local labels, not authenticated identities or executable paths.
public struct ProviderSessionBinding: Sendable, Equatable, Hashable {
    public let hostID: String
    public let providerID: String
    public let targetID: String
    public let sessionID: String
    public let observationID: UUID

    public init(
        hostID: String, providerID: String, targetID: String, sessionID: String,
        observationID: UUID = UUID()
    ) throws {
        let identifiers = [hostID, providerID, targetID, sessionID]
        guard identifiers.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.utf8.count <= ProviderEventLimits.maxIdentifiers
        }) else { throw ProviderContractError.invalidIdentifier }
        self.hostID = hostID
        self.providerID = providerID
        self.targetID = targetID
        self.sessionID = sessionID
        self.observationID = observationID
    }
}

/// Connection generation is correlation isolation, never terminal authentication. Allocate fresh turn IDs.
public struct ProviderTurnContext: Sendable, Equatable {
    public let id: UUID
    public let utteranceID: UUID
    public let connectionID: UUID
    public let binding: ProviderSessionBinding

    public init(id: UUID = UUID(), utteranceID: UUID, connectionID: UUID, binding: ProviderSessionBinding) {
        self.id = id
        self.utteranceID = utteranceID
        self.connectionID = connectionID
        self.binding = binding
    }
}

public enum ProviderTextVisibility: Sendable, Equatable {
    case userVisible, internalOnly
}

/// Fixed reasons avoid carrying private adapter diagnostics into an eventual display boundary.
public enum ProviderFailureReason: Sendable, Equatable {
    case providerFailed, observationLost, unavailable
}

public enum ProviderEventKind: Sendable, Equatable {
    case accepted
    case running
    case text(String, isFinal: Bool, visibility: ProviderTextVisibility)
    /// Explicit provider lifecycle completion, not proof that a requested real-world effect succeeded.
    case finished
    case interrupted
    case failed(ProviderFailureReason)
}

/// Immutable, bounded events from one observation. Sequence starts at zero and never resets in that observation.
/// A nil turn context is explicitly unassociated; arrival order must not be used to invent one.
public struct ProviderSessionEvent: Sendable, Equatable {
    public let id: UUID
    public let binding: ProviderSessionBinding
    public let sequence: Int
    public let turn: ProviderTurnContext?
    public let kind: ProviderEventKind

    public init(
        binding: ProviderSessionBinding, sequence: Int, turn: ProviderTurnContext? = nil,
        kind: ProviderEventKind, id: UUID = UUID()
    ) throws {
        guard sequence >= 0 else { throw ProviderContractError.invalidSequence }
        guard turn == nil || turn?.binding == binding else { throw ProviderContractError.wrongContext }
        if case .text(let text, _, _) = kind, text.utf8.count > ProviderEventLimits.maxTextBytes {
            throw ProviderContractError.oversizedText
        }
        self.id = id
        self.binding = binding
        self.sequence = sequence
        self.turn = turn
        self.kind = kind
    }
}
