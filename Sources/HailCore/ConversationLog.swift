// The chat's entries and every way one joins it (sent, overheard, reply, refusal, paste) stay in one model.
// swiftlint:disable file_length
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
    /// A reply from another session that answers a request the user addressed to it by name from the thread it
    /// arrived in (#636): that session's listed name, shown as the reply's label. Nil for every other entry.
    public var source: String?
    /// The thread such a reply shows in, besides its own. Nil otherwise.
    public var shownIn: String?
    /// The host refused one request and nothing was sent (any `ErrorCode.isRequestRefusal`, #608, #636): `text` is the
    /// host's own message, shown as a system line, never as a reply.
    public var notice = false
    /// Text the user pasted with this request (#608), shown as its own block; `text` may then be empty. Set only for
    /// the device's own sent turns, never from a host frame.
    public var pasted: String?
    /// The paste's state (#608): pending until a reply for this destination arrives or the Mac refuses it. The refusal's
    /// message is shown and announced once by `noteRefusal`; this state only marks the turn.
    public var pasteState: PasteState?

    public enum PasteState: Equatable, Sendable {
        case pending, delivered
        case refused(String)
    }

    /// Whether the entry shows in one destination's thread: its own target's entries, plus, with `addressed`, a reply
    /// that answers a request addressed from it to another session (`shownIn`). The one place a thread's membership
    /// is decided.
    public func belongs(endpointID: HostEndpoint.Identifier, targetID: String, addressed: Bool = false) -> Bool {
        self.endpointID == endpointID && (self.targetID == targetID || (addressed && shownIn == targetID))
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
    /// Which entry each recent address placed (address id to entry id), so a send that then fails can undo it.
    @ObservationIgnored private var placements: [(address: UUID, entry: String)] = []
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Entries for one destination, oldest first. With `addressed`, also replies to requests addressed from it to other
    /// sessions. The app opts in only together with showing their `source` label and tracking their arrival (#636
    /// slice 7b); until then its threads are unchanged, so no reply appears unlabelled where it did not before.
    public func entries(
        endpointID: HostEndpoint.Identifier, targetID: String, addressed: Bool = false
    ) -> [ConversationEntry] {
        entries.filter { $0.belongs(endpointID: endpointID, targetID: targetID, addressed: addressed) }
    }

    /// A request the user sent, or (#318) one the ambient stream heard and sent. When it opens with another listed
    /// session's name and a mark ("Deck, …"), that session's replies show in this thread for `addressLifetime`.
    /// `scope` binds the address to the connection and selection it was sent on; without one nothing is recorded.
    func noteSent(
        _ text: String, pasted: String? = nil, endpointID: HostEndpoint.Identifier, targetID: String,
        targets: [TargetInfo] = [], scope: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || pasted != nil else { return }
        var entry = ConversationEntry(
            id: "you|\(UUID().uuidString.lowercased())", speaker: .you, text: trimmed,
            endpointID: endpointID, targetID: targetID, date: now()
        )
        // A sent paste (#608) stays pending until a reply for this destination arrives or the Mac refuses it.
        entry.pasted = pasted
        entry.pasteState = pasted == nil ? nil : .pending
        append(entry)
        address(trimmed, endpointID: endpointID, targetID: targetID, targets: targets, scope: scope)
    }

    /// The Mac refused the latest pending paste for `endpointID` (#608); returns that turn. Refusals carry no request
    /// id, and the station sends one request per destination at a time, so the newest pending paste is the one. Only
    /// the turn's state changes: the refusal's line is `noteRefusal`'s.
    func notePasteRefused(_ message: String, endpointID: HostEndpoint.Identifier) -> (id: String, text: String)? {
        guard let index = entries.lastIndex(where: { $0.endpointID == endpointID && $0.pasteState == .pending }),
              let pasted = entries[index].pasted else { return nil }
        entries[index].pasteState = .refused(message)
        return (entries[index].id, pasted)
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

    /// Takes back an address whose send failed, and undoes any placement it already made: a reply that arrived
    /// during the send goes back to its own thread alone.
    func retractAddress(_ id: UUID?) {
        guard let id else { return }
        addressed.removeAll { $0.id == id }
        for placement in placements where placement.address == id {
            if let index = entries.firstIndex(where: { $0.id == placement.entry }) {
                (entries[index].shownIn, entries[index].source) = (nil, nil)
            }
        }
        placements.removeAll { $0.address == id }
    }

    /// A request the host refused, nothing sent (#608, #636): its message as a system line in the thread selected when
    /// the refusal arrived. The one place a refusal joins the chat, whatever its code.
    func noteRefusal(_ message: String, endpointID: HostEndpoint.Identifier, targetID: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entry = ConversationEntry(
            id: "notice|\(UUID().uuidString.lowercased())", speaker: .haili, text: trimmed,
            endpointID: endpointID, targetID: targetID, date: now()
        )
        entry.notice = true
        append(entry)
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
            entries[index].metadata = payload.metadata
            entries[index].spoken = reply.audioStreamID != nil
            return
        }
        // A reply from the destination means its pending pastes were taken (#608).
        for index in entries.indices where entries[index].pasteState == .pending
            && entries[index].endpointID == event.endpointID && entries[index].targetID == reply.targetID {
            entries[index].pasteState = .delivered
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
            let address = addressed.remove(at: index)
            (entry.shownIn, entry.source) = (selected, address.target.name)
            placements.append((address.id, entry.id))
            if placements.count > AddressedRequest.limit {
                placements.removeFirst(placements.count - AddressedRequest.limit)
            }
        }
        entry.metadata = payload.metadata
        entry.spoken = reply.audioStreamID != nil
        append(entry)
    }

    private func append(_ entry: ConversationEntry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
