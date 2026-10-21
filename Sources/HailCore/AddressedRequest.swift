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

    /// The listed target `text` opens by addressing, by the host's own word rules: after an optional greeting, one to
    /// three plain words (ASCII letters, digits and apostrophes) separated by whitespace alone, spelling a target's
    /// listed name, then a mark and a space or the end. A word carrying a mark ends the search, so "Voice, Work, …"
    /// can address "Voice" but never "Voice Work"; a name that is not plain words, which no route can have, never
    /// matches. Nil for anything else.
    static func target(addressedIn text: String, among targets: [TargetInfo]) -> TargetInfo? {
        for mark in text.indices where marks.contains(text[mark])
            && text[text.index(after: mark)...].first?.isWhitespace ?? true {
            var words = text[..<mark].split(whereSeparator: \.isWhitespace)
            if let first = words.first, greetings.contains(key(first)) { words.removeFirst() }
            guard (1...3).contains(words.count), words.allSatisfy(isPlainWord) else { continue }
            let spoken = words.map(key).joined()
            if let target = targets.first(where: { name(of: $0) == spoken }) { return target }
        }
        return nil
    }

    /// A target's name as one key, or nil unless it is one to three plain words.
    private static func name(of target: TargetInfo) -> String? {
        let words = target.name.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count), words.allSatisfy(isPlainWord) else { return nil }
        return words.map(key).joined()
    }

    private static func isPlainWord(_ word: Substring) -> Bool {
        word.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "'" }
    }

    private static func key(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
}
