import Foundation
/// One explicit producer session and immutable target binding. Failures never imply rollback or permit retry.
public actor RightyoInputConsumer {
    private let host: HailHost?
    private let allowSynthetic: Bool
    private let target: String
    private let binding: String
    private let session: String
    private let streamBudgetMs: Int?
    private var started = false, terminal = false, busy = false, activationEnabled = false, failed = false
    private var sequence = 0, emittedAt = 0
    private var speakers = "anonymous"
    private var requests = Set<String>()
    private var superseded = Set<String>()
    private var decided = Set<String>()
    private var finals: [String: Data] = [:]
    private var attentions: [String: Data] = [:]
    private var seen: [Int: Data] = [:]
    /// `streamBudgetMs` is an optional ceiling on producer stream time; the default is no ceiling (#188).
    public init(host: HailHost?, target: String, binding: String, session: String,
                allowSynthetic: Bool = false, streamBudgetMs: Int? = nil) throws {
        guard !binding.isEmpty, RightyoInputEvent.identifier(session), streamBudgetMs.map({ $0 >= 0 }) ?? true else {
            throw RightyoInputError.unavailableBinding
        }
        self.host = host
        self.allowSynthetic = allowSynthetic
        self.target = target
        self.binding = binding
        self.session = session
        self.streamBudgetMs = streamBudgetMs
    }
    /// True means handled: guarded delivery, or validation only when initialized with no host.
    public func consume(_ event: RightyoInputEvent) async throws -> Bool {
        do {
            guard try admit(event) else { return false }
            if event.type == "override" { return true }
            guard event.type == "request", let requestID = event.requestId else { return false }
            guard requests.count < 1000, requests.insert(requestID).inserted else {
                throw RightyoInputError.invalidEvent
            }
            guard host == nil || allowSynthetic || event.turn?.provenance == "live-microphone" else {
                terminal = true
                throw RightyoInputError.invalidEvent
            }
            guard let host else { return true }
            busy = true
            defer { busy = false }
            do {
                try Task.checkCancellation()
                let outcome = try await host.send(event.prompt(speakers: speakers), to: target,
                                                  from: "rightyo-local", expectedBinding: binding)
                if case .needsConfirmation(let readBack) = outcome {
                    await host.cancel(readBack.hash)
                    throw RightyoInputError.confirmationRequired
                }
                return true
            } catch {
                terminal = true
                throw error
            }
        } catch {
            terminal = true
            failed = true
            throw error
        }
    }
    private func admit(_ event: RightyoInputEvent) throws -> Bool {
        try event.validate(session: session, enrolled: speakers == "enrolled", budgetMs: streamBudgetMs)
        guard !busy else { throw RightyoInputError.invalidLifecycle }
        let fingerprint = try RightyoInputEvent.fingerprint(event)
        if let old = seen[event.sequence] {
            guard old == fingerprint else {
                throw RightyoInputError.invalidEvent
            }
            return false
        }
        guard !terminal else { throw RightyoInputError.invalidLifecycle }
        guard event.sequence > sequence, event.emittedAtMs >= emittedAt else {
            throw RightyoInputError.sequenceGap
        }
        guard seen.count < 4096 else { throw RightyoInputError.capacity }
        if event.type == "session" {
            let caps = try event.phase == "started" ? startCapabilities(event) : nil
            try lifecycle(event.phase)
            // Only an accepted first `started` mutates session state; a rejected repeat changes nothing.
            if let caps {
                activationEnabled = caps.activation == "finalized-turn"
                speakers = caps.speakers
            }
        } else if !started { throw RightyoInputError.invalidLifecycle }
        try correlate(event)
        sequence = event.sequence
        emittedAt = event.emittedAtMs
        seen[event.sequence] = fingerprint
        return true
    }
    private func startCapabilities(_ event: RightyoInputEvent) throws -> RightyoInputEvent.Capabilities {
        guard let caps = event.capabilities, ["finalized-turn", "disabled"].contains(caps.activation),
              !caps.partials, ["anonymous", "enrolled"].contains(caps.speakers), caps.context else {
            throw RightyoInputError.invalidEvent
        }
        return caps
    }
    public func finish() throws {
        guard terminal, !busy else { throw RightyoInputError.invalidLifecycle }
        if failed { throw RightyoInputError.producerFailed }
    }
    private func lifecycle(_ phase: String?) throws {
        switch phase {
        case "started":
            guard !started else { throw RightyoInputError.invalidLifecycle }
            started = true
        case "stopped", "cancelled", "error":
            guard started else { throw RightyoInputError.invalidLifecycle }
            terminal = true
            failed = phase == "error"
        default: throw RightyoInputError.invalidLifecycle
        }
    }
}
/// Correlation against admitted records lives here so the actor body stays within the type-length limit.
extension RightyoInputConsumer {
    private func correlate(_ event: RightyoInputEvent) throws {
        switch event.type {
        case "transcript":
            guard let turn = event.turn, finals.count < 1000, finals[turn.utteranceId] == nil else {
                throw RightyoInputError.invalidEvent
            }
            finals[turn.utteranceId] = try RightyoInputEvent.fingerprint(turn)
        case "attention": try attention(event)
        case "override": try supersede(event)
        case "request":
            guard activationEnabled, let turn = event.turn, let decision = event.decision,
                  !superseded.contains(event.requestId ?? ""),
                  finals[turn.utteranceId] == (try RightyoInputEvent.fingerprint(turn)),
                  attentions[event.requestId ?? ""] == (try RightyoInputEvent.fingerprint(decision)) else {
                throw RightyoInputError.invalidEvent
            }
            for prior in event.context?.turns ?? [] {
                guard finals[prior.utteranceId] == (try RightyoInputEvent.fingerprint(prior)) else {
                    throw RightyoInputError.invalidEvent
                }
            }
        default: break
        }
    }
    private func attention(_ event: RightyoInputEvent) throws {
        guard let utterance = event.utteranceId, finals[utterance] != nil, let decision = event.decision,
              decided.count < 1000, decided.insert(utterance).inserted,
              ["attend", "ignore", "uncertain"].contains(decision.label) else {
            throw RightyoInputError.invalidEvent
        }
        if decision.label == "attend" {
            guard activationEnabled, decision.recipientKind == "system",
                  event.requestId == "\(session):\(utterance)", attentions.count < 1000,
                  attentions[event.requestId ?? ""] == nil else {
                throw RightyoInputError.invalidEvent
            }
            attentions[event.requestId ?? ""] = try RightyoInputEvent.fingerprint(decision)
        }
    }
    /// An owner `override` (#188 item 3) must follow the owner's own admitted transcript and attention
    /// records. The superseded id is recorded whether or not this consumer ever admitted it (a producer may
    /// supersede a request the host refused), idempotently, under the same cap as `requests`. A request
    /// already sent to the pane stays sent: this records precedence and refuses a later request with that id.
    private func supersede(_ event: RightyoInputEvent) throws {
        guard let requestID = event.supersededRequestId, let utterance = event.byUtteranceId,
              finals[utterance] != nil, decided.contains(utterance),
              superseded.contains(requestID) || superseded.count < 1000 else {
            throw RightyoInputError.invalidEvent
        }
        superseded.insert(requestID)
    }
}
