import Foundation
import HailProtocol

/// A request the user addressed by name to another listed session from one thread (#636), so that session's reply
/// can show in that thread too. The host decides where a request goes; this only places the reply in the chat, and
/// a reply nobody addressed stays in its own thread. Only a route's reply can reach a device selecting another
/// target at all (the host's reply rules), so an address never places a reply the host did not route here.
struct AddressedRequest: Sendable {
    /// As long as the host keeps a routed request's claim on its reply (its last-input lifetime, #370).
    static let addressLifetime: TimeInterval = 600
    static let limit = 16
    /// Words the host skips before a session's name, as it does.
    static let greetings: Set<String> = ["hey", "ok", "okay"]
    /// Marks after a name that make it an address, as on the host: "Deck, …", "Deck: …", "Deck - …".
    static let marks: Set<Character> = [",", ":", "-"]

    let id = UUID()
    let endpointID: HostEndpoint.Identifier
    let thread: String
    let target: TargetInfo
    let at: Date
    /// The connection and selection it was sent on (`HostConnectionStore.addressScope`). The host retires its reply
    /// claim on any reselection or reconnect, so a reply under another scope never matches.
    let scope: String

    /// The listed target `text` opens by addressing, by the host's own rules (`VoiceRoutes.match`): after an optional
    /// greeting, the longest run of one to three words that spells a target's listed name, then a mark and a space or
    /// the end. Words are runs of letters, digits and apostrophes keyed as the host keys them (case-folded ASCII
    /// letters and digits); a run counts only when its words are separated by whitespace alone and each keys to
    /// something. So "Voice, Work, …" can address "Voice" but never "Voice Work", and "DECK!" is the name "Deck".
    /// Nil for anything else, including a name with nothing after it.
    static func target(addressedIn text: String, among targets: [TargetInfo]) -> TargetInfo? {
        let words = words(text)
        let start = words.first.map { greetings.contains($0.key) } == true ? 1 : 0
        for width in stride(from: 3, through: 1, by: -1) where start + width <= words.count {
            let window = words[start..<start + width]
            guard let spoken = key(text, window), let last = window.last,
                  let target = targets.first(where: { name(of: $0) == spoken }) else { continue }
            let rest = text[last.range.upperBound...].drop { $0.isWhitespace }
            guard let mark = rest.first, marks.contains(mark), rest.dropFirst().first?.isWhitespace ?? true else {
                return nil
            }
            return target
        }
        return nil
    }

    private struct Word {
        let key: String
        let range: Range<String.Index>
    }

    /// A target's listed name as one key, by the same rules; nil when the host could never hear it.
    private static func name(of target: TargetInfo) -> String? {
        let words = words(target.name)
        return (1...3).contains(words.count) ? key(target.name, words[...]) : nil
    }

    /// The window's joined key, or nil when a word keys to nothing or a gap between its words is not whitespace.
    private static func key(_ text: String, _ window: ArraySlice<Word>) -> String? {
        guard window.allSatisfy({ !$0.key.isEmpty }) else { return nil }
        for (left, right) in zip(window, window.dropFirst())
        where !text[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace) {
            return nil
        }
        return window.map(\.key).joined()
    }

    /// Runs of letters, digits and apostrophes in `text`, each keyed, with where it sits.
    private static func words(_ text: String) -> [Word] {
        var found: [Word] = [], start: String.Index?
        for index in text.indices + [text.endIndex] {
            let character = index < text.endIndex ? text[index] : " "
            let inWord = character.isLetter || character.isNumber || character == "'"
            if inWord, start == nil { start = index }
            if !inWord, let begin = start {
                let key = String(text[begin..<index].lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
                found.append(Word(key: key, range: begin..<index))
                start = nil
            }
        }
        return found
    }
}
