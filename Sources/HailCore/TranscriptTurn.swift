/// Read-only labels for a document turn. A heard caption carries no evidence of a successful send.
public struct TranscriptTurn: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case transportCompleted(ConversationEntry.TransportDestination), notSent, overheard, heard, reply, unknown

        /// Heard but not sent, and refused: the amber warning tint, distinct from Sent and the on-air red
        /// (owner, 2026-11-26).
        public var isHeldWarning: Bool {
            switch self {
            case .overheard, .notSent: true
            case .transportCompleted, .heard, .reply, .unknown: false
            }
        }

        public var chip: (title: String, accessibilityLabel: String)? {
            switch self {
            case .transportCompleted(let destination):
                ("Sent", "Sent to \(destination.hostName) · \(destination.targetName).")
            case .notSent: ("Not sent", "Not sent.")
            case .overheard: ("Heard · not sent", "Heard but not sent.")
            case .heard: ("Heard", "Heard. Send unconfirmed.")
            case .unknown: ("Unconfirmed", "Send unconfirmed.")
            case .reply: nil
            }
        }
    }

    public let speaker: String
    public let session: String?
    public let delivery: Delivery

    public init(entry: ConversationEntry, sessionName: String?) {
        switch entry.speaker {
        // The owner role and a device's own sends both read "You". Neither carries voiceprint provenance.
        case .you: speaker = "You"
        case .haili: speaker = "Haili"
        case .someone: speaker = entry.name ?? "Unknown"
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
        } else if entry.ambientHeard {
            delivery = .heard
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
