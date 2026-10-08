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
/// What one admitted `dismiss` did (rightyo#98). Fixed tokens and counts only: never ids or transcript text.
public struct RightyoDismissReceipt: Sendable, Equatable {
    /// `stop-phrase` or `decision`.
    public var reason: String
    /// What RightyO asks the host to stop: `playback`, `pending_request`, `engagement`.
    public var scope: [String]
    /// Listed ids this consumer never delivered: dropped should they ever arrive. RightyO already withholds
    /// them, so this is the host's own record, not a delivery change.
    public var withdrawn: Int
    /// Listed ids already delivered: withdrawal is advisory and nothing delivered is undone.
    public var alreadyDelivered: Int
    public var stopsPlayback: Bool { scope.contains("playback") }
    public init(reason: String, scope: [String], withdrawn: Int, alreadyDelivered: Int) {
        (self.reason, self.scope, self.withdrawn, self.alreadyDelivered) = (reason, scope, withdrawn, alreadyDelivered)
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
/// Why a target id cannot be named in the reply block (#188 item 1); refused at startup, before any event. The
/// diagnostic names the rule, never the id, so `haild rightyo` can print it as is.
public enum RightyoTargetError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Outside the allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`, the only shape the shell-shaped block quotes safely.
    case unsafeIdentifier
    /// The block built for the id matches the named default guard rules, so every request would need confirmation.
    case guarded([String])
    public var description: String {
        switch self {
        case .unsafeIdentifier:
            "target id must match [A-Za-z0-9][A-Za-z0-9._:-]{0,95} to be named in the reply block"
        case .guarded(let rules): "target name would trigger the content guard (\(rules.joined(separator: ", ")))"
        }
    }
}
/// One explicit producer session and immutable target binding. Failures never imply rollback or permit retry.
public actor RightyoInputConsumer {
    /// nil validates only (dry run): no delivery step exists.
    private let dispatcher: (any RightyoDispatching)?
    /// True for heard text that is the host's own reply coming back through the mic (#269); never dispatched.
    private let echoFilter: (@Sendable (String) -> Bool)?
    /// Requests dropped as own-voice echo. A count only, never their text.
    public private(set) var echoDropped = 0
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
    /// Whether `started` advertised `dismissal` version 1 (rightyo#98): only then is `dismiss` admitted.
    private var dismissible = false
    /// Request ids a `dismiss` withdrew before this consumer delivered them; a later request with one is dropped.
    private var withdrawn = Set<String>()
    /// Withdrawn ids a request has already been dropped for, so a repeat is refused as a duplicate (a subset of `withdrawn`).
    private var dropped = Set<String>()
    /// Requests dropped because a dismissal had withdrawn them. A count only.
    public private(set) var withdrawnDropped = 0
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
    /// What the most recent admitted `dismiss` did; cleared as each event is consumed, like `lastReceipt`.
    public private(set) var lastDismissal: RightyoDismissReceipt?
    /// `streamBudgetMs` is an optional ceiling on producer stream time; the default is no ceiling (#188).
    /// `dispatcher` replaces the direct `HailHost.send` step (#188 item 1); without it, `host` delivers directly
    /// and nil `host` validates only. A dispatcher with no host still delivers (it owns its own host access).
    /// `target` is quoted verbatim into every prompt's reply block, so `validateTarget` refuses an unsafe or
    /// guarded id at startup rather than delivering it.
    public init(host: HailHost?, target: String, binding: String, session: String,
                allowSynthetic: Bool = false, streamBudgetMs: Int? = nil,
                dispatcher: (any RightyoDispatching)? = nil, echoFilter: (@Sendable (String) -> Bool)? = nil) throws {
        guard !binding.isEmpty, RightyoInputEvent.identifier(session), streamBudgetMs.map({ $0 >= 0 }) ?? true else {
            throw RightyoInputError.unavailableBinding
        }
        try Self.validateTarget(target)
        self.dispatcher = dispatcher ?? host.map { RightyoHostDispatcher(host: $0) }
        self.echoFilter = echoFilter
        self.allowSynthetic = allowSynthetic
        self.target = target
        self.binding = binding
        self.session = session
        self.streamBudgetMs = streamBudgetMs
    }
    /// The reply block is a shell-shaped instruction that names the target verbatim, so the id must match the
    /// allowlist `[A-Za-z0-9][A-Za-z0-9._:-]{0,95}`: every listed `kind:name` shape the adapters produce
    /// (`tmux:demo`, `tmux-reply:main.0`, `tmux:dev.2:0`) and nothing a shell could read as syntax. tmux names may
    /// legally contain spaces or `;`; such a target is unusable for `haild rightyo` until it is renamed. The block
    /// for the id is then matched against the default guard rules, so an authorized name carrying a guarded word
    /// (`tmux:sudo`) is refused here with a diagnostic instead of turning every request into
    /// `confirmationRequired`; a daemon policy with custom guard patterns can still require confirmation, which
    /// the consumer refuses per request as before.
    public static func validateTarget(_ target: String) throws {
        let alphanumeric = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        guard let first = target.first, alphanumeric.contains(first), target.count <= 96,
              target.allSatisfy({ alphanumeric.contains($0) || "._:-".contains($0) }) else {
            throw RightyoTargetError.unsafeIdentifier
        }
        let hits = DangerousPatternGuard.matches(in: [RightyoInputEvent.replyBlock(target: target)],
                                                 patterns: DangerousPatternGuard.defaults)
        guard hits.isEmpty else { throw RightyoTargetError.guarded(hits) }
    }
    /// True means handled: guarded delivery, or validation only when initialized with no host. An admitted `dismiss`
    /// delivers nothing and returns false; `lastDismissal` then says what it did.
    public func consume(_ event: RightyoInputEvent) async throws -> Bool {
        lastReceipt = nil
        lastDismissal = nil
        do {
            guard try admit(event) else { return false }
            if event.type == "override" { return true }
            guard event.type == "request", let requestID = event.requestId else { return false }
            guard try claim(requestID, provenance: event.turn?.provenance) else { return false }
            guard let dispatcher else { return true }
            // Matched on the heard turn, not the built prompt, whose envelope would bury the echo (#269).
            if let echoFilter, let heard = event.turn?.text, echoFilter(heard) {
                echoDropped += 1
                return false
            }
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
    /// Refuses a duplicate id or, on a live-only consumer, a non-live request; then claims the id. False means
    /// withdrawn by the speaker's dismissal before it arrived: never delivered, and the session goes on. That drop
    /// comes after both refusals, and a repeat of a dropped id is still a duplicate.
    private func claim(_ requestID: String, provenance: String?) throws -> Bool {
        guard requests.count < 1000, !requests.contains(requestID) else { throw RightyoInputError.invalidEvent }
        guard dispatcher == nil || allowSynthetic || provenance == "live-microphone" else {
            terminal = true
            throw RightyoInputError.invalidEvent
        }
        if withdrawn.contains(requestID) {
            guard dropped.insert(requestID).inserted else { throw RightyoInputError.invalidEvent }
            withdrawnDropped += 1
            return false
        }
        requests.insert(requestID)
        return true
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
                dismissible = event.dismissal != nil
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
        case "dismiss": try dismiss(event)
        case "request": try request(event)
        default: break
        }
    }
    private func request(_ event: RightyoInputEvent) throws {
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
    }
    private func attention(_ event: RightyoInputEvent) throws {
        guard let utterance = event.utteranceId, finals[utterance] != nil, let decision = event.decision,
              decided.count < 1000, decided.insert(utterance).inserted,
              ["attend", "ignore", "uncertain"].contains(decision.label) else {
            throw RightyoInputError.invalidEvent
        }
        // An attention record that does not repeat `owner` demotes the utterance; it can never promote one.
        if decision.role != "owner" { owners.remove(utterance) }
        // An `attend` with no `request_id` forms no request: RightyO sends one for a turn it dismissed, withdrew,
        // superseded or held as a stop phrase (rightyo#98). Nothing is recorded, so `request` refuses any request
        // citing it; only an `attend` that names a request id is checked and recorded.
        if decision.label == "attend", let requestID = event.requestId {
            guard activationEnabled, decision.recipientKind == "system",
                  requestID == "\(session):\(utterance)", attentions.count < 1000,
                  attentions[requestID] == nil else {
                throw RightyoInputError.invalidEvent
            }
            attentions[requestID] = try RightyoInputEvent.fingerprint(decision)
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
    /// A `dismiss` (rightyo#98) is admitted only on a session that advertised `dismissal`, and must cite an admitted
    /// transcript: a stop phrase's comes right after it, before its attention. Each listed id this consumer already
    /// delivered stays delivered (withdrawal is advisory); any other id, including one never seen, which is how
    /// RightyO names a request it withheld, is recorded so a later request with it is dropped, idempotently, under
    /// the same cap as `requests`. Scope and role only withhold or stop host action; they never grant any.
    private func dismiss(_ event: RightyoInputEvent) throws {
        guard dismissible, let utterance = event.utteranceId, finals[utterance] != nil,
              let ids = event.withdrawnRequestIds, let scope = event.scope, let reason = event.reason else {
            throw RightyoInputError.invalidEvent
        }
        let delivered = ids.filter(requests.contains)
        let fresh = Set(ids).subtracting(requests).subtracting(withdrawn)
        guard withdrawn.count + fresh.count <= 1000 else { throw RightyoInputError.capacity }
        withdrawn.formUnion(fresh)
        lastDismissal = RightyoDismissReceipt(reason: reason, scope: scope, withdrawn: ids.count - delivered.count,
                                              alreadyDelivered: delivered.count)
    }
}
