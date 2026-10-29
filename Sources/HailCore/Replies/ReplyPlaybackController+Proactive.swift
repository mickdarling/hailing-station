import Foundation
import HailProtocol

@MainActor
final class ProactiveReplyPlaybackState {
    struct Identity {
        let descriptor: ReplyDescriptor
        let generation: UUID
        let expires: ContinuousClock.Instant
        var activityEpoch: UInt64?
    }
    static let limit = 32
    static let maximumBytes = 2 * 1_024 * 1_024
    static let waitingLifetime: Duration = .seconds(30)
    var identities: [ReplyStreamKey: Identity] = [:]
    var activity: ProactiveAudioActivity?
    var captureSafe: (@Sendable () -> Bool)?
    var authorize: (@MainActor (HostEndpoint.Identifier, UUID, ReplyDescriptor) -> Bool)?
    var cancelWatch: (@MainActor () -> Void)?
}

extension ReplyPlaybackController {
    func wireProactiveActivity(_ echoGuard: AmbientReplyEchoGuard) {
        proactive.activity = echoGuard.proactiveActivity
        proactive.captureSafe = { [weak echoGuard] in
            echoGuard?.isEchoCancelling == true && echoGuard?.masksDuringReplies == false
        }
        echoGuard.proactiveActivity.onChange { [weak self] in
            Task { @MainActor in self?.recheckProactivePlayback() }
        }
    }

    func enqueueStreamIfNeeded(_ key: ReplyStreamKey, descriptor: ReplyDescriptor) {
        guard streams[key] == nil else { return }
        if descriptor.sessionUpdateID == nil { supersedePausedReplies() }
        queue.append(key)
    }

    func beginPlaybackIfNeeded(_ key: ReplyStreamKey, begins: Bool) -> Bool {
        guard begins else { return true }
        if proactive.identities[key] != nil {
            guard let epoch = proactive.activity?.quietEpoch, proactive.captureSafe?() == true else { return false }
            if let admitted = proactive.identities[key]?.activityEpoch, admitted != epoch { return false }
            proactive.identities[key]?.activityEpoch = epoch
        }
        playbackOrder.append(key)
        if activeKey == nil { activeKey = key }
        return true
    }

    func prepareDrain() -> Bool {
        guard admitProactiveHead() else { return false }
        watchHeadIfChanged() // before any segment of a new head is scheduled (#469)
        guard segmentBoundary == nil else { return false }
        dropAbandonedHold()
        applyPendingMuteIfDue()
        return true
    }

    /// Explicitly marked audio can never fall through to ordinary replies when a receipt was dropped or evicted.
    func acceptProactiveFrame(_ event: HostReplyEvent, descriptor: ReplyDescriptor) -> Bool {
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        guard let update = descriptor.sessionUpdateID else { return proactive.identities[key] == nil }
        guard streams[key] == nil || proactive.identities[key] != nil else { return false }
        guard update == descriptor.id, descriptor.requestID == nil, descriptor.priority == .background,
              descriptor.interruption == .enqueue, event.frame.source == descriptor.hostID,
              event.frame.target == descriptor.targetID, case .audio(let audio) = event.frame.payload,
              let generation = HostNoticeOrigin.generation, !completed.contains(key),
              proactive.authorize?(event.endpointID, generation, descriptor) == true else { return false }
        proactive.identities = proactive.identities.filter { !completed.contains($0.key) || $0.key == lastKey }
        if let existing = proactive.identities[key] {
            guard existing.generation == generation, existing.descriptor == descriptor else { return false }
        } else {
            guard proactive.identities.count < ProactiveReplyPlaybackState.limit else { return false }
            proactive.identities[key] = .init(descriptor: descriptor, generation: generation,
                expires: idleNow().advanced(by: ProactiveReplyPlaybackState.waitingLifetime), activityEpoch: nil)
        }
        let stored = streams[key]?.segments.values.reduce(0) { $0 + $1.bytes.count } ?? 0
        let added = streams[key]?.segments[audio.sequence] == nil ? audio.bytes.count : 0
        guard stored + added <= ProactiveReplyPlaybackState.maximumBytes else {
            retireProactive(key)
            return false
        }
        return true
    }

    private func proactivePolicyAllows(_ key: ReplyStreamKey) -> Bool {
        guard let identity = proactive.identities[key], idleNow() < identity.expires else { return false }
        if let epoch = identity.activityEpoch, proactive.activity?.epoch != epoch { return false }
        return proactive.authorize?(key.endpointID, identity.generation, identity.descriptor) == true
    }

    private var proactiveQuiet: Bool {
        proactive.activity?.isQuiet == true && proactive.captureSafe?() == true
            && !isCaptureSuppressed && !isPaused && !isMuted && !idleWatch.audioInterrupted
    }

    /// Re-evaluated at admission and after real capture/policy events. Ordinary replies preserve their own FIFO.
    func admitProactiveHead() -> Bool {
        for key in queue where proactive.identities[key] != nil && !proactivePolicyAllows(key) {
            retireProactive(key)
        }
        guard let head = queue.first, proactive.identities[head] != nil else { return true }
        guard proactiveQuiet else {
            if activeKey == head { retireProactive(head); return true }
            // A deferred unsolicited update never prevents an ordinary answer from reaching the player.
            if let index = queue.firstIndex(where: { proactive.identities[$0] == nil }) {
                let ordinary = queue.remove(at: index)
                queue.insert(ordinary, at: 0)
                return true
            }
            setPresentationStatus("Waiting for a measured pause", for: head)
            return false
        }
        if activeKey != nil && activeKey != head { return false }
        armProactiveWatch()
        return true
    }

    /// Check before an existing proactive buffer can become audible, including synchronous UI restoration paths.
    /// Pause/mute are intentionally omitted here because the caller is restoring precisely that owner control.
    func prepareProactiveAudibility() -> Bool {
        guard let key = activeKey, let identity = proactive.identities[key] else { return true }
        guard let epoch = proactive.activity?.quietEpoch, identity.activityEpoch == epoch,
              proactivePolicyAllows(key), proactive.captureSafe?() == true,
              !isCaptureSuppressed, !idleWatch.audioInterrupted else {
            retireProactive(key)
            return false
        }
        armProactiveWatch()
        return true
    }

    /// A deliberate Replay uses the original, unrenewed receipt and still respects current output policy.
    func allowProactiveReplay() -> Bool {
        guard lastAudio.first?.reply?.sessionUpdateID != nil else { return true }
        guard let lastKey, let epoch = proactive.activity?.quietEpoch,
              proactive.identities[lastKey]?.activityEpoch == epoch,
              proactivePolicyAllows(lastKey), proactiveQuiet else {
            status = "Update available in conversation"
            return false
        }
        armProactiveWatch()
        return true
    }

    /// A fresh sound, missing capture or policy change retires only unsolicited speech; its card remains visible.
    public func recheckProactivePlayback() {
        for key in queue where proactive.identities[key] != nil && !proactivePolicyAllows(key) {
            retireProactive(key)
        }
        if let activeKey, proactive.identities[activeKey] != nil,
           !proactivePolicyAllows(activeKey) || !proactiveQuiet { retireProactive(activeKey) }
        drain()
    }

    private func retireProactive(_ key: ReplyStreamKey) {
        if activeKey == key {
            player.cancel()
            playbackGeneration &+= 1
            playbackOrder.removeAll { $0 == key }
            activeKey = playbackOrder.first
        }
        cancelFirstAudio(for: [key])
        streams[key] = nil
        queue.removeAll { $0 == key }
        completed.insert(key)
        proactive.identities[key] = nil
        setPresentationStatus("Update available in conversation", for: key)
    }

    private func armProactiveWatch() {
        proactive.cancelWatch?()
        proactive.cancelWatch = nil
        guard let deadline = proactive.activity?.validUntil else { return }
        proactive.cancelWatch = idleScheduler(max(.zero, idleNow().duration(to: deadline))) { [weak self] in
            guard let self else { return }
            self.proactive.cancelWatch = nil
            self.recheckProactivePlayback()
        }
    }
}
