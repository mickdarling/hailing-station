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
    /// Suspends after preparation and immediately before final admission; absent in production.
    @TaskLocal static var beforeEnqueue: (@Sendable () async -> Void)?
    /// Holds the card-to-speech capability hop after transport completion.
    @TaskLocal static var beforeSpeechCapabilities: (@Sendable () async -> Void)?
    /// Exercises a policy transition while the first host actor validation is pending.
    @TaskLocal static var beforeAuthorityValidation: (@Sendable () async -> Void)?
}

enum SilentSessionUpdateDrainReason: String, Sendable {
    case immediate, holdCleared = "hold_cleared", recipientChanged = "recipient_changed"
}

struct SessionUpdateAudienceLease: Sendable {
    let lastInput: LastInputLedger.Entry?
    let privacyRevision: UInt64
    var taskAuthority: TaskProgressPublicationAuthority?
    var silentRecipient: SilentSessionUpdateRecipient?
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

    // Privacy gates spoken and action output; visual-only info is independent of room audio modes.
    var sessionUpdatesPrivate: Bool { ambient?.sessionUpdatesPrivate == true || replyHold.anyHeld }

    func purgePrivateSessionUpdates() {
        sessionUpdates.expire(now: .now)
        let revision = replyHold.entryRevision
        if revision != sessionUpdatePrivacyRevision || sessionUpdatesPrivate {
            // Silent info ignores privacy. Spoken/action output keeps main's discard rule.
            for update in sessionUpdates.held where !silentInfo(update.priority) {
                sessionUpdates.acknowledge(update.id)
            }
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
        await deliverSessionUpdates(trigger, connection: connection, only: id, reason: nil)
    }

    func deliverSessionUpdates(
        _ trigger: SessionUpdateDrainTrigger, connection: UUID? = nil, only id: UUID? = nil,
        reason: SilentSessionUpdateDrainReason?
    ) async -> Set<UUID> {
        var delivered: Set<UUID> = []
        defer { logSessionUpdateDrain(trigger, reason: reason, count: delivered.count) }
        await refreshTaskProgressEnvironment()
        guard sessionUpdates.policy.enabled, !stopped else { return [] }
        if sessionUpdatesDelivering {
            if sessionUpdateFence.speechStatus == "not_configured" { silentUpdateDrainPending = reason ?? .immediate }
            return []
        }
        purgePrivateSessionUpdates()
        sessionUpdatesDelivering = true
        defer {
            sessionUpdatesDelivering = false
            if let pending = silentUpdateDrainPending {
                silentUpdateDrainPending = nil
                Task.detached { await self.drainSilentSessionUpdates(pending) }
            }
        }
        var offered = sessionUpdates
        // Copying preserves the real held queue until each send completes.
        let updates = offered.drain(trigger, audience: .init(quiet: sessionUpdatesQuiet), now: .now)
        for update in updates where id == nil || update.id == id {
            if reason != nil && !silentInfo(update.priority) { continue }
            if await deliverOfferedSessionUpdate(update, connection: connection) { delivered.insert(update.id) }
        }
        return delivered
    }

    private func deliverOfferedSessionUpdate(_ update: SessionUpdate, connection: UUID?) async -> Bool {
        let silent = silentInfo(update.priority)
        purgePrivateSessionUpdates()
        guard !stopped, !sessionUpdatesQuiet, silent || !sessionUpdatesPrivate else { return false }
        guard sessionUpdates.held.contains(where: { $0.id == update.id }) else { return false }
        guard let authority = sessionUpdateTaskAuthorities[update.id] else {
            sessionUpdates.acknowledge(update.id)
            return false
        }
        authority.generation.observePolicy()
        if !authority.isCurrent {
            sessionUpdates.acknowledge(update.id)
            sessionUpdateTaskAuthorities[update.id] = nil
            return false
        }
        let audience = updateAudience(for: update.session)
        guard silent || !audience.media, let recipient = audience.target,
              connection == nil || connection == recipient,
              let peer = peers.values.first(where: { $0.session.connectionID == recipient }) else { return false }
        let last = lastInput.latest(for: update.session)
        let audienceLease = SessionUpdateAudienceLease(lastInput: last, privacyRevision: replyHold.entryRevision,
            taskAuthority: authority, silentRecipient: silent ? .init(
                connection: recipient, target: update.session, ledger: lastInput, ambient: ambient
            ) : nil)
        await SessionUpdatePrivacyScope.beforePeerHop?()
        guard await peer.deliverSessionUpdate(update, audience: audienceLease, hold: replyHold,
            ambient: ambient, fence: sessionUpdateFence, log: log,
            silentGate: silent ? silentUpdateGate : nil) else {
            if silent, audienceLease.silentRecipient?.changed == true {
                silentUpdateDrainPending = .recipientChanged
            }
            return false
        }
        sessionUpdates.acknowledge(update.id)
        sessionUpdateTaskAuthorities[update.id] = nil
        return true
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
        await SessionUpdatePrivacyScope.beforeEnqueue?()
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
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in },
        silentGate: SilentSessionUpdateGate? = nil
    ) async -> Bool {
        let privacyRevision = audience.privacyRevision, lastInput = audience.lastInput
        let stopGeneration = Mutex<UInt64?>(nil)
        guard !ended, let admission = await session.prepareSessionUpdate(update, lastInput: lastInput,
                                                                        taskAuthority: audience.taskAuthority),
              let prepared = await prepareReplyPublication(admission.frame),
              await session.enqueueSessionUpdate(admission, lastInput: lastInput, enqueue: {
                  if let silentGate {
                      return self.enqueueSilentUpdate(prepared, gates: (silentGate, fence),
                                                      recipient: audience.silentRecipient)
                  }
                  return fence.enqueue(connection: self.session.connectionID) { generation in
                      let handoff: @Sendable () -> Bool = {
                          hold.unlessAnyHeld(expectedRevision: privacyRevision) { prepared.enqueue() }
                      }
                      let admitted = ambient?.withSessionUpdatePermission(connection: self.session.connectionID,
                                                                         enqueue: handoff) ?? handoff()
                      if admitted { stopGeneration.withLock { $0 = generation } }
                      return admitted
                  }
              }) else { return false }
        guard replySendSucceeded(await prepared.result()) else { return false }
        if silentGate != nil { return true }
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
    private nonisolated func enqueueSilentUpdate(
        _ prepared: PreparedWebSocketReply, gates: (SilentSessionUpdateGate, SessionUpdateFence),
        recipient: SilentSessionUpdateRecipient?
    ) -> Bool {
        gates.0.enqueue {
            guard gates.1.speechStatus == "not_configured" else { return false }
            return recipient?.enqueue { prepared.enqueue() } ?? false
        }
    }
}

/// The quiet switch is checked at the exact handoff, including while HostSession awaits policy/registry work.
final class SilentSessionUpdateGate: Sendable {
    private struct State { var quiet = false, closed = false }
    private let state = Mutex(State())
    func setQuiet(_ quiet: Bool) { state.withLock { $0.quiet = quiet } }
    func close() { state.withLock { $0.closed = true } }
    func enqueue(_ operation: () -> Bool) -> Bool {
        state.withLock { !$0.quiet && !$0.closed && operation() }
    }
}

extension WebSocketListener {
    func silentInfo(_ priority: SessionUpdatePriority) -> Bool {
        priority == .info && sessionUpdateFence.speechStatus == "not_configured"
    }

    func drainSilentSessionUpdates(_ reason: SilentSessionUpdateDrainReason) async {
        guard sessionUpdateFence.speechStatus == "not_configured", !sessionUpdates.held.isEmpty else { return }
        _ = await deliverSessionUpdates(.interaction, reason: reason)
    }

    private func logSessionUpdateDrain(
        _ trigger: SessionUpdateDrainTrigger, reason: SilentSessionUpdateDrainReason?, count: Int
    ) {
        guard sessionUpdates.policy.enabled else { return }
        let name = reason?.rawValue
            ?? (trigger == .naturalPause ? "natural_pause" : trigger == .asked ? "asked" : "interaction")
        log(.init(event: "session_update_drained", detail: "trigger=\(name) count=\(count)"))
    }
}

/// Audience selection and the actual enqueue share the router/ledger locks, after all async preparation.
/// A rejected old recipient leaves the original queue entry intact and schedules one fresh-audience offer.
final class SilentSessionUpdateRecipient: Sendable {
    let connection: UUID
    let target: String
    let ledger: LastInputLedger
    let ambient: (any AmbientListenerWiring)?
    private let rejected = Mutex(false)
    var changed: Bool { rejected.withLock { $0 } }

    init(connection: UUID, target: String, ledger: LastInputLedger, ambient: (any AmbientListenerWiring)?) {
        (self.connection, self.target, self.ledger, self.ambient) = (connection, target, ledger, ambient)
    }

    func enqueue(_ operation: @escaping @Sendable () -> Bool) -> Bool {
        let handoff: @Sendable (UUID?) -> Bool = { listening in
            self.ledger.withLatest(for: self.target) { last in
                guard (listening ?? last?.connection) == self.connection else {
                    self.rejected.withLock { $0 = true }
                    return false
                }
                return operation()
            }
        }
        return ambient?.withSilentSessionUpdateAudience(handoff) ?? handoff(nil)
    }
}
