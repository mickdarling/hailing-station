import Foundation
public import HailProtocol
import Synchronization

// Correlated and single-terminal fallback publication share one admission-and-enqueue boundary.
// swiftlint:disable file_length

enum ReplyPublicationStatus: Equatable, Sendable {
    case absent, pending, ready
}

/// A host-minted request belongs to this HostSession only. Neither device names nor wire UUIDs create it.
struct HostReplyRequest {
    static let capacity = 64
    static let lifetime: Duration = .seconds(120)
    static let frameLimit = 1_024
    let context: ProviderTurnContext
    let generation: UUID
    let createdAt: ContinuousClock.Instant
    let policyPermit: ReplyPublicationPermit
    /// The adapter's cooperative binding gate. Nil only for a host-minted ambient reference on a legacy adapter
    /// (#230), which no adapter can lease: its binding is re-read from the listing before every enqueue instead
    /// (`unleasedBindingIsCurrent`), a snapshot rather than a gate.
    let bindingLease: ProviderReplyBindingLease?
    var committed = false
    var descriptor: ReplyDescriptor?
    var textDelivered = false
    var audioSequence = 0
    var audioFinished = false
    var frames: Set<UUID> = []

    func isCurrent(at timestamp: ContinuousClock.Instant) -> Bool {
        let elapsed = createdAt.duration(to: timestamp)
        return elapsed >= .zero && elapsed < Self.lifetime
    }

    /// Keep these exact admission tickets: revocation followed by restoration cannot revive a request.
    func withAuthority<Result>(_ operation: () -> Result) -> Result? {
        guard let result = policyPermit.performIfCurrent({ () -> Result? in
            guard let bindingLease else { return operation() }
            return bindingLease.performIfCurrent(operation)
        }) else { return nil }
        return result
    }

    mutating func accept(_ frame: Frame, descriptor reply: ReplyDescriptor) -> Bool {
        guard frames.count < Self.frameLimit, !frames.contains(frame.id),
              descriptor == nil || descriptor == reply else { return false }
        switch frame.payload {
        case .text(let text):
            guard text.isFinal, !textDelivered else { return false }
            textDelivered = true
        case .audio(let audio):
            guard !audioFinished, audio.streamID == reply.audioStreamID, audio.streamID != nil,
                  audio.sequence == audioSequence else { return false }
            audioSequence += 1
            audioFinished = audio.isFinal
        default: return false
        }
        descriptor = reply
        frames.insert(frame.id)
        return true
    }
}

/// #370: per target, the connection that most recently sent it admitted input, by ambient dispatch or a phone's own
/// final text frame, recorded only after a delivered handoff. Host-side only: no client field, device name or reply
/// reference can write it. An entry is bound to its connection and that connection's selection generation, and it
/// routes a request-less reply for `lifetime` (10 minutes, long enough for a reply to a long task, short enough that a
/// device left selecting the target does not keep the answers indefinitely). Replies are pinned to the device that
/// received their first frame, so one reply never splits across devices.
final class LastInputLedger: Sendable {
    struct Entry: Equatable, Sendable {
        let connection: UUID
        let generation: UUID
        let at: ContinuousClock.Instant
    }

    static let lifetime: Duration = .seconds(600)
    static let targetLimit = 256
    static let pinLimit = 64

    private struct Pin {
        let reply: UUID
        let target: String
        let entry: Entry
    }

    private struct State {
        var latest: [String: Entry] = [:]
        var pins: [Pin] = []
        var routed: [UUID] = []
    }

    private let state = Mutex(State())

    func record(_ entry: Entry, for target: String) {
        state.withLock { state in
            state.latest[target] = entry
            guard state.latest.count > Self.targetLimit,
                  let oldest = state.latest.min(by: { $0.value.at < $1.value.at })?.key else { return }
            state.latest[oldest] = nil
        }
    }

    func latest(for target: String) -> Entry? { state.withLock { $0.latest[target] } }

    func pinned(_ reply: UUID, target: String) -> Entry? {
        state.withLock { $0.pins.last(where: { $0.reply == reply && $0.target == target })?.entry }
    }

    func pin(_ reply: UUID, target: String, to entry: Entry) {
        state.withLock { state in
            guard !state.pins.contains(where: { $0.reply == reply && $0.target == target }) else { return }
            state.pins.append(Pin(reply: reply, target: target, entry: entry))
            state.pins.removeFirst(max(0, state.pins.count - Self.pinLimit))
        }
    }

    /// True the first time a reply is routed (bounded like the pins), so its path is logged once per reply.
    func firstRoute(of reply: UUID) -> Bool {
        state.withLock { state in
            guard !state.routed.contains(reply) else { return false }
            state.routed.append(reply)
            state.routed.removeFirst(max(0, state.routed.count - Self.pinLimit))
            return true
        }
    }

    /// A departed connection is no target's last input device. Its pins stay (bounded), so the rest of a reply that
    /// started there is refused rather than moved to another device.
    func forget(connection: UUID) {
        state.withLock { state in state.latest = state.latest.filter { $0.value.connection != connection } }
    }
}

/// Which connection a request-less reply is restricted to (#370): the target's last input device, or the device
/// that received the reply's first frame (`pinned`, which outlives the input lifetime but not the selection).
struct LastInputRoute: Sendable {
    let entry: LastInputLedger.Entry
    let pinned: Bool
}

extension HostSession {
    func attachLastInput(_ ledger: LastInputLedger) { lastInputLedger = ledger }

    /// Called only from `deliver` after a delivered handoff, in the actor turn that confirmed `generation`.
    func noteLastInput(to target: String, generation: UUID) {
        let entry = LastInputLedger.Entry(connection: connectionID, generation: generation, at: requestClock())
        lastInputLedger?.record(entry, for: target)
    }

    /// The route still names this connection on the same selection of `target`, and an unpinned route is current.
    private func holds(_ route: LastInputRoute, target: String) -> Bool {
        guard case .ready = state, route.entry.connection == connectionID,
              route.entry.generation == selectionGeneration, selectedTarget == target else { return false }
        guard !route.pinned else { return true }
        let elapsed = route.entry.at.duration(to: requestClock())
        return elapsed >= .zero && elapsed < LastInputLedger.lifetime
    }

    func pruneReplyRequests() {
        let timestamp = requestClock()
        replyRequests = replyRequests.filter {
            $0.value.isCurrent(at: timestamp) && $0.value.withAuthority { true } == true
        }
    }

    /// A side-effect-free admission snapshot, not publication authority. Media is checked on a copy;
    /// actual enqueue must repeat the recipient/media checks under the retained authority gates.
    func replyPublicationStatus(_ frame: Frame) -> ReplyPublicationStatus {
        guard let (_, request) = replyCandidate(frame) else { return .absent }
        return request.withAuthority {
            guard !Task.isCancelled, request.isCurrent(at: requestClock()) else { return .absent }
            return request.committed ? .ready : .pending
        } ?? .absent
    }

    private func replyDescriptor(_ frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }

    private func replyCandidate(_ frame: Frame) -> (UUID, HostReplyRequest)? {
        guard !Task.isCancelled, let reply = replyDescriptor(frame), let requestID = reply.requestID,
              !stoppedReplies.contains(reply.id) else { return nil }
        guard case .ready(let version) = state, frame.version == version,
              var request = replyRequests[requestID], request.isCurrent(at: requestClock()),
              request.generation == selectionGeneration, selectedTarget == frame.target,
              request.context.connectionID == connectionID,
              frame.target == request.context.binding.targetID,
              request.accept(frame, descriptor: reply) else { return nil }
        return (requestID, request)
    }

    /// Pending/failed, legacy, stale and other-connection requests never acquire recipient authority.
    /// The enqueue must be synchronous and non-reentrant; no Boolean authorization leaves this actor.
    func enqueueHostReply(_ frame: Frame, enqueue: @Sendable () -> Bool) -> Bool {
        pruneReplyRequests()
        guard let (requestID, request) = replyCandidate(frame), request.committed else { return false }
        // Policy, cooperative binding, recipient/media state and actual network submission share one
        // no-await commit. Recheck expiry after waiting for the gates; completion is awaited outside them.
        guard request.withAuthority({
            guard !Task.isCancelled, request.isCurrent(at: requestClock()), enqueue() else { return false }
            replyRequests[requestID] = request
            noteReplyDelivered(frame)
            return true
        }) == true else {
            replyRequests[requestID] = nil
            return false
        }
        return true
    }

    /// An unleased ambient record (#230) has no cooperative binding gate, so its target's listing is re-read before
    /// each enqueue: a rebound, vanished or dead target refuses and drops the record. This is a snapshot one actor
    /// hop from the enqueue, not a lease. A leased record, or none at all, is left to `enqueueHostReply`.
    func unleasedBindingIsCurrent(_ frame: Frame) async -> Bool {
        guard let requestID = replyDescriptor(frame)?.requestID, let request = replyRequests[requestID],
              request.bindingLease == nil else { return true }
        let binding = request.context.binding
        let listing = try? await host.registry.listing()
        guard listing?.contains(where: {
            $0.info.id == binding.targetID && $0.info.alive && $0.binding == binding.sessionID
        }) == true else {
            if replyRequests[requestID]?.context == request.context { replyRequests[requestID] = nil }
            return false
        }
        return true
    }

    /// Side-effect-free single-terminal fallback snapshot (#188): a request-less reply, live selection of
    /// its target and a currently issuable host permit (policy binding, tier, policy health, lockdown).
    /// No ticket is retained from it.
    /// A `lastInput` route (#370) additionally restricts the reply to that exact connection and selection.
    func admitsRequestlessReply(_ frame: Frame, lastInput: LastInputRoute? = nil) async -> Bool {
        guard selectsRequestlessReplyTarget(frame, lastInput: lastInput),
              await requestlessReplyPermit(frame) != nil else { return false }
        return selectsRequestlessReplyTarget(frame, lastInput: lastInput)
    }

    /// Any explicit request reference, owned or not, stays on the correlated path. Only the plain
    /// `haild reply --say` shape may fall back, so a stale reference can never reach another connection.
    private func selectsRequestlessReplyTarget(_ frame: Frame, lastInput: LastInputRoute?) -> Bool {
        guard !Task.isCancelled, case .ready(let version) = state, frame.version == version,
              let reply = replyDescriptor(frame), reply.requestID == nil, !stoppedReplies.contains(reply.id),
              let target = frame.target, target == selectedTarget else { return false }
        return lastInput.map { holds($0, target: target) } ?? true
    }

    /// Policy, exact binding, tier and lockdown are re-read from the host for every fallback attempt.
    /// There is no retained request ticket, cooperative lease or media pinning for a request-less reply.
    private func requestlessReplyPermit(_ frame: Frame) async -> ReplyPublicationPermit? {
        guard let target = frame.target, let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive, let sessionBinding = try? ProviderSessionBinding(
                hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding
              ) else { return nil }
        return await host.replyPublicationPermit(for: sessionBinding)
    }

    func enqueueRequestlessReply(_ frame: Frame, enqueue: @Sendable () -> Bool) async -> Bool {
        await enqueueRoutedReply(frame, enqueue: enqueue) != nil
    }

    /// Delivers to this connection only while it still selects the target (and still holds `lastInput`, when
    /// given) and the host permit is current. Returns the selection it delivered under, so later frames of the same
    /// reply can be pinned to it (#370); nil when nothing was enqueued.
    func enqueueRoutedReply(
        _ frame: Frame, lastInput: LastInputRoute? = nil, enqueue: @Sendable () -> Bool
    ) async -> LastInputLedger.Entry? {
        guard selectsRequestlessReplyTarget(frame, lastInput: lastInput),
              let permit = await requestlessReplyPermit(frame) else { return nil }
        // Selection or state may have moved during the awaits; the gate itself rejects a revoked permit.
        guard selectsRequestlessReplyTarget(frame, lastInput: lastInput) else { return nil }
        guard permit.performIfCurrent({ !Task.isCancelled && enqueue() }) == true else { return nil }
        noteReplyDelivered(frame)
        return .init(connection: connectionID, generation: selectionGeneration, at: requestClock())
    }

    /// Tracks which replies' audio is mid-stream on this connection, so a stop knows what to cut (#309).
    private func noteReplyDelivered(_ frame: Frame) {
        guard case .audio(let audio) = frame.payload, let reply = audio.reply else { return }
        repliesInFlight.removeAll { $0 == reply.id }
        guard !audio.isFinal else { return }
        // An abandoned stream never sends its final frame, so the oldest entry gives way: a live reply is always
        // tracked, and a stale one can at worst be stopped again.
        repliesInFlight.append(reply.id)
        repliesInFlight.removeFirst(max(0, repliesInFlight.count - Self.playbackStopLimit))
    }

    static let playbackStopLimit = 64

    func hasStopped(_ frame: Frame) -> Bool {
        Self.replyID(frame).map(stoppedReplies.contains) ?? false
    }

    nonisolated static func replyID(_ frame: Frame) -> UUID? {
        switch frame.payload {
        case .text(let text): text.reply?.id
        case .audio(let audio): audio.reply?.id
        default: nil
        }
    }

    /// A `dismiss` asked to stop playback (#309). Every reply mid-stream on this connection is stopped: its
    /// remaining frames are refused, so the reply CLI retires its renderer. The `stop_playback` frame is
    /// returned only for a ready device that advertised it; an older device would refuse it as malformed.
    func stopReplyPlayback() -> (frame: Frame?, stopped: [UUID]) {
        guard case .ready(let version) = state else { return (nil, []) }
        let stopped = repliesInFlight
        stoppedReplies.append(contentsOf: repliesInFlight)
        stoppedReplies.removeFirst(max(0, stoppedReplies.count - Self.playbackStopLimit))
        repliesInFlight.removeAll()
        guard peerCapabilities.contains(PlaybackStop.capability) else { return (nil, stopped) }
        return (response(.stopPlayback, version: version), stopped)
    }
}

extension WebSocketPeer {
    func replyPublicationStatus(_ frame: Frame) async -> ReplyPublicationStatus {
        // Terminal retirement precedes actor callbacks. Preparation is side-effect-free, and final
        // enqueue independently rechecks transport authority rather than trusting this status snapshot.
        guard prepareReplyPublication(frame) != nil else { return .absent }
        let status = await session.replyPublicationStatus(frame)
        guard prepareReplyPublication(frame) != nil else { return .absent }
        return status
    }

    /// Returns true only for this negotiated connection's successfully dispatched, still-current request.
    func deliverHostReply(_ frame: Frame) async -> Bool {
        guard !ended, await session.unleasedBindingIsCurrent(frame), let prepared = prepareReplyPublication(frame),
              await session.enqueueHostReply(frame, enqueue: prepared.enqueue) else { return false }
        guard await prepared.result() else {
            finish(reason: "host reply send failed")
            return false
        }
        return true
    }

    func admitsRequestlessReply(_ frame: Frame, lastInput: LastInputRoute? = nil) async -> Bool {
        guard await session.admitsRequestlessReply(frame, lastInput: lastInput) else { return false }
        // A retiring transport cannot be the single recipient.
        return prepareReplyPublication(frame) != nil
    }

    /// Host-originated to this one connection (rightyo#105 acknowledgements): no route, no pin.
    func deliverRequestlessReply(_ frame: Frame) async -> Bool { await deliverRoutedReply(frame) != nil }

    /// Returns the selection the reply was delivered under, so its later frames can be pinned to it (#370).
    func deliverRoutedReply(_ frame: Frame, lastInput: LastInputRoute? = nil) async -> LastInputLedger.Entry? {
        guard !ended, let prepared = prepareReplyPublication(frame),
              let delivered = await session.enqueueRoutedReply(
                frame, lastInput: lastInput, enqueue: prepared.enqueue
              ) else { return nil }
        guard await prepared.result() else {
            finish(reason: "host reply send failed")
            return nil
        }
        return delivered
    }
}

extension WebSocketListener {
    /// Publishes a correlated reply only to its requesting connection; ambiguous legacy replies reach nobody.
    /// Encoding and decoding at this trust boundary applies the same size, identity, stream, and provenance
    /// validation as a network sender; programmatically constructed mismatches cannot bypass it.
    @discardableResult
    public func publish(_ frame: Frame) async throws -> Int {
        guard !stopped, readyResult != nil else { throw WebSocketListenerError.stoppedBeforeReady }
        let validated = try validatedReply(frame)
        if await isStopped(validated) { throw LocalReplyRefusal.replyStopped }
        // Fresh host-minted UUIDs establish origin ownership. This scan is an admission snapshot,
        // not a transactional global directory or a UUID-collision proof. Never enqueue during it.
        var candidate: (WebSocketPeer, ReplyPublicationStatus)?
        for peer in Array(peers.values) {
            let status = await peer.replyPublicationStatus(validated)
            guard status != .absent else { continue }
            guard candidate == nil else { throw LocalReplyRefusal.notUniqueRecipient }
            candidate = (peer, status)
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        guard let (peer, status) = candidate else {
            let delivered = try await publishUncorrelated(validated)
            ambient?.observeReply(validated)
            return delivered
        }
        // This refusal has made zero enqueue attempts. Only this code permits bounded same-frame retry.
        guard status == .ready else { throw LocalReplyRefusal.requestPending }
        // The snapshot may already be stale. Final synchronous gates decide; later send completion
        // failure is ambiguous and must never be treated as a safe pre-publication retry.
        guard await peer.deliverHostReply(validated) else { throw LocalReplyRefusal.publicationFailed }
        ambient?.observeReply(validated) // Own-voice rejection for ambient requests (#269).
        if let peerID = peers.first(where: { $0.value === peer })?.key {
            noteRoute(validated, to: peerID, path: "request")
        }
        return 1
    }

    /// #370 audit: which path delivered a reply, once per reply (its first delivered frame). The event
    /// names only the listener connection id `session_connected` already logs and a fixed path token.
    private func noteRoute(_ frame: Frame, to peer: UUID, path: String) {
        guard let reply = HostSession.replyID(frame), lastInput.firstRoute(of: reply) else { return }
        log(WebSocketListenerEvent(event: "reply_routed", sessionID: peer, detail: "path=\(path)"))
    }

    /// Demo-era single-terminal bridge (#188): with the opt-in flag, a reply carrying no request reference
    /// reaches the one live connection selecting its target. Any explicit reference that is not currently
    /// owned keeps today's refusal, as do zero or several selecting connections; this is bounded, not a
    /// return to broadcast. The scan is a snapshot; uniqueness is not rescanned at enqueue.
    private func publishUncorrelated(_ frame: Frame) async throws -> Int {
        guard singleTerminalReplyFallback else { throw LocalReplyRefusal.noRecipient }
        if let delivered = try await publishToLastInput(frame) { return delivered }
        var candidates: [(UUID, WebSocketPeer)] = []
        for (id, peer) in Array(peers) where await peer.admitsRequestlessReply(frame) {
            candidates.append((id, peer))
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        // The whole scan completes first so the refusal code never depends on peer iteration order.
        guard candidates.count <= 1 else { throw LocalReplyRefusal.notUniqueRecipient }
        // A stop that landed during the scan made its own connection refuse, which could leave another connection
        // as the only candidate; check again before handing the reply to it.
        if await isStopped(frame) { throw LocalReplyRefusal.replyStopped }
        guard let (peerID, candidate) = candidates.first else { throw LocalReplyRefusal.noRecipient }
        guard let delivered = await candidate.deliverRoutedReply(frame) else {
            throw LocalReplyRefusal.publicationFailed
        }
        pin(frame, to: delivered)
        noteRoute(frame, to: peerID, path: "single_selector")
        return 1
    }

    /// #370: a request-less reply goes to its target's last input device, even when several devices select the
    /// target, through the same selection, permit, transport and stop gates as the single-selector path. Nil when
    /// there is no current last input device for the target (none recorded, disconnected, selected away or
    /// reselected, or expired): the single-selector rule then applies unchanged. A reply that already started on one
    /// device continues only there, and is refused rather than moved when that device is gone.
    private func publishToLastInput(_ frame: Frame) async throws -> Int? {
        guard let route = lastInputRoute(frame) else { return nil }
        guard let (peerID, peer) = peers.first(where: { $0.value.session.connectionID == route.entry.connection }),
              await peer.admitsRequestlessReply(frame, lastInput: route) else {
            if route.pinned { throw LocalReplyRefusal.noRecipient }
            return nil
        }
        try Task.checkCancellation()
        guard !stopped else { throw WebSocketListenerError.stoppedBeforeReady }
        if await isStopped(frame) { throw LocalReplyRefusal.replyStopped }
        guard let delivered = await peer.deliverRoutedReply(frame, lastInput: route) else {
            throw LocalReplyRefusal.publicationFailed
        }
        pin(frame, to: delivered)
        noteRoute(frame, to: peerID, path: "last_input")
        return 1
    }

    /// The reply's pin when it has one, else its target's last input record. Side-effect-free.
    func lastInputRoute(_ frame: Frame) -> LastInputRoute? {
        guard let target = frame.target, let reply = HostSession.replyID(frame) else { return nil }
        if let pinned = lastInput.pinned(reply, target: target) { return LastInputRoute(entry: pinned, pinned: true) }
        return lastInput.latest(for: target).map { LastInputRoute(entry: $0, pinned: false) }
    }

    private func pin(_ frame: Frame, to entry: LastInputLedger.Entry) {
        guard let target = frame.target, let reply = HostSession.replyID(frame) else { return }
        lastInput.pin(reply, target: target, to: entry)
    }

    /// A reply stopped on any connection is refused everywhere (#309), so a stop never hands the rest of it to
    /// another connection selecting its target. The listener's record outlives the connection; the per-session scan
    /// covers a stop still between its session and the listener, including one whose peer has since ended.
    private func isStopped(_ frame: Frame) async -> Bool {
        if let id = HostSession.replyID(frame), stoppedReplyIDs.contains(id) { return true }
        for session in peers.values.map(\.session) + stopsInFlight.values where await session.hasStopped(frame) {
            return true
        }
        return false
    }

    private func validatedReply(_ frame: Frame) throws -> Frame {
        guard let encoded = try? FrameCoding.encode(frame),
              let validated = try? FrameCoding.decode(encoded),
              validated == frame else {
            throw WebSocketListenerError.invalidReply
        }
        guard validated.source.compare(
            hostName, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedSame else { throw WebSocketListenerError.sourceHostMismatch }
        switch validated.payload {
        case .text(let text) where text.isFinal && text.reply != nil: break
        case .audio(let audio) where audio.reply != nil: break
        default: throw WebSocketListenerError.invalidReply
        }
        return validated
    }
}
