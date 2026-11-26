/// Read-only labels for a document turn. A heard caption carries no evidence of a successful send.
public struct TranscriptTurn: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case transportCompleted(ConversationEntry.TransportDestination), notSent, overheard, reply, unknown
    }

    public let speaker: String
    public let session: String?
    public let delivery: Delivery

    public init(entry: ConversationEntry, sessionName: String?) {
        switch entry.speaker {
        case .you: speaker = "You"
        case .haili: speaker = "Haili"
        case .someone: speaker = entry.name ?? "Someone"
        }
        if entry.notSent || entry.notice {
            delivery = .notSent
        } else if case .refused = entry.pasteState {
            delivery = .notSent
        } else if entry.overheard {
            delivery = .overheard
        } else if entry.speaker == .haili {
            delivery = .reply
        } else if let destination = entry.transportCompletedTo {
            delivery = .transportCompleted(destination)
        } else {
            delivery = .unknown
        }
        if delivery == .reply {
            let name = entry.source ?? sessionName ?? entry.targetID
            session = entry.updatePriority == nil ? name : "\(name) · Update"
        } else {
            session = nil
        }
    }
}
