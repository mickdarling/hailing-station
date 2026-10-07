public import Foundation
import HailProtocol
public import Observation

/// One message in the station chat (#288): something the user sent, or Haili's reply.
public struct ConversationEntry: Identifiable, Equatable, Sendable {
    public enum Speaker: Sendable { case you, haili }

    public let id: String
    public let speaker: Speaker
    public var text: String
    public let endpointID: HostEndpoint.Identifier
    public let targetID: String
    public let date: Date
}

/// The session's conversation, in the order things happened: each request as it is sent, each reply as its text
/// first arrives (later text for the same reply updates it in place). Kept in the model rather than a view so
/// replies that arrive in the background are already in place on return (#282). Memory only, bounded; never logged.
@MainActor
@Observable
public final class ConversationLog {
    public static let limit = 200

    public private(set) var entries: [ConversationEntry] = []
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Entries for one destination, oldest first.
    public func entries(endpointID: HostEndpoint.Identifier, targetID: String) -> [ConversationEntry] {
        entries.filter { $0.endpointID == endpointID && $0.targetID == targetID }
    }

    func noteSent(_ text: String, endpointID: HostEndpoint.Identifier, targetID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(ConversationEntry(
            id: "you|\(UUID().uuidString.lowercased())", speaker: .you, text: trimmed,
            endpointID: endpointID, targetID: targetID, date: now()
        ))
    }

    /// A reply's text frame. The id matches `ReplyPresentation.id`, so the chat can show that reply's playback.
    func noteReply(_ event: HostReplyEvent) {
        guard case .text(let payload) = event.frame.payload, let reply = payload.reply else { return }
        let id = "\(event.endpointID)|\(reply.id.uuidString.lowercased())"
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = payload.text
            return
        }
        append(ConversationEntry(
            id: id, speaker: .haili, text: payload.text,
            endpointID: event.endpointID, targetID: reply.targetID, date: now()
        ))
    }

    private func append(_ entry: ConversationEntry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
