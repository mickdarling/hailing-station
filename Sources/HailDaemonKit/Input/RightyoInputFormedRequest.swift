import Foundation
/// Formed requests (#188 item 4). A producer that advertises `request_forming` at `started` puts a natural-language
/// `formed_request` on every request of that session; it becomes the prompt body and the diarized turns ride
/// behind it as the same compact JSON as before, so the receiving session still sees who said what. The formed
/// text is descriptive producer data like roles: it never selects a target or bypasses policy, tiers or guards.
extension RightyoInputEvent {
    /// `{"kind": "<allowlisted>"}` and nothing else; a record with any other key fails to decode (fail closed).
    struct RequestForming: Codable, Sendable {
        static let kinds: Set<String> = ["template"]
        let kind: String
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: RightyoInputKey.self)
            guard container.allKeys.map(\.stringValue) == ["kind"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "request_forming: keys other than kind"))
            }
            kind = try container.decode(String.self, forKey: RightyoInputKey(stringValue: "kind"))
        }
    }
    /// The formed text rides only on `request` events as one sanitizer-stable line of 1...16,000 characters
    /// (64,000 UTF-8 bytes, the same 4:1 ratio as turn text, so combining marks cannot inflate it); every
    /// sanitizer refusal is `invalidEvent`. `request_forming` rides only on the `started` session event with an
    /// allowlisted `kind`. Whether a request must or must not carry the text is the consumer's rule, decided by
    /// what the session advertised.
    func validateFormed() throws {
        if let requestForming {
            guard type == "session", phase == "started", RequestForming.kinds.contains(requestForming.kind) else {
                throw RightyoInputError.invalidEvent
            }
        }
        guard let formedRequest else { return }
        let policy = SanitizePolicy(maxCharacters: 16_000, maxUTF8Bytes: 64_000)
        guard type == "request", !formedRequest.isEmpty, formedRequest.count <= 16_000,
              !formedRequest.contains(Self.rawTurnsMarker),
              (try? Sanitizer.sanitize(formedRequest, policy: policy)) == [formedRequest] else {
            throw RightyoInputError.invalidEvent
        }
    }
    /// Separates the formed body from the raw turns on one line: the host sanitizer refuses line breaks, so a
    /// blank-line layout could never be delivered. A formed text containing this exact substring is refused, so the
    /// first occurrence in a delivered prompt is always the host's and the producer cannot impersonate the record.
    static let rawTurnsMarker = " Raw turns (JSON, admitted record): "
    /// `speakers` is the advertised capability (`anonymous` or `enrolled`) so the session can weigh roles. Without a
    /// formed request the prompt is the compact JSON alone, byte for byte as before; with one it is
    /// `<formed_request><rawTurnsMarker><json>`, so the JSON can be cut off at the marker and parsed as a whole.
    /// The host cannot check the formed text against the admitted turns and roles; it is the producer's unverified
    /// claim, and the JSON is the admitted record the session should trust when the two disagree.
    func prompt(speakers: String) throws -> String {
        struct Prompt: Encodable {
            let requestId: String?
            let speakers: String
            let request: Turn?
            let decision: Decision?
            let context: Context?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Prompt(requestId: requestId, speakers: speakers, request: turn,
                                             decision: decision, context: context))
        guard let json = String(data: data, encoding: .utf8) else { throw RightyoInputError.invalidEvent }
        guard let formedRequest else { return json }
        return formedRequest + Self.rawTurnsMarker + json
    }
}
/// Every key a keyed container carries (already converted from snake case), for strict no-extra-keys decoding.
private struct RightyoInputKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
