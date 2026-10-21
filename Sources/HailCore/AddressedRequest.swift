import Foundation
import HailProtocol

/// A request the user addressed by name to another listed session from one thread (#636), so that session's reply
/// can show in that thread too. The host decides where a request goes; this only places the reply in the chat, and
/// a reply nobody addressed stays in its own thread.
struct AddressedRequest: Sendable {
    /// As long as the host keeps a routed request's claim on its reply (its last-input lifetime, #370).
    static let addressLifetime: TimeInterval = 600
    static let limit = 16
    /// Words the host skips before a session's name, as it does.
    static let greetings: Set<String> = ["hey", "ok", "okay"]
    /// Marks after a name that make it an address, as on the host: "Deck, …", "Deck: …", "Deck - …".
    static let marks: Set<Character> = [",", ":", "-"]

    let endpointID: HostEndpoint.Identifier
    let thread: String
    let target: TargetInfo
    let at: Date

    /// The listed target `text` opens by addressing: after an optional greeting, a target's listed name (letters
    /// and digits, case-folded) followed by a mark and then a space or the end. Nil for anything else.
    static func target(addressedIn text: String, among targets: [TargetInfo]) -> TargetInfo? {
        guard let mark = text.firstIndex(where: { marks.contains($0) }),
              text[text.index(after: mark)...].first?.isWhitespace ?? true else { return nil }
        var words = text[..<mark].split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        if let first = words.first, greetings.contains(first) { words.removeFirst() }
        let spoken = words.joined()
        guard !spoken.isEmpty else { return nil }
        return targets.first { key($0.name) == spoken }
    }

    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }
}
