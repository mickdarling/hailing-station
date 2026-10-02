import CryptoKit
public import Foundation
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
    let role: String?
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
              ["session", "transcript", "attention", "request", "override"].contains(type) else {
            throw RightyoInputError.invalidEvent
        }
        try validateOverride(session: session, enrolled: enrolled)
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
    /// session's `session:utterance` shape. Other event kinds may not carry override fields (fail closed).
    private func validateOverride(session: String, enrolled: Bool) throws {
        guard type == "override" else {
            guard supersededRequestId == nil, byUtteranceId == nil, role == nil else {
                throw RightyoInputError.invalidEvent
            }
            return
        }
        guard enrolled, role == "owner", let supersededRequestId, let byUtteranceId,
              Self.identifier(byUtteranceId), supersededRequestId.hasPrefix("\(session):"),
              Self.identifier(String(supersededRequestId.dropFirst(session.count + 1))) else {
            throw RightyoInputError.invalidEvent
        }
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
