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
    /// A reply from another session that answers a request the user addressed to it by name from the thread it
    /// arrived in (#636): that session's listed name, shown as the reply's label. Nil for every other entry.
    public var source: String?
    /// The thread such a reply shows in, besides its own. Nil otherwise.
    public var shownIn: String?

    /// Whether the entry shows in one destination's thread: its own target's entries, plus a reply that answers a
    /// request addressed from it to another session (`shownIn`). The one place a thread's membership is decided.
    public func belongs(endpointID: HostEndpoint.Identifier, targetID: String) -> Bool {
        self.endpointID == endpointID && (self.targetID == targetID || shownIn == targetID)
    }
}

/// The session's conversation, in the order things happened: each request as it is sent, each reply as its text
/// first arrives (later text for the same reply updates it in place). Kept in the model rather than a view so
/// replies that arrive in the background are already in place on return (#282). Memory only, bounded; never logged.
@MainActor
@Observable
public final class ConversationLog {
    public static let limit = 200

    public private(set) var entries: [ConversationEntry] = []
    /// Requests the user addressed by name to another session (#636), each open for `addressLifetime`; newest last.
    @ObservationIgnored private var addressed: [AddressedRequest] = []
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Entries for one destination, oldest first, with replies to requests addressed from it to other sessions.
    public func entries(endpointID: HostEndpoint.Identifier, targetID: String) -> [ConversationEntry] {
        entries.filter { $0.belongs(endpointID: endpointID, targetID: targetID) }
    }

    /// A request the user sent, or (#318) one the ambient stream heard and sent. When it opens with another listed
    /// session's name and a mark ("Deck, …"), that session's replies show in this thread for `addressLifetime`.
    /// `scope` binds the address to the connection and selection it was sent on; without one nothing is recorded.
    func noteSent(
        _ text: String, endpointID: HostEndpoint.Identifier, targetID: String, targets: [TargetInfo] = [],
        scope: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(ConversationEntry(
            id: "you|\(UUID().uuidString.lowercased())", speaker: .you, text: trimmed,
            endpointID: endpointID, targetID: targetID, date: now()
        ))
        address(trimmed, endpointID: endpointID, targetID: targetID, targets: targets, scope: scope)
    }

    /// Records `text` as addressed from `targetID`'s thread when it opens with another listed session's name, under
    /// `scope`; returns the record's id so a send that fails can take it back (`retractAddress`), or nil when nothing
    /// was recorded. Tap-to-talk calls it before sending, so a fast reply cannot arrive ahead of its address.
    @discardableResult
    func address(
        _ text: String, endpointID: HostEndpoint.Identifier, targetID: String, targets: [TargetInfo], scope: String?
    ) -> UUID? {
        guard let scope, let named = AddressedRequest.target(addressedIn: text, among: targets),
              named.id != targetID else { return nil }
        let request = AddressedRequest(endpointID: endpointID, thread: targetID, target: named, at: now(), scope: scope)
        addressed.append(request)
        if addressed.count > AddressedRequest.limit { addressed.removeFirst(addressed.count - AddressedRequest.limit) }
        return request.id
    }

    func retractAddress(_ id: UUID?) {
        addressed.removeAll { $0.id == id }
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

    /// A reply's text frame. The id matches `ReplyPresentation.id`, so the chat can show that reply's playback. A reply
    /// from another session shows in the `selected` thread, labelled, only while a request addressed to it from that
    /// thread is open (#636), and each address places one reply; any other stays in its own thread alone. Its
    /// placement is fixed at its first text.
    func noteReply(_ event: HostReplyEvent, selected: String? = nil, scope: String? = nil) {
        guard case .text(let payload) = event.frame.payload, let reply = payload.reply else { return }
        let id = "\(event.endpointID)|\(reply.id.uuidString.lowercased())"
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = payload.text
            return
        }
        var entry = ConversationEntry(
            id: id, speaker: .haili, text: payload.text,
            endpointID: event.endpointID, targetID: reply.targetID, date: now()
        )
        let cutoff = now().addingTimeInterval(-AddressedRequest.addressLifetime)
        addressed.removeAll { $0.at < cutoff }
        // One address places one reply: its first text takes the record, so a later reply from that session (its
        // later text frames update this entry in place above) stays in its own thread.
        if let selected, selected != reply.targetID, let index = addressed.lastIndex(where: {
            $0.endpointID == event.endpointID && $0.thread == selected && $0.target.id == reply.targetID
                && $0.scope == scope
        }) {
            (entry.shownIn, entry.source) = (selected, addressed.remove(at: index).target.name)
        }
        append(entry)
    }

    private func append(_ entry: ConversationEntry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
