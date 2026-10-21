public import Foundation
import HailProtocol
public import Observation

/// One message in the station chat (#288): something the user sent, Haili's reply, or (#398) a remark the ambient
/// stream heard but did not send, by the user or by someone else.
public struct ConversationEntry: Identifiable, Equatable, Sendable {
    public enum Speaker: Sendable { case you, haili, someone }

    public let id: String
    public let speaker: Speaker
    public var text: String
    public let endpointID: HostEndpoint.Identifier
    public let targetID: String
    public let date: Date
    /// Heard but not sent to the target (#398): shown greyed, and hidden with the overheard setting.
    public var overheard = false
    /// The known guest who said an overheard turn (#434), from the host's `name`; nil shows "Someone". Never the
    /// owner's, never logged.
    public var name: String?
    /// A reply's unspoken Markdown (#606), shown beside its spoken `text` through `MessageMarkdown`; never spoken.
    public var metadata: String? {
        didSet {
            guard metadata != oldValue else { return } // A repeated text frame with the same details is not re-parsed.
            metadataBlocks = metadata.map(MessageMarkdown.blocks) ?? []
        }
    }
    /// `metadata` parsed once when it is set, not on every redraw or context menu.
    public private(set) var metadataBlocks: [MarkdownBlock] = []
    /// The reply has audio (#606), so its `text` is the words spoken aloud: the chat shows it in a speech style.
    public var spoken = false
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

    /// A turn the ambient stream heard but did not send (#398), as the owner's or someone else's, with a known
    /// guest's `name` when the host bound one (#434). A name is kept only for someone else's turn.
    func noteOverheard(
        _ text: String, owner: Bool, name: String? = nil, endpointID: HostEndpoint.Identifier, targetID: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entry = ConversationEntry(
            id: "heard|\(UUID().uuidString.lowercased())", speaker: owner ? .you : .someone, text: trimmed,
            endpointID: endpointID, targetID: targetID, date: now()
        )
        entry.overheard = true
        entry.name = owner ? nil : AmbientOverheard.name(name)
        append(entry)
    }

    /// A reply's text frame. The id matches `ReplyPresentation.id`, so the chat can show that reply's playback.
    func noteReply(_ event: HostReplyEvent) {
        guard case .text(let payload) = event.frame.payload, let reply = payload.reply else { return }
        let id = "\(event.endpointID)|\(reply.id.uuidString.lowercased())"
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = payload.text
            entries[index].metadata = payload.metadata
            entries[index].spoken = reply.audioStreamID != nil
            return
        }
        var entry = ConversationEntry(
            id: id, speaker: .haili, text: payload.text,
            endpointID: event.endpointID, targetID: reply.targetID, date: now()
        )
        entry.metadata = payload.metadata
        entry.spoken = reply.audioStreamID != nil
        append(entry)
    }

    private func append(_ entry: ConversationEntry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
