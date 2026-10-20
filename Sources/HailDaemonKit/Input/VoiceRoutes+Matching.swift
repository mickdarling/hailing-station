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

    /// Marks that may follow a name: "Voice Work, …", "Deck: …", "Deck - …".
    static let separators = ",:;.!?-"

    /// Where `heard` goes. After an optional greeting ("hey", "ok") and an optional addressing name from `names`
    /// (keyed, as `RightyoAddressing.key`, e.g. "jarvis"), a route's name or alias, longest first and up to three
    /// words, must end at a space or the end, after any separators ("Deck: …", but not "deck.md"). A route's own
    /// spelling is tried before an addressing name, so a route may share a spelling with one. A near miss of a
    /// route's name counts only when a comma follows it, so ordinary openings such as "Check, …" stay requests.
    public func match(_ heard: String, names: Set<String> = []) -> Match {
        let words = VoiceDestinations.words(heard)
        var index = 0
        if index < words.count, VoiceMute.greetings.contains(words[index].text) { index += 1 }
        if let found = named(heard, words, at: index) { return found }
        if let width = (1...3).first(where: { width in
            index + width < words.count && names.contains(words[index..<index + width].map(\.key).joined())
        }) {
            index += width
            if let found = named(heard, words, at: index) { return found }
        }
        return nearMiss(heard, words, at: index) ? .unclear : .unaddressed
    }

    /// The route spelled by the words at `start`, and what follows it; nil when no spelling starts there.
    private func named(_ heard: String, _ words: [VoiceDestinations.Word], at start: Int) -> Match? {
        for width in stride(from: 3, through: 1, by: -1) where start + width <= words.count {
            guard let route = keyed[words[start..<start + width].map(\.key).joined()] else { continue }
            let end = words[start + width - 1].range.upperBound
            let after = heard[end...].drop { Self.separators.contains($0) }
            guard after.first?.isWhitespace ?? true else { return nil }
            let text = heard[end...].drop { $0.isWhitespace || Self.separators.contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .nothingToSay(route) : .routed(route, text: text)
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
            let spoken = words[start..<start + width].map(\.key).joined()
            return keyed.keys.contains { key in
                key.count >= 5 && Self.distance(spoken, key, within: key.count / 4) <= key.count / 4
            }
        }
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
