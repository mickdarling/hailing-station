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
              !Self.carriesMarker(formedRequest),
              (try? Sanitizer.sanitize(formedRequest, policy: policy)) == [formedRequest] else {
            throw RightyoInputError.invalidEvent
        }
    }
    /// Separates the formed body from the raw turns on one line: the host sanitizer refuses line breaks, so a
    /// blank-line layout could never be delivered. A formed text that carries this substring, or ends in it minus
    /// its trailing space, is refused (`carriesMarker`), so the first literal occurrence in a delivered prompt is
    /// the host's and the producer cannot impersonate the record.
    static let rawTurnsMarker = " Raw turns (JSON, admitted record): "
    /// Literal code-unit search, not grapheme search: a combining mark right after the marker would hide it from
    /// `contains`. The suffix rule covers a text ending in the marker minus its trailing space, which the host's
    /// leading space would otherwise complete one character early.
    static func carriesMarker(_ text: String) -> Bool {
        text.range(of: rawTurnsMarker, options: .literal) != nil
            || text.range(of: String(rawTurnsMarker.dropLast()), options: [.literal, .backwards, .anchored]) != nil
    }
    /// Tells the receiving session how to answer so the phone hears it (#188 item 1). Appended last to both
    /// layouts, after the JSON, so the session cuts the prompt at the LAST occurrence of `replyBlockPrefix`:
    /// producer text before it may repeat these words, but nothing follows the host's block. The reply request
    /// id is minted by the daemon after this text is formed, so the block points at the `request` field of the
    /// `BridgeRequest` envelope the pane receives rather than embedding it; a legacy adapter delivers no
    /// envelope, and there the request-less shape reaches a phone only under the single-terminal fallback.
    /// ASCII, one line, never the marker, deterministic: `target` (the listed id the binding was pinned from)
    /// is its only variable part and appears twice.
    static let replyBlockPrefix = " Reply: run haild reply "
    static func replyBlock(target: String) -> String {
        replyBlockPrefix + target + " --request <request id from this envelope> --say \"<spoken answer>\""
            + " (or --text); without an envelope request id run haild reply " + target
            + " --say \"<spoken answer>\" (single-terminal fallback only)."
    }
    /// `speakers` is the advertised capability (`anonymous` or `enrolled`) so the session can weigh roles. Without a
    /// formed request the body is the compact JSON alone, byte for byte as before; with one it is
    /// `<formed_request><rawTurnsMarker><json>`, so the JSON can be cut off at the marker and parsed as a whole.
    /// Either body is followed by `replyBlock(target:)`. The host cannot check the formed text against the
    /// admitted turns and roles; it is the producer's unverified claim, and the JSON is the admitted record the
    /// session should trust when the two disagree.
    func prompt(speakers: String, target: String) throws -> String {
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
        let body = formedRequest.map { $0 + Self.rawTurnsMarker + json } ?? json
        return body + Self.replyBlock(target: target)
    }
}
/// Every key a keyed container carries (already converted from snake case), for strict no-extra-keys decoding.
private struct RightyoInputKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
/// An optional field that may be absent but never an explicit `null` (fail closed). Synthesized `Optional` decoding
/// collapses `null` to `nil`, so `request_forming: null` would silently select legacy prompting and
/// `formed_request: null` would pass on kinds where the field is forbidden; this wrapper refuses the null instead.
/// Absent keys stay absent on both sides (the keyed-container overloads below), so fingerprints are unchanged.
@propertyWrapper
struct RefusingNull<Value: Codable & Sendable>: Codable, Sendable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil() else {
            throw DecodingError.valueNotFound(Value.self, .init(codingPath: decoder.codingPath,
                                                                debugDescription: "explicit null is refused"))
        }
        wrappedValue = try container.decode(Value.self)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}
extension KeyedDecodingContainer {
    func decode<Value>(_: RefusingNull<Value>.Type, forKey key: Key) throws -> RefusingNull<Value> {
        guard contains(key) else { return RefusingNull(wrappedValue: nil) }
        return try RefusingNull(from: superDecoder(forKey: key))
    }
}
extension KeyedEncodingContainer {
    mutating func encode<Value>(_ value: RefusingNull<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}
