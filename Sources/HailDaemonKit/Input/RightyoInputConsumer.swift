public import Foundation

// The delivery-step protocol and its direct implementation stay beside the consumer that owns their contract.
// swiftlint:disable file_length

/// What an admitted RightyO request becomes once delivered (#188 item 1, part B). `request` is the host-minted
/// reply request the named connection now owns, or nil when no reply ownership was established: the direct
/// `HailHost.send` path never mints one, and a dispatch to a legacy adapter answers `request: null`.
public struct RightyoDispatchReceipt: Sendable, Equatable {
    public var request: UUID?
    /// The deliverer's own explanation when the prompt landed but no reply ownership survived (for example
    /// the daemon's `ownershipLost` or `connectionLost`); nil when there is nothing to explain.
    public var caveat: String?
    public init(request: UUID?, caveat: String? = nil) {
        self.request = request
        self.caveat = caveat
    }
}
/// The final delivery step of an admitted request. The consumer keeps every validation and correlation rule
/// in front of this call and treats any thrown error as terminal; implementations must not retry on their own.
/// `RightyoHostDispatcher` is the direct path; `haild rightyo --reply-to` supplies a reply-socket dispatcher.
public protocol RightyoDispatching: Sendable {
    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt
}
/// The direct path: `HailHost.send` from the fixed `rightyo-local` device with the pinned binding. A
/// confirmation read-back is cancelled and refused; this consumer never confirms on the person's behalf.
public struct RightyoHostDispatcher: RightyoDispatching {
    public static let device = "rightyo-local"
    private let host: HailHost
    public init(host: HailHost) { self.host = host }
    public func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        let outcome = try await host.send(text, to: target, from: Self.device, expectedBinding: binding)
        if case .needsConfirmation(let readBack) = outcome {
            await host.cancel(readBack.hash)
            throw RightyoInputError.confirmationRequired
        }
        return RightyoDispatchReceipt(request: nil)
    }
}
/// One explicit producer session and immutable target binding. Failures never imply rollback or permit retry.
public actor RightyoInputConsumer {
    /// nil validates only (dry run): no delivery step exists.
    private let dispatcher: (any RightyoDispatching)?
    private let allowSynthetic: Bool
    private let target: String
    private let binding: String
    private let session: String
    private let streamBudgetMs: Int?
    private var started = false, terminal = false, busy = false, activationEnabled = false, failed = false
    private var sequence = 0, emittedAt = 0
    private var speakers = "anonymous"
    /// Whether `started` advertised `request_forming` (#188 item 4): then every request must carry `formed_request`,
    /// otherwise none may. Forming is allowed on anonymous sessions too (hosts pick), where any role the formed text
    /// names is uncheckable: only the JSON record behind it carries verified roles, and anonymous sessions have none.
    private var forming = false
    private var requests = Set<String>()
    private var superseded = Set<String>()
    private var decided = Set<String>()
    /// Utterance ids whose admitted transcript carried `role: owner` and whose admitted attention record, if any,
    /// carried it too (#188 item 3). A subset of `finals`, so the 1,000-finals cap bounds it.
    private var owners = Set<String>()
    private var finals: [String: Data] = [:]
    private var attentions: [String: Data] = [:]
    private var seen: [Int: Data] = [:]
    /// The receipt of the most recent delivered request; nil until one is delivered and cleared as each event
    /// is consumed, so a caller reads only the receipt of the event it just passed in.
    public private(set) var lastReceipt: RightyoDispatchReceipt?
    /// `streamBudgetMs` is an optional ceiling on producer stream time; the default is no ceiling (#188).
    /// `dispatcher` replaces the direct `HailHost.send` step (#188 item 1); without it, `host` delivers directly
    /// and nil `host` validates only. A dispatcher with no host still delivers (it owns its own host access).
    /// `target` is named in every prompt's reply block, so a target with a line break is refused at startup:
    /// the block is one line by construction, not only because the host sanitizer would refuse the prompt.
    public init(host: HailHost?, target: String, binding: String, session: String,
                allowSynthetic: Bool = false, streamBudgetMs: Int? = nil,
                dispatcher: (any RightyoDispatching)? = nil) throws {
        guard !binding.isEmpty, !target.isEmpty, !target.contains(where: \.isNewline),
              RightyoInputEvent.identifier(session), streamBudgetMs.map({ $0 >= 0 }) ?? true else {
            throw RightyoInputError.unavailableBinding
        }
        self.dispatcher = dispatcher ?? host.map { RightyoHostDispatcher(host: $0) }
        self.allowSynthetic = allowSynthetic
        self.target = target
        self.binding = binding
        self.session = session
        self.streamBudgetMs = streamBudgetMs
    }
    /// True means handled: guarded delivery, or validation only when initialized with no host.
    public func consume(_ event: RightyoInputEvent) async throws -> Bool {
        lastReceipt = nil
        do {
            guard try admit(event) else { return false }
            if event.type == "override" { return true }
            guard event.type == "request", let requestID = event.requestId else { return false }
            guard requests.count < 1000, requests.insert(requestID).inserted else {
                throw RightyoInputError.invalidEvent
            }
            guard dispatcher == nil || allowSynthetic || event.turn?.provenance == "live-microphone" else {
                terminal = true
                throw RightyoInputError.invalidEvent
            }
            guard let dispatcher else { return true }
            busy = true
            defer { busy = false }
            do {
                try Task.checkCancellation()
                lastReceipt = try await dispatcher.dispatch(
                    text: event.prompt(speakers: speakers, target: target), target: target, binding: binding
                )
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
                forming = event.requestForming != nil
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
            if turn.role == "owner" { owners.insert(turn.utteranceId) }
        case "attention": try attention(event)
        case "override": try supersede(event)
        case "request":
            guard activationEnabled, let turn = event.turn, let decision = event.decision,
                  (event.formedRequest != nil) == forming, !superseded.contains(event.requestId ?? ""),
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
        // An attention record that does not repeat `owner` demotes the utterance; it can never promote one.
        if decision.role != "owner" { owners.remove(utterance) }
        if decision.label == "attend" {
            guard activationEnabled, decision.recipientKind == "system",
                  event.requestId == "\(session):\(utterance)", attentions.count < 1000,
                  attentions[event.requestId ?? ""] == nil else {
                throw RightyoInputError.invalidEvent
            }
            attentions[event.requestId ?? ""] = try RightyoInputEvent.fingerprint(decision)
        }
    }
    /// An owner `override` (#188 item 3) must cite the owner's own admitted transcript and attention records:
    /// both must have carried `role: owner` (`owners`), so an absent, anonymous or non-owner cited turn is
    /// refused (fail closed). The superseded id is recorded whether or not this consumer ever admitted it (a
    /// producer may supersede a request the host refused), idempotently, under the same cap as `requests`. A
    /// request already sent to the pane stays sent: this records precedence and refuses a later request with that id.
    private func supersede(_ event: RightyoInputEvent) throws {
        guard let requestID = event.supersededRequestId, let utterance = event.byUtteranceId,
              owners.contains(utterance), decided.contains(utterance),
              superseded.contains(requestID) || superseded.count < 1000 else {
            throw RightyoInputError.invalidEvent
        }
        superseded.insert(requestID)
    }
}
