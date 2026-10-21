#if os(macOS)
import Foundation

extension VoiceRoutes {
    /// What a request's opening words say about where it goes.
    public enum Match: Sendable, Equatable {
        /// No route was named: the request goes, unchanged, to the target already chosen.
        case unaddressed
        /// A route was named: the request goes to it. `text` is the words after the name, as said.
        case routed(Route, text: String)
        /// A route was named with nothing after it, so there is nothing to send.
        case nothingToSay(Route)
        /// The opening words sound like a route's name but are none of its spellings. Nothing is sent, so a
        /// misheard name never lands in the wrong session.
        case unclear
    }

    /// The marks that make a name an address: "Voice Work, …", "Deck: …", "Deck - …". Each must be followed by a
    /// space or the end, so "Deck-building …" stays a request.
    static let marks: Set<Character> = [",", ":", "-"]

    /// Where `heard` goes. After an optional greeting ("hey", "ok"), the request must open with a route's name or
    /// alias (longest first, up to three words) followed by one of `marks`. Without the mark, a name is just a
    /// word: "Deck is still stopped" or "Sales are slow" stay requests. A name with nothing after it, at most a
    /// final ".", "?" or "!", has nothing to say. A request opening with an addressing name from `names` (keyed,
    /// as `RightyoAddressing.key`, e.g. "jarvis") that is not itself a route's spelling is addressed to that name
    /// and is never re-routed or called unclear, whatever follows: "Jarvis, Deck, …" goes where "Jarvis" goes.
    /// A near miss of a route's name counts only when a comma follows it, so ordinary openings such as
    /// "Check, …" stay requests.
    public func match(_ heard: String, names: Set<String> = []) -> Match {
        let words = VoiceDestinations.words(heard)
        let start = words.first.map { VoiceMute.greetings.contains($0.text) } == true ? 1 : 0
        if let found = named(heard, words, at: start) { return found }
        let addressed = (1...3).contains { width in
            Self.windowKey(heard, words, start, width).map(names.contains) == true
        }
        return !addressed && nearMiss(heard, words, at: start) ? .unclear : .unaddressed
    }

    /// The route addressed by the words at `start`, and what follows it; nil when no spelling starts there or the
    /// spelling found is not followed by a mark or the end.
    private func named(_ heard: String, _ words: [VoiceDestinations.Word], at start: Int) -> Match? {
        for width in stride(from: 3, through: 1, by: -1) where start + width <= words.count {
            guard let route = Self.windowKey(heard, words, start, width).flatMap({ keyed[$0] }) else { continue }
            let rest = heard[words[start + width - 1].range.upperBound...].drop { $0.isWhitespace }
            if let mark = rest.first, Self.marks.contains(mark), rest.dropFirst().first?.isWhitespace ?? true {
                let text = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? .nothingToSay(route) : .routed(route, text: text)
            }
            return rest.allSatisfy { $0.isWhitespace || ".?!".contains($0) } ? .nothingToSay(route) : nil
        }
        return nil
    }

    /// Whether one to three words at `start`, followed directly by a comma, are within a small edit distance of a
    /// route's spelling: one edit for every four letters, and only for spellings of at least five letters (a short
    /// name's misrecognitions, such as "Duck" for "Deck", belong in its aliases).
    private func nearMiss(_ heard: String, _ words: [VoiceDestinations.Word], at start: Int) -> Bool {
        (1...3).contains { width in
            guard start + width <= words.count else { return false }
            let end = words[start + width - 1].range.upperBound
            guard end < heard.endIndex, heard[end] == "," else { return false }
            guard let spoken = Self.windowKey(heard, words, start, width) else { return false }
            return keyed.keys.contains { key in
                key.count >= 5 && Self.distance(spoken, key, within: key.count / 4) <= key.count / 4
            }
        }
    }

    /// The joined key of `width` words at `start`, or nil past the end or when the words are not separated by
    /// whitespace alone: a window never crosses a mark, so "Voice, Work, …" is "Voice" addressed, never "Voice Work".
    static func windowKey(_ heard: String, _ words: [VoiceDestinations.Word], _ start: Int, _ width: Int) -> String? {
        guard start + width <= words.count else { return nil }
        let window = words[start..<start + width]
        for (left, right) in zip(window, window.dropFirst())
        where !heard[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace) {
            return nil
        }
        return window.map(\.key).joined()
    }

    /// Levenshtein distance between two keys, stopping early once it exceeds `limit` (then any larger value).
    static func distance(_ lhs: String, _ rhs: String, within limit: Int) -> Int {
        let left = Array(lhs), right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }
        var previous = Array(0...right.count)
        for (row, character) in left.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: right.count)
            for column in right.indices {
                let substitution = previous[column] + (character == right[column] ? 0 : 1)
                current[column + 1] = min(substitution, previous[column + 1] + 1, current[column] + 1)
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }
}
#endif
