#if os(macOS)
import Foundation

/// FIFO metadata beside each PCM item; no-gap Data keeps its original storage. O(1) amortised removal.
struct RightyoPrefixedQueue {
    struct Item {
        let epoch: Int
        let data: Data
        let at: UInt64
        let silence: Int
    }
    private var items: [Item?] = [], head = 0
    private var prefixes: [Int: Int] = [:]
    var silenceAllowance: Int { prefixes.keys.max() ?? 0 } // At most 30 whole-slice prefix sizes.
    var isEmpty: Bool { head == items.count }
    var first: Item? { isEmpty ? nil : items[head] }
    mutating func append(_ item: Item) {
        items.append(item)
        if item.silence > 0 { prefixes[item.silence, default: 0] += 1 }
    }
    mutating func removeFirst() -> Item {
        guard let item = items[head] else { preconditionFailure("stdin slot already taken") }
        if item.silence > 0 {
            let remaining = (prefixes[item.silence] ?? 1) - 1
            prefixes[item.silence] = remaining == 0 ? nil : remaining
        }
        (items[head], head) = (nil, head + 1)
        if isEmpty { items.removeAll(keepingCapacity: true); head = 0 } else if head >= items.count - head {
            items.removeFirst(head); head = 0
        }
        return item
    }
}

/// Host duration pinned to AmbientAudioFormat.chunkBytes by the cross-module format test.
struct AmbientGapFill: Sendable, Equatable {
    static let chunkBytes = 3_200
    static let maxSegments = 30
    static let maxBytes = chunkBytes * maxSegments
    let missing: Int
    let segments: Int
    var bytes: Int { segments * Self.chunkBytes }
    var detail: String {
        "missing=\(missing) filled_ms=\(segments * 100) capped=\(segments < missing)"
    }

    init?(after last: Int?, sequence: Int, budget: Duration) {
        guard let last, last >= 0, sequence > last, sequence - last > 1 else { return nil }
        missing = sequence - last - 1
        let available = max(.zero, min(.seconds(3), budget)).components
        // Integer floor, never ceil: even a tiny positive elapsed time cannot buy a 100 ms slice.
        let slices = Int(available.seconds * 10 + available.attoseconds / 100_000_000_000_000_000)
        segments = min(missing, slices)
    }
}

#endif
