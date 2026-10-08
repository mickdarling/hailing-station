import CryptoKit
public import Foundation
import HailProtocol
// The event shape and its dismissal rules (rightyo#98) form one review boundary within the four-file budget.
// swiftlint:disable file_length
public enum RightyoInputError: Error, Sendable, Equatable {
    case invalidEvent, invalidLifecycle, sequenceGap, capacity, unavailableBinding, confirmationRequired, producerFailed
}
/// Finalized-turn, host-local input only (#183). JSONL is not an authenticated remote transport.
public struct RightyoInputEvent: Codable, Sendable {
    public struct Turn: Codable, Sendable {
        let sessionId: String
        let utteranceId: String
        let revision: Int
        let startMs: Int, endMs: Int
        let text: String
        let speakerId: String?
        let finalized: Bool
        let overlap: Bool
        let recognizerId: String
        let provenance: String, speakerProvenance: String
        /// Enrolled-speaker role (#188). Descriptive data for the prompt; it never bypasses policy.
        let role: String?
    }
    struct Decision: Codable, Sendable {
        let label: String
        let recipientKind: String
        let confidence: Double
        let provider: String
        let model: String
        let role: String?
    }
    struct Retention: Codable, Sendable {
        let retentionMs: Int?, maxTurns: Int?, maxBytes: Int?, expiredTurns: Int?, capacityEvictedTurns: Int?
        let cutoffMs: Int?, nowMs: Int?, oldestStartMs: Int?, newestEndMs: Int?
        let boundaryOverlapMs: Int?, boundaryPolicy: String?
        let turnCount: Int?, sessionTurnCount: Int?, maxSessionTurns: Int?, retainedBytes: Int?
    }
    struct Context: Codable, Sendable { let turns: [Turn]; let retention: Retention? }
    struct Capabilities: Codable, Sendable {
        let activation: String
        let partials: Bool
        let speakers: String
        let context: Bool
    }
    let schemaVersion: Int
    let type: String
    let sessionId: String
    let sequence: Int
    let emittedAtMs: Int
    let utteranceId: String?
    let phase: String?
    let capabilities: Capabilities?
    /// Request forming (#188 item 4): advertised once at `started`, then `formed_request` is the prompt body on
    /// every request of that session and on nothing else. Rules and layout: RightyoInputFormedRequest.swift.
    @RefusingNull var requestForming: RequestForming?
    @RefusingNull var formedRequest: String?
    let requestId: String?
    let turn: Turn?
    let decision: Decision?
    let context: Context?
    let decisionAtMs: Int?
    /// Owner `override` fields (#188 item 3): the request this owner utterance supersedes. Public so the CLI
    /// can print the receipt; never transcript content.
    public let supersededRequestId: String?
    let byUtteranceId: String?
    /// `override` and `dismiss` only: the speaker's role, by the same rules as a turn's.
    let role: String?
    /// The names `started` advertises (rightyo#105), kept as raw JSON so a malformed list never refuses the stream;
    /// only the acknowledgement voice reads it, through `RightyoAddressing`'s bounded, lenient parse.
    let addressing: JSONValue?
    /// Natural dismissal (rightyo#98): advertised once at `started`; only then may `dismiss` events arrive.
    @RefusingNull var dismissal: Dismissal?
    /// `dismiss` fields. `speech_end_ms` also rides on `attention`, and `reason` on terminal session events.
    let speechEndMs: Int?
    let speakerId: String?
    let scope: [String]?
    let withdrawnRequestIds: [String]?
    let reason: String?
    let confidence: Double?
    let cooldownUntilMs: Int?
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 1_200_000 else { throw RightyoInputError.capacity }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Self.self, from: data) } catch { throw RightyoInputError.invalidEvent }
    }
    /// Stream time has no default ceiling for ambient listening (#188); `Int` decoding already rejects values
    /// past Int64 and `budgetMs` is the caller's optional explicit limit.
    func validate(session: String, enrolled: Bool, budgetMs: Int? = nil) throws {
        guard schemaVersion == 1, sessionId == session, sequence > 0, emittedAtMs >= 0,
              emittedAtMs <= budgetMs ?? Int.max,
              ["session", "transcript", "attention", "request", "override", "dismiss"].contains(type) else {
            throw RightyoInputError.invalidEvent
        }
        try validateOverride(session: session, enrolled: enrolled)
        try validateDismiss(session: session, enrolled: enrolled)
        try validateFormed()
        if let turn { try validate(turn, session: session, enrolled: enrolled) }
        if let decision {
            guard decision.confidence.isFinite, (0...1).contains(decision.confidence),
                  Self.identifier(decision.provider), Self.identifier(decision.model),
                  ["attend", "ignore", "uncertain"].contains(decision.label),
                  ["system", "other_human", "unknown", "known_speaker"].contains(decision.recipientKind),
                  Self.role(decision.role, enrolled: enrolled) else {
                throw RightyoInputError.invalidEvent
            }
        }
        if type == "transcript", turn == nil { throw RightyoInputError.invalidEvent }
        guard type == "request" else { return }
        guard let turn, let context, let decision, let decisionAtMs,
              decision.label == "attend", decision.recipientKind == "system",
              requestId == "\(session):\(turn.utteranceId)",
              decisionAtMs >= turn.endMs, decisionAtMs <= emittedAtMs,
              context.turns.count <= 1000 else { throw RightyoInputError.invalidEvent }
        var identities = Set<String>()
        var previousEnd = 0
        for prior in context.turns {
            try validate(prior, session: session, enrolled: enrolled)
            guard prior.endMs <= turn.startMs, prior.endMs >= previousEnd,
                  prior.utteranceId != turn.utteranceId,
                  identities.insert(prior.utteranceId).inserted else { throw RightyoInputError.invalidEvent }
            previousEnd = prior.endMs
        }
        guard try JSONEncoder().encode(context).count <= 1_048_576 else { throw RightyoInputError.capacity }
    }
    /// Only an enrolled session's owner may supersede a request, and the superseded id must carry this
    /// session's `session:utterance` shape. Other event kinds may not carry override fields (fail closed); `role`
    /// also rides on `dismiss`, which checks it itself.
    private func validateOverride(session: String, enrolled: Bool) throws {
        guard type == "override" else {
            guard supersededRequestId == nil, byUtteranceId == nil, role == nil || type == "dismiss" else {
                throw RightyoInputError.invalidEvent
            }
            return
        }
        guard enrolled, role == "owner", let supersededRequestId, let byUtteranceId,
              Self.identifier(byUtteranceId), Self.requestID(supersededRequestId, session: session) else {
            throw RightyoInputError.invalidEvent
        }
    }
    /// This session's `session:utterance` request id shape.
    static func requestID(_ value: String, session: String) -> Bool {
        value.hasPrefix("\(session):") && identifier(String(value.dropFirst(session.count + 1)))
    }
    private func validate(_ turn: Turn, session: String, enrolled: Bool) throws {
        guard turn.sessionId == session, Self.identifier(turn.sessionId), Self.identifier(turn.utteranceId),
              turn.revision > 0, turn.finalized, turn.startMs >= 0, turn.endMs >= turn.startMs,
              turn.endMs <= emittedAtMs, !turn.text.isEmpty, turn.text.count <= 4000,
              Self.identifier(turn.recognizerId), turn.speakerId.map(Self.identifier) ?? true,
              Self.role(turn.role, enrolled: enrolled),
              ["synthetic", "recorded-file", "causal-replay", "live-microphone"].contains(turn.provenance),
              ["authored-fixture", "diarization-timeline", "diarization-utterance", "unknown"]
                .contains(turn.speakerProvenance) else {
            throw RightyoInputError.invalidEvent
        }
        guard try Sanitizer.sanitize(turn.text, policy: .init(maxCharacters: 4000, maxUTF8Bytes: 16_000)) == [turn.text]
        else { throw RightyoInputError.invalidEvent }
    }
    /// Anonymous sessions may only say `unknown`; enrolled sessions may name a role. Absent is always allowed.
    static func role(_ value: String?, enrolled: Bool) -> Bool {
        guard let value else { return true }
        return enrolled ? ["owner", "trusted", "participant", "unknown"].contains(value) : value == "unknown"
    }
    static func identifier(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_. -")
        return (1...96).contains(value.count) && value.allSatisfy(allowed.contains)
    }
    static func fingerprint<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
}
/// Natural dismissal (rightyo#98, RightyO `docs/tool-api.md` "Natural dismissal and barge-in"). A producer that
/// advertises `dismissal` version 1 at `started` may emit `dismiss`: the speaker told the assistant to stop, go
/// away, or that it was not addressed. Without the advertisement `dismiss` is refused as before. A dismissal only
/// ever withholds or stops host action; it never delivers anything or grants authority.
extension RightyoInputEvent {
    /// `{"version": 1, "window_ms", "cooldown_ms", "cooldown_min_confidence"}` with the producer's documented
    /// ranges and nothing else; any other key, or another version, fails to decode (fail closed).
    struct Dismissal: Codable, Sendable, Equatable {
        static let keys: Set<String> = ["version", "windowMs", "cooldownMs", "cooldownMinConfidence"]
        let version: Int
        let windowMs: Int
        let cooldownMs: Int
        let cooldownMinConfidence: Double
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DismissalKey.self)
            guard Set(container.allKeys.map(\.stringValue)) == Self.keys else { throw Self.refusal(decoder) }
            version = try container.decode(Int.self, forKey: DismissalKey(stringValue: "version"))
            windowMs = try container.decode(Int.self, forKey: DismissalKey(stringValue: "windowMs"))
            cooldownMs = try container.decode(Int.self, forKey: DismissalKey(stringValue: "cooldownMs"))
            cooldownMinConfidence = try container.decode(Double.self,
                                                         forKey: DismissalKey(stringValue: "cooldownMinConfidence"))
            guard version == 1, (1...60_000).contains(windowMs), (0...600_000).contains(cooldownMs),
                  cooldownMinConfidence.isFinite, (0...1).contains(cooldownMinConfidence) else {
                throw Self.refusal(decoder)
            }
        }
        private static func refusal(_ decoder: any Decoder) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "dismissal: unsupported object"))
        }
    }
    static let dismissScopes: Set<String> = ["playback", "pending_request", "engagement"]
    /// RightyO keeps at most 32 delivered requests withdrawable; a pending withdrawal names one id.
    static let maxWithdrawnIDs = 32

    /// `dismissal` rides only on `started`; the `dismiss`-only fields ride only on `dismiss`. Whether a `dismiss`
    /// may arrive at all is the consumer's rule, decided by what the session advertised.
    func validateDismiss(session: String, enrolled: Bool) throws {
        if dismissal != nil, type != "session" || phase != "started" { throw RightyoInputError.invalidEvent }
        guard type == "dismiss" else {
            guard scope == nil, withdrawnRequestIds == nil, cooldownUntilMs == nil else {
                throw RightyoInputError.invalidEvent
            }
            return
        }
        guard let utteranceId, Self.identifier(utteranceId), let speechEndMs, speechEndMs >= 0,
              speechEndMs <= emittedAtMs, speakerId.map(Self.identifier) ?? true, Self.role(role, enrolled: enrolled),
              turn == nil, decision == nil, context == nil, requestId == nil, decisionAtMs == nil, phase == nil,
              capabilities == nil, validDismissScope, validDismissReason,
              let ids = withdrawnRequestIds, ids.count <= Self.maxWithdrawnIDs, Set(ids).count == ids.count,
              ids.allSatisfy({ Self.requestID($0, session: session) }) else {
            throw RightyoInputError.invalidEvent
        }
    }
    /// A non-empty set of known scopes; a cool-down only comes with `engagement` and ends after the speech.
    private var validDismissScope: Bool {
        guard let scope, !scope.isEmpty, Set(scope).count == scope.count,
              scope.allSatisfy(Self.dismissScopes.contains) else { return false }
        guard let cooldownUntilMs else { return true }
        return scope.contains("engagement") && cooldownUntilMs >= (speechEndMs ?? Int.max)
    }
    /// `stop-phrase` carries no confidence; `decision` carries a probability.
    private var validDismissReason: Bool {
        switch (reason, confidence) {
        case ("stop-phrase", nil): true
        case ("decision", let value?): value.isFinite && (0...1).contains(value)
        default: false
        }
    }
}
/// Every key of the `dismissal` object (already converted from snake case), for strict no-extra-keys decoding.
private struct DismissalKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
