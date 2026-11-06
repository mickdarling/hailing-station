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
    /// Exercises a policy transition while the first host actor validation is pending.
    @TaskLocal static var beforeAuthorityValidation: (@Sendable () async -> Void)?
}

struct SessionUpdateAudienceLease: Sendable {
    let lastInput: LastInputLedger.Entry?
    let privacyRevision: UInt64
    var taskAuthority: TaskProgressPublicationAuthority?
}

/// Card-only lifetime/quiet fence; speech is not configured in this cut.
final class SessionUpdateFence: Sendable {
    private let allowed = Mutex(true)
    func close() { allowed.withLock { $0 = false } }
    func quiet() { close() }
    func enqueue(_ operation: () -> Bool) -> Bool { allowed.withLock { $0 && operation() } }
    var speechBusy: Bool { false }
    var speechStatus: String { "not_configured" }
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
        guard sessionUpdates.policy.enabled, !stopped, !sessionUpdatesDelivering else { return [] }
        purgePrivateSessionUpdates()
        guard !sessionUpdatesPrivate else { return [] }
        sessionUpdatesDelivering = true
        defer { sessionUpdatesDelivering = false }
        var offered = sessionUpdates
        // Copying preserves the real held queue until each send completes.
        let updates = offered.drain(trigger, audience: .init(quiet: sessionUpdatesQuiet), now: .now)
        var delivered: Set<UUID> = []
        for update in updates where id == nil || update.id == id {
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
            guard await peer.deliverSessionUpdate(update, audience: audienceLease, hold: replyHold,
                                                  ambient: ambient, fence: sessionUpdateFence) else { continue }
            sessionUpdates.acknowledge(update.id)
            sessionUpdateTaskAuthorities[update.id] = nil
            delivered.insert(update.id)
        }
        return delivered
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
        _ admission: SessionUpdateAdmission, lastInput: LastInputLedger.Entry?, enqueue: @Sendable () -> Bool
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
        if let authority = admission.taskAuthority {
            return authority.perform { withSessionUpdatePermit(admission, enqueue: enqueue) }
        }
        return withSessionUpdatePermit(admission, enqueue: enqueue)
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
        ambient: (any AmbientListenerWiring)?, fence: SessionUpdateFence
    ) async -> Bool {
        let privacyRevision = audience.privacyRevision, lastInput = audience.lastInput
        guard !ended, let admission = await session.prepareSessionUpdate(update, lastInput: lastInput,
                                                                        taskAuthority: audience.taskAuthority),
              let prepared = await prepareReplyPublication(admission.frame),
              await session.enqueueSessionUpdate(admission, lastInput: lastInput, enqueue: {
                  fence.enqueue {
                      let handoff: @Sendable () -> Bool = {
                          hold.unlessAnyHeld(expectedRevision: privacyRevision) { prepared.enqueue() }
                      }
                      return ambient?.withSessionUpdatePermission(connection: self.session.connectionID,
                                                                 enqueue: handoff) ?? handoff()
                  }
              }) else { return false }
        guard replySendSucceeded(await prepared.result()) else { return false }
        return true
    }
}
