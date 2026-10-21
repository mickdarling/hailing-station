/// Each conversation message's link parsing, memoised per entry and text (#641 review). The chat lays out every row
/// (up to the log's 200) on each update, and a streaming reply updates often; without this every row re-ran the link
/// regex and data detector each time. A message whose text changed is parsed again; one that did not is not. It only
/// saves work: what a row shows is exactly `MessageLinks.segments` of its current text.
@MainActor
public final class MessageSegmentCache {
    private struct Parsed {
        let text: String
        let segments: [MessageSegment]
    }

    private var parsed: [String: Parsed] = [:]
    /// How many times a text was actually parsed, for tests.
    public private(set) var parses = 0

    public init() {}

    public func segments(for entry: ConversationEntry) -> [MessageSegment] {
        if let cached = parsed[entry.id], cached.text == entry.text { return cached.segments }
        // Bounded: past twice the log's limit, entries long gone are dropped and the visible ones parsed again.
        if parsed.count >= 2 * ConversationLog.limit { parsed.removeAll(keepingCapacity: true) }
        let segments = MessageLinks.segments(entry.text)
        parsed[entry.id] = Parsed(text: entry.text, segments: segments)
        parses += 1
        return segments
    }
}
