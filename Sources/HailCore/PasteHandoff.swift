public import Foundation

/// Who holds the station's paste (#608): attached for the next request, or carried by a send whose write has not
/// returned. A reply placed while that write is still going (#636) ends the send's wait, so Talk and Send Paste come
/// back early; the paste in flight must not go a second time, and it is cleared when its write returns, whatever the
/// station did in between. Each attachment has its own identity, so the same text attached again is a new paste.
public struct PasteHandoff: Equatable, Sendable {
    private var attachment: (id: UUID, paste: PastedDraft)?
    private var carried: [UUID: UUID] = [:]

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.attachment?.id == rhs.attachment?.id && lhs.carried == rhs.carried
    }

    public var attached: PastedDraft? { attachment?.paste }

    /// The attached paste is already on its way with a send whose write has not returned.
    public var isCarried: Bool { attachment.map { carried.values.contains($0.id) } ?? false }

    /// Attaches a new paste, or removes the attached one with nil.
    public mutating func attach(_ paste: PastedDraft?) { attachment = paste.map { (UUID(), $0) } }

    /// The paste a new send carries: the attached one, unless a send still being written already carries it.
    public mutating func take(for send: UUID) -> PastedDraft? {
        guard let attachment, !isCarried else { return nil }
        carried[send] = attachment.id
        return attachment.paste
    }

    /// The send's write returned. Delivered, the paste it carried went with it; failed, it stays for the next request.
    public mutating func finish(_ send: UUID, delivered: Bool) {
        guard let id = carried.removeValue(forKey: send), delivered, attachment?.id == id else { return }
        attachment = nil
    }

    /// The Mac refused the paste that `send` carried: it comes back attached, and that send no longer carries it.
    public mutating func restore(_ paste: PastedDraft, refusing send: UUID) {
        carried[send] = nil
        attach(paste)
    }
}
