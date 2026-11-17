public import Foundation
import HailProtocol
import Synchronization

// Card preparation and its final exact-peer enqueue remain one review boundary.
// swiftlint:disable file_length

/// A task report retains the privacy epoch of the status solicitation that produced it. It cannot disclose old
/// output after a privacy on/off pair, and it grants no delivery or request authority.
enum SessionUpdatePrivacyScope {
    @TaskLocal static var expectedRevision: UInt64?
    /// Deterministic actor-hop interleaving seam; absent in production.
    @TaskLocal static var beforePeerHop: (@Sendable () async -> Void)?
    /// Holds the card-to-speech capability hop after transport completion.
    @TaskLocal static var beforeSpeechCapabilities: (@Sendable () async -> Void)?
    /// Exercises a policy transition while the first host actor validation is pending.
    @TaskLocal static var beforeAuthorityValidation: (@Sendable () async -> Void)?
}

struct SessionUpdateAudienceLease: Sendable {
    let lastInput: LastInputLedger.Entry?
    let privacyRevision: UInt64
    var taskAuthority: TaskProgressPublicationAuthority?
}

extension WebSocketListener {
    /// Each submission retains its original source identity and continuous policy generation, including ordinary
    /// notify. A task report uses the solicitation's authority; this admission must never upgrade it to a new grant.
    func sessionUpdateAuthority(for target: String) async -> TaskProgressPublicationAuthority? {
        let authority: TaskProgressPublicationAuthority
        if let original = TaskProgressPublicationScope.authority { authority = original } else {
            // Observe an external owner grant even when the cached target has no binding. This is a fresh
            // submission only; an existing task authority is never replaced by the newly observed policy.
            do { try host.targetPolicy.refreshIfChanged() } catch { return nil }
            // Snapshot before the first actor hop. A policy replacement while preflight waits must never
            // turn words submitted under the old source into an update from a newly allowed binding.
            let generation = host.targetPolicy.snapshot(for: target)
            guard let binding = generation.binding else { return nil }
            authority = .init(generation: generation, binding: binding)
        }
        await SessionUpdatePrivacyScope.beforeAuthorityValidation?()
        do { try await host.requireSendPreflight() } catch { return nil }
        guard let policy = await host.refreshedPolicy(), let allowed = policy.targets[target],
              allowed.tier != .locked, authority.generation.target == target, authority.isCurrent,
              authority.generation.binding == allowed.binding, authority.binding == allowed.binding else { return nil }
        return authority
    }

    var sessionUpdatesPrivate: Bool { replyHold.anyHeld || ambient?.sessionUpdatesPrivate == true }

    func purgePrivateSessionUpdates() {
        sessionUpdates.expire(now: .now)
        let revision = replyHold.entryRevision
        if revision != sessionUpdatePrivacyRevision || sessionUpdatesPrivate {
            sessionUpdates.discardHeld()
            sessionUpdatePrivacyRevision = revision
        }
        let kept = Set(sessionUpdates.held.map(\.id))
        sessionUpdateTaskAuthorities = sessionUpdateTaskAuthorities.filter { kept.contains($0.key) }
    }

    /// Content-free availability for the task cadence controller. Actual publication repeats every gate.
    public func sessionUpdatePauseReason(for target: String) async -> String? {
        guard sessionUpdates.policy.enabled else { return "not_enabled" }
        guard !stopped else { return "stopping" }
        purgePrivateSessionUpdates()
        if sessionUpdatesPrivate { return "private" }
        if sessionUpdatesQuiet { return "quiet" }
        let audience = updateAudience(for: target)
        guard let connection = audience.target,
              let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_device"
        }
        if audience.media { return "media" }
        if sessionUpdateFence.speechBusy { return "playback" }
        guard await peer.isLive, await peer.session.canReceiveSessionUpdate(target: target,
            lastInput: lastInput.latest(for: target)) else { return "unavailable_recipient" }
        return nil
    }

    /// Offers a snapshot without removing it. An acknowledgement consumes only a completed exact-peer send.
    /// A second event while a send is outstanding coalesces into the next real event, never another sender.
    @discardableResult
    public func drainSessionUpdates(
        _ trigger: SessionUpdateDrainTrigger, connection: UUID? = nil, only id: UUID? = nil
    ) async -> Set<UUID> {
        await deliverSessionUpdates(trigger, connection: connection, only: id, settle: nil)
    }

    private func deliverSessionUpdates(
        _ trigger: SessionUpdateDrainTrigger, connection: UUID?, only id: UUID?, settle: SessionUpdateSettleLease?
    ) async -> Set<UUID> {
        var delivered: Set<UUID> = []
        defer { logSessionUpdateDrain(trigger, count: delivered.count, settle: settle != nil) }
        await refreshTaskProgressEnvironment()
        guard sessionUpdates.policy.enabled, !stopped, !sessionUpdatesDelivering else { return [] }
        purgePrivateSessionUpdates()
        guard !sessionUpdatesPrivate else { return [] }
        sessionUpdatesDelivering = true
        defer { finishSessionUpdateDrain() }
        var offered = sessionUpdates
        // Copying preserves the real held queue until each send completes.
        let updates = offered.drain(trigger, audience: .init(quiet: sessionUpdatesQuiet), now: .now)
        for update in updates where id == nil || update.id == id {
            guard permitsSettleUpdate(update, connection: connection, settle: settle) else { continue }
            purgePrivateSessionUpdates()
            guard !stopped, !sessionUpdatesQuiet, !sessionUpdatesPrivate else { break }
            guard sessionUpdates.held.contains(where: { $0.id == update.id }) else { continue }
            guard let authority = sessionUpdateTaskAuthorities[update.id] else {
                sessionUpdates.acknowledge(update.id)
                continue
            }
            authority.generation.observePolicy()
            if !authority.isCurrent {
                sessionUpdates.acknowledge(update.id)
                sessionUpdateTaskAuthorities[update.id] = nil
                continue
            }
            let audience = updateAudience(for: update.session)
            guard !audience.media, let recipient = audience.target,
                  connection == nil || connection == recipient,
                  let peer = peers.values.first(where: { $0.session.connectionID == recipient }) else { continue }
            let last = lastInput.latest(for: update.session)
            let audienceLease = SessionUpdateAudienceLease(lastInput: last, privacyRevision: replyHold.entryRevision,
                                                           taskAuthority: authority)
            await SessionUpdatePrivacyScope.beforePeerHop?()
            guard await deliverSessionUpdate(update, to: peer, audience: audienceLease, settle: settle)
                else { continue }
            sessionUpdates.acknowledge(update.id)
            sessionUpdateTaskAuthorities[update.id] = nil
            delivered.insert(update.id)
        }
        return delivered
    }
}

extension WebSocketListener {
    private func finishSessionUpdateDrain() {
        sessionUpdatesDelivering = false
        if sessionUpdateSettleDeferred {
            sessionUpdateSettleDeferred = false
            Task { await self.refreshSessionUpdateSettles() }
        }
    }

    private func logSessionUpdateDrain(_ trigger: SessionUpdateDrainTrigger, count: Int, settle: Bool) {
        guard sessionUpdates.policy.enabled else { return }
        let name = settle ? "settle" : trigger == .naturalPause ? "natural_pause"
            : trigger == .asked ? "asked" : "interaction"
        log(.init(event: "session_update_drained", detail: "trigger=\(name) count=\(count)"))
    }

    private func deliverSessionUpdate(
        _ update: SessionUpdate, to peer: WebSocketPeer, audience: SessionUpdateAudienceLease,
        settle: SessionUpdateSettleLease?
    ) async -> Bool {
        await peer.deliverSessionUpdate(update, audience: audience,
            delivery: .init(hold: replyHold, ambient: ambient, fence: sessionUpdateFence, log: log, settle: settle))
    }

    private func permitsSettleUpdate(
        _ update: SessionUpdate, connection: UUID?, settle: SessionUpdateSettleLease?
    ) -> Bool {
        guard let lease = settle else { return true }
        guard update.priority == .info, let connection else { return false }
        return sessionUpdateSettleAllowed(connection: connection) && lease.activity.permits(lease, enqueue: { true })
    }
}

extension HostSession {
    func canReceiveSessionUpdate(target: String, lastInput: LastInputLedger.Entry?) -> Bool {
        guard case .ready = state, peerCapabilities.contains(SessionUpdateCard.capability) else { return false }
        if selectedTarget == target { return true }
        guard let lastInput, lastInput.connection == connectionID,
              lastInput.generation == selectionGeneration, covers(target) else { return false }
        let age = lastInput.at.duration(to: requestClock())
        return age >= .zero && age < LastInputLedger.lifetime
    }

    /// The selected audience, exact registry binding, current policy permit, privacy and transport enqueue are
    /// checked afresh. The route never creates or renews a request, and never falls back to another connection.
    func prepareSessionUpdate(
        _ update: SessionUpdate, lastInput: LastInputLedger.Entry?,
        taskAuthority: TaskProgressPublicationAuthority? = nil
    ) async -> SessionUpdateAdmission? {
        guard await host.refreshedPolicy() != nil,
              canReceiveSessionUpdate(target: update.session, lastInput: lastInput) else { return nil }
        let generation = selectionGeneration
        guard let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == update.session && $0.info.alive }),
              let bindingID = listed.binding, let label = SessionUpdateCard.session(listed.info.name),
              let binding = try? ProviderSessionBinding(
                hostID: hostName, providerID: listed.info.kind, targetID: update.session, sessionID: bindingID
              ) else { return nil }
        if let taskAuthority {
            guard taskAuthority.isCurrent, taskAuthority.generation.target == update.session,
                  taskAuthority.binding == bindingID else { return nil }
        }
        let lease: ProviderReplyBindingLease?
        do {
            lease = try await host.registry.acquireReplyBindingLease(binding)
        } catch RegistryError.replyBindingLeaseUnsupported {
            lease = nil
        } catch { return nil }
        guard await host.refreshedPolicy() != nil,
              let permit = await host.replyPublicationPermit(for: binding),
              generation == selectionGeneration,
              canReceiveSessionUpdate(target: update.session, lastInput: lastInput),
              case .ready(let version) = state else { return nil }
        var frame = response(.sessionUpdate(update: update.id, session: label, priority: update.priority.rawValue,
                                             text: update.spoken, card: update.card), version: version)
        frame.target = update.session
        return SessionUpdateAdmission(frame: frame, generation: generation, permit: permit, binding: binding,
                                      bindingLease: lease, taskAuthority: taskAuthority)
    }

    func enqueueSessionUpdate(
        _ admission: SessionUpdateAdmission, lastInput: LastInputLedger.Entry?,
        admittingAudio: Bool = false, enqueue: @Sendable () -> Bool
    ) async -> Bool {
        guard await host.refreshedPolicy() != nil else { return false }
        if admission.bindingLease == nil {
            // Legacy tmux has no cooperative output lease, matching the existing request-less reply boundary.
            // This is a fresh listing snapshot, not a promise that an external tmux binding cannot change later.
            guard let listing = try? await host.registry.listing(), listing.contains(where: {
                $0.info.id == admission.binding.targetID && $0.info.alive && $0.binding == admission.binding.sessionID
            }) else { return false }
        }
        admission.taskAuthority?.generation.observePolicy()
        guard !Task.isCancelled, admission.generation == selectionGeneration,
              let target = admission.frame.target,
              canReceiveSessionUpdate(target: target, lastInput: lastInput) else { return false }
        let admitted: Bool
        if let authority = admission.taskAuthority {
            admitted = authority.perform { withSessionUpdatePermit(admission, enqueue: enqueue) }
        } else {
            admitted = withSessionUpdatePermit(admission, enqueue: enqueue)
        }
        // Share the stop boundary's actor turn: new audio invalidates coalescing before any send-result await.
        // Cards and renderer preflight do not admit audio, including when their enqueue succeeds.
        if admitted && admittingAudio { replyFlightRevision &+= 1 }
        return admitted
    }

    private func withSessionUpdatePermit(
        _ admission: SessionUpdateAdmission, enqueue: @Sendable () -> Bool
    ) -> Bool {
        admission.permit.performIfCurrent {
            if let lease = admission.bindingLease { return lease.performIfCurrent(enqueue) == true }
            return enqueue()
        } == true
    }
}

struct SessionUpdateAdmission: Sendable {
    let frame: Frame
    let generation: UUID
    let permit: ReplyPublicationPermit
    let binding: ProviderSessionBinding
    let bindingLease: ProviderReplyBindingLease?
    let taskAuthority: TaskProgressPublicationAuthority?
}

extension WebSocketPeer {
    func deliverSessionUpdate(
        _ update: SessionUpdate, audience: SessionUpdateAudienceLease, hold: PrivateReplyHold,
        ambient: (any AmbientListenerWiring)?, fence: SessionUpdateFence,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }
    ) async -> Bool {
        await deliverSessionUpdate(update, audience: audience,
            delivery: .init(hold: hold, ambient: ambient, fence: fence, log: log, settle: nil))
    }

    fileprivate func deliverSessionUpdate(
        _ update: SessionUpdate, audience: SessionUpdateAudienceLease, delivery: SessionUpdateCardDelivery
    ) async -> Bool {
        let (hold, ambient, fence) = (delivery.hold, delivery.ambient, delivery.fence)
        let (log, settle) = (delivery.log, delivery.settle)
        let privacyRevision = audience.privacyRevision, lastInput = audience.lastInput
        let stopGeneration = Mutex<UInt64?>(nil)
        guard !ended, let admission = await session.prepareSessionUpdate(update, lastInput: lastInput,
                                                                        taskAuthority: audience.taskAuthority),
              let prepared = await prepareReplyPublication(admission.frame),
              await session.enqueueSessionUpdate(admission, lastInput: lastInput, enqueue: {
                  if settle != nil && fence.speechStatus != "not_configured" { return false }
                  return fence.enqueue(connection: self.session.connectionID) { generation in
                      let handoff: @Sendable () -> Bool = {
                          enqueueSessionUpdateCard(prepared, hold: hold, privacyRevision: privacyRevision,
                                                   settle: settle)
                      }
                      let admitted = withSessionUpdateCardPermission(ambient, connection: self.session.connectionID,
                          settle: settle != nil, enqueue: handoff)
                      if admitted { stopGeneration.withLock { $0 = generation } }
                      return admitted
                  }
              }) else { return false }
        guard replySendSucceeded(await prepared.result()) else { return false }
        // A settle lease is visual-only even if a renderer is configured after the card's enqueue.
        if settle != nil { return true }
        await SessionUpdatePrivacyScope.beforeSpeechCapabilities?()
        if await session.peerCapabilities.contains(SessionUpdateCard.audioCapability),
           let generation = stopGeneration.withLock({ $0 }) {
            let connection = session.connectionID
            fence.startSpeech(connection: connection, privacyRevision: privacyRevision, stopGeneration: generation,
                onStopped: { reason in
                    let event = reason == "stopped_running" ? "session_update_speech_revoked"
                        : "session_update_speech_cancelled"
                    log(WebSocketListenerEvent(event: event, sessionID: connection,
                        detail: "reason=\(reason) update=\(update.id)"))
                }, { renderer in
                    let delivery = SessionUpdateSpeechDelivery(admission: admission, lastInput: lastInput,
                        privacyRevision: privacyRevision, hold: hold, ambient: ambient, fence: fence)
                    await self.speakSessionUpdate(update, delivery: delivery, renderer: renderer)
                })
        }
        return true
    }
}

/// Shared synchronous activity fence; contains timing and counts only, never transcript or reply content.
final class SessionUpdateSettleActivity: Sendable {
    struct Snapshot: Sendable { let revision: UInt64; let at: ContinuousClock.Instant; let playing: Bool }
    private struct State {
        var clock = TaskProgressClock.continuous
        var at = ContinuousClock.now
        var revision: UInt64 = 0
        var playing = false, closed = false
        var pendingInputs = 0
        var notify: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    static func configuredMilliseconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment["HAIL_SESSION_UPDATE_SETTLE_MS"], let value = Int(raw),
              (2_000...120_000).contains(value) else { return 8_000 }
        return value
    }

    func observe(clock: TaskProgressClock, notify: @escaping @Sendable () -> Void) {
        state.withLock { value in
            value.clock = clock
            value.at = clock.now()
            value.notify = notify
        }
    }

    func changed() { change { _ in } }
    func playback(_ playing: Bool) { change { $0.playing = playing } }
    func beginInput() { change { $0.pendingInputs += 1 } }
    func endInput() { change { $0.pendingInputs = max(0, $0.pendingInputs - 1) } }
    func endInput(if pending: Bool) { if pending { endInput() } }
    func beginFinalInput(_ frame: Frame) -> Bool {
        guard case .text(let text) = frame.payload, text.isFinal else { return false }
        beginInput()
        return true
    }

    private func change(_ mutation: (inout State) -> Void) {
        let notify = state.withLock { value -> (@Sendable () -> Void)? in
            guard !value.closed else { return nil }
            value.revision &+= 1
            value.at = value.clock.now()
            mutation(&value)
            return value.notify
        }
        notify?()
    }

    /// A start blocks before the diagnostic-log hop; only an admitted end can clear that conservative hold.
    func beginPlaybackEvents(_ events: [DiagnosticEvent]) {
        if events.contains(where: { $0.name == .replyPlaybackStart }) {
            playback(true)
        } else if events.contains(where: { $0.name == .replyPlaybackEnd || $0.name == .replyPlaybackError }) {
            changed()
        }
    }

    func playbackEvents(_ events: [DiagnosticEvent]) {
        for event in events {
            switch event.name {
            case .replyPlaybackStart: playback(true)
            case .replyPlaybackEnd, .replyPlaybackError: playback(false)
            default: break
            }
        }
    }

    func close() {
        state.withLock { $0.closed = true; $0.revision &+= 1; $0.notify = nil }
    }

    var snapshot: Snapshot? {
        state.withLock { value in
            value.closed ? nil : Snapshot(revision: value.revision, at: value.at,
                                          playing: value.playing || value.pendingInputs > 0)
        }
    }

    func permits(_ lease: SessionUpdateSettleLease, enqueue: () -> Bool) -> Bool {
        state.withLock { value in
            guard !value.closed, !value.playing, value.pendingInputs == 0, value.revision == lease.revision,
                  value.clock.now() >= lease.due else { return false }
            return enqueue()
        }
    }
}

struct SessionUpdateSettleLease: Sendable {
    let activity: SessionUpdateSettleActivity
    let revision: UInt64
    let due: ContinuousClock.Instant
}

struct SessionUpdateSettleTimer {
    let revision: UInt64
    let due: ContinuousClock.Instant
    let task: Task<Void, Never>
}

/// Explicit publication context: a settle lease cannot escape into unrelated tasks or cadence callbacks.
private struct SessionUpdateCardDelivery: Sendable {
    let hold: PrivateReplyHold
    let ambient: (any AmbientListenerWiring)?
    let fence: SessionUpdateFence
    let log: @Sendable (WebSocketListenerEvent) -> Void
    let settle: SessionUpdateSettleLease?
}

extension HostSession {
    /// Pending/admitted requests block until completion or their existing correlation lifetime expires. A single
    /// expiry deadline replaces polling. Repeated frames/admission changes invalidate the final enqueue lease.
    func sessionUpdateSettleLease(interval: Duration, now: ContinuousClock.Instant) -> SessionUpdateSettleLease? {
        guard case .ready = state, repliesInFlight.isEmpty,
              let snapshot = sessionUpdateActivity.snapshot, !snapshot.playing else { return nil }
        var due = max(now, snapshot.at) + interval
        for request in replyRequests.values where !request.audioFinished && request.providerTurnEndedAt == nil {
            guard request.isCurrent(at: requestClock()) else { continue }
            var end = request.createdAt + HostReplyRequest.lifetime
            if request.isProviderTurn { end = request.createdAt + HostReplyRequest.providerTurnBound }
            if request.committed && request.firstFrameAt == nil {
                end = max(end, request.createdAt + HostReplyRequest.lateAnswerBound)
            }
            if let first = request.firstFrameAt, let last = request.lastFrameAt {
                end = max(end, min(first + HostReplyRequest.streamCap, last + HostReplyRequest.streamIdleGap))
            }
            due = max(due, end + interval)
        }
        return .init(activity: sessionUpdateActivity, revision: snapshot.revision, due: due)
    }

    func sessionUpdateHasPendingRequest() -> Bool {
        replyRequests.values.contains {
            !$0.audioFinished && $0.providerTurnEndedAt == nil && $0.isCurrent(at: requestClock())
        } || !repliesInFlight.isEmpty
    }
}

extension WebSocketListener {
    func observeSessionUpdateActivity(_ session: HostSession) {
        guard sessionUpdates.policy.enabled, sessionUpdateFence.speechStatus == "not_configured" else { return }
        let connection = session.connectionID
        session.sessionUpdateActivity.observe(clock: sessionUpdateSettleClock) { [weak self] in
            Task { await self?.refreshSessionUpdateSettles() }
        }
        #if os(macOS)
        (ambient as? AmbientRightyoRouter)?.observeSessionUpdateActivity(session.sessionUpdateActivity,
                                                                        connection: connection)
        #endif
    }

    func sessionUpdateModesChanged() {
        for peer in peers.values { peer.session.sessionUpdateActivity.changed() }
    }

    func sessionUpdateSettleAllowed(connection: UUID) -> Bool {
        guard !stopped, sessionUpdates.policy.enabled, !sessionUpdatesQuiet, !sessionUpdatesPrivate,
              sessionUpdateFence.speechStatus == "not_configured" else { return false }
        return withSessionUpdateCardPermission(ambient, connection: connection, settle: true, enqueue: { true })
    }

    /// Queue changes, activity and mode transitions drive one cancellable deadline per exact connection.
    func refreshSessionUpdateSettles() async {
        let recipients = Set(sessionUpdates.held.filter { $0.priority == .info }.compactMap {
            updateAudience(for: $0.session).target
        })
        for connection in Array(sessionUpdateSettles.keys) where !recipients.contains(connection)
            || !sessionUpdateSettleAllowed(connection: connection) {
            sessionUpdateSettles.removeValue(forKey: connection)?.task.cancel()
        }
        for connection in recipients {
            guard sessionUpdateSettleAllowed(connection: connection),
                  let peer = peers.values.first(where: { $0.session.connectionID == connection }) else { continue }
            let existing = sessionUpdateSettles[connection]
            // Keep an unchanged timer's original due time; a refresh must not extend an idle interval.
            if existing?.revision == peer.session.sessionUpdateActivity.snapshot?.revision { continue }
            sessionUpdateSettles.removeValue(forKey: connection)?.task.cancel()
            guard let lease = await peer.session.sessionUpdateSettleLease(interval: sessionUpdateSettleInterval,
                now: sessionUpdateSettleClock.now()), sessionUpdateSettleAllowed(connection: connection),
                  peer.session.sessionUpdateActivity.snapshot?.revision == lease.revision else { continue }
            guard sessionUpdateSettles[connection] == nil,
                  sessionUpdates.held.contains(where: {
                      $0.priority == .info && updateAudience(for: $0.session).target == connection
                  }) else { continue }
            let clock = sessionUpdateSettleClock, didFire = sessionUpdateSettleDidFire
            let task = Task { [weak self] in
                do { try await clock.sleepUntil(lease.due) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.sessionUpdateSettleFired(connection: connection, lease: lease)
                didFire?()
            }
            sessionUpdateSettles[connection] = .init(revision: lease.revision, due: lease.due, task: task)
        }
    }

    func sessionUpdateSettleFired(connection: UUID, lease: SessionUpdateSettleLease) async {
        guard sessionUpdateSettles[connection]?.revision == lease.revision,
              sessionUpdateSettles[connection]?.due == lease.due else { return }
        sessionUpdateSettles[connection] = nil
        if sessionUpdatesDelivering {
            sessionUpdateSettleDeferred = true
            return // The existing sender's completion schedules one fresh deadline, never a retry poll.
        }
        guard sessionUpdateSettleAllowed(connection: connection),
              lease.activity.permits(lease, enqueue: { true }),
              let peer = peers.values.first(where: { $0.session.connectionID == connection }),
              await !peer.session.sessionUpdateHasPendingRequest() else { return }
        // Reuse natural-pause queue policy with an explicit, non-inheritable per-delivery lease.
        _ = await deliverSessionUpdates(.naturalPause, connection: connection, only: nil, settle: lease)
    }
}

/// Preserve the normal card path; silent settle additionally excludes the router's meeting state.
private func withSessionUpdateCardPermission(
    _ ambient: (any AmbientListenerWiring)?, connection: UUID, settle: Bool, enqueue: @Sendable () -> Bool
) -> Bool {
    #if os(macOS)
    if settle, let router = ambient as? AmbientRightyoRouter {
        return router.withSilentSessionUpdatePermission(connection: connection, enqueue: enqueue)
    }
    #endif
    return ambient?.withSessionUpdatePermission(connection: connection, enqueue: enqueue) ?? enqueue()
}

/// The activity lock encloses only the prepared synchronous handoff, inside the existing privacy/router gates.
private func enqueueSessionUpdateCard(
    _ prepared: PreparedWebSocketReply, hold: PrivateReplyHold, privacyRevision: UInt64,
    settle: SessionUpdateSettleLease?
) -> Bool {
    hold.unlessAnyHeld(expectedRevision: privacyRevision) {
        if let lease = settle {
            return lease.activity.permits(lease) { prepared.enqueue() }
        }
        return prepared.enqueue()
    }
}
