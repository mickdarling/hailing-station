public import Foundation

/// RED STEP ONLY: main's rule, as `TranscriptionLabView.send` applies it. Replaced in the next commit.
public struct PasteHandoff: Equatable, Sendable {
    public private(set) var attached: PastedDraft?
    private var latest: UUID?
    private var carried: [UUID: PastedDraft] = [:]

    public init() {}

    public var isCarried: Bool { false }

    public mutating func attach(_ paste: PastedDraft?) { attached = paste }

    public mutating func take(for send: UUID) -> PastedDraft? {
        latest = send
        if let attached { carried[send] = attached }
        return attached
    }

    public mutating func finish(_ send: UUID, delivered: Bool) {
        guard let paste = carried.removeValue(forKey: send), send == latest else { return }
        if delivered, attached == paste { attached = nil }
    }

    public mutating func restore(_ paste: PastedDraft, refusing send: UUID) {
        attached = paste
        latest = nil
    }
}
