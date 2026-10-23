/// Unheard cues stay in order until dismissed (#825), including repeated identical cues.
public struct AnnouncementBanners: Sendable {
    private var pending: [String] = []

    public init() {}

    public var current: String? { pending.first }
    public var pendingCount: Int { pending.count }

    public mutating func append(_ text: String) {
        pending.append(text)
        // Keep the five newest cues: a long unattended failure must not leave an unbounded backlog (#825).
        if pending.count > 5 { pending.removeFirst() }
    }

    public mutating func dismissCurrent() {
        if !pending.isEmpty { pending.removeFirst() }
    }
}
