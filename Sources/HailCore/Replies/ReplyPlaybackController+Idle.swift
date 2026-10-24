import Foundation
import HailProtocol
extension ReplyPlaybackController {
    /// A stream whose terminal marker never comes (haild crashed, the Mac slept, its request expired mid-reply) would
    /// hold the head of the queue until Stop (#469). Once its scheduled audio has played out and this long passes
    /// with no new frame of its own, it is ended and the queue moves on. A live paced reply stays up to 20 s ahead of
    /// playback and sends a frame every second; every frame keeps a slower stream alive.
    public static let streamIdleTimeout: Duration = .seconds(20)
    // longer than any realistic queue; a reply queued behind more than 10 min of other audio is claimed lost (#825)
    static let firstAudioMaxWait: Duration = .seconds(600)
    nonisolated static let abandonedStatus = "Ended without its final audio"
    /// The head's segment was handed to the player: its audio now runs out that much later, after anything ahead.
    /// While held nothing plays, so it joins the held audio, which all plays once the hold ends (Codex P1 on #473).
    func noteScheduled(_ segment: AudioPayload) {
        let duration = Duration.seconds(Self.seconds(of: segment))
        if let held = idleWatch.heldRemaining { return idleWatch.heldRemaining = held + duration }
        let start = max(idleNow(), idleWatch.bufferedUntil, idleWatch.aheadUntil)
        idleWatch.bufferedUntil = start.advanced(by: duration)
    }
    func noteReplay(_ payloads: [AudioPayload]) {
        let total = Duration.seconds(payloads.reduce(0) { $0 + Self.seconds(of: $1) })
        idleWatch.aheadUntil = idleNow().advanced(by: total)
        if let held = idleWatch.heldRemaining { idleWatch.heldRemaining = held + total }
        armIdleWatch()
    }
    nonisolated static let interruptionNotification = Notification.Name("AVAudioSessionInterruptionNotification")
    nonisolated static let interruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
    nonisolated static let interruptionOptionKey = "AVAudioSessionInterruptionOptionKey"
    nonisolated static let foregroundNotification = Notification.Name("UIApplicationWillEnterForegroundNotification")
    /// Follows interruptions on `center`, by name so it works wherever the controller runs. A begin (type 1) holds the
    /// watch. An end with `shouldResume` releases it: reply-only playback and the keepalive activate the session
    /// themselves, so no managed-session result may come (Codex P1 on #478). An end without it keeps the hold. When
    /// the managed session resumes playback (`follow`) it releases too, and so does the foreground.
    func observeAudioInterruptions(on center: NotificationCenter) {
        _ = center.addObserver(forName: Self.foregroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard Thread.isMainThread else {
                Task { @MainActor in self?.audioInterruption(began: false) }
                return
            }
            MainActor.assumeIsolated { self?.audioInterruption(began: false) }
        }
        _ = center.addObserver(forName: Self.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let began = (note.userInfo?[Self.interruptionTypeKey] as? UInt) == 1
            let shouldResume = ((note.userInfo?[Self.interruptionOptionKey] as? UInt) ?? 0) & 1 == 1
            guard began || shouldResume else { return }
            guard Thread.isMainThread else {
                Task { @MainActor in self?.audioInterruption(began: began) }
                return
            }
            MainActor.assumeIsolated { self?.audioInterruption(began: began) }
        }
    }
    /// Follows `session`'s events for as long as the caller's task runs: an interruption holds the idle watch until
    /// the session reports playback resumed. An end without a resume (or a failed reactivation) leaves the player
    /// stopped, so the hold stays until a later resume or the app comes to the foreground (Codex round 5, #469).
    public func follow(_ session: any AudioSessionDiagnosticsProviding) async {
        for await event in await session.events {
            guard !Task.isCancelled else { return }
            noteAudioSession(event)
        }
    }
    func noteAudioSession(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan: audioInterruption(began: true)
        case .interruptionEnded(resumed: true): audioInterruption(began: false)
        case .interruptionEnded(resumed: false), .routeChanged: break
        }
    }
    func audioInterruption(began: Bool) {
        idleWatch.audioInterrupted = began
        syncIdleHold()
    }
}

extension ReplyPlaybackController {
    /// Drains after `key`'s frame arrived; if it is the head's, the head is alive and its timeout starts again.
    func drain(noting key: ReplyStreamKey) {
        drain()
        if queue.first == key { noteHeadFrame() }
    }
    func noteHeadFrame() {
        idleWatch.lastFrameAt = idleNow()
        armIdleWatch()
    }
    /// A new head (or none) starts its own watch; frames of other streams never extend the head's.
    func watchHeadIfChanged() {
        syncIdleHold()
        guard queue.first != idleWatch.key else { return }
        idleWatch.key = queue.first
        idleWatch.bufferedUntil = idleNow()
        idleWatch.lastFrameAt = idleNow()
        idleWatch.heldRemaining = isIdleHeld ? .zero : nil
        armIdleWatch()
    }
    var isIdleHeld: Bool { isPaused || isCaptureSuppressed || idleWatch.audioInterrupted }
    func idleDeadline() -> ContinuousClock.Instant { idleDeadline(idleWatch) }
    /// Paused, listening or interrupted, the player holds its audio (Codex P1s on #473): the unplayed duration
    /// (a replay's included) is kept and the watch stops, then it resumes with that still to play.
    func syncIdleHold() {
        let held = isIdleHeld
        if held, idleWatch.heldRemaining == nil {
            let unplayed = max(idleWatch.bufferedUntil, idleWatch.aheadUntil)
            idleWatch.heldRemaining = max(.zero, idleNow().duration(to: unplayed))
            idleWatch.cancel?()
            idleWatch.cancel = nil
        } else if !held, let remaining = idleWatch.heldRemaining {
            idleWatch.heldRemaining = nil
            idleWatch.bufferedUntil = idleNow().advanced(by: remaining)
            idleWatch.aheadUntil = idleNow()
            armIdleWatch()
        }
    }
    func armIdleWatch() {
        idleWatch.cancel?()
        idleWatch.cancel = nil
        // A head whose final segment is scheduled has ended its stream: only the player's completion moves it on,
        // however long the player stalls, so a finished reply is never relabelled or unmasked (#473 review).
        guard let key = queue.first, key == idleWatch.key, idleWatch.heldRemaining == nil,
              !completed.contains(key) else { return }
        let delay = max(.zero, idleNow().duration(to: idleDeadline()))
        idleWatch.cancel = idleScheduler(delay) { [weak self] in self?.idleDeadlinePassed(for: key) }
    }
    func idleDeadlinePassed(for key: ReplyStreamKey) {
        guard queue.first == key, idleWatch.key == key, !completed.contains(key) else { return }
        guard idleNow() >= idleDeadline() else { return armIdleWatch() }
        guard !isIdleHeld else { return syncIdleHold() }
        abandonHead(key)
    }
    /// Ends the stuck head as if it had finished. The player is not cancelled: anything still buffered plays out,
    /// and the next reply follows it. Later frames of the abandoned stream are ignored.
    private func abandonHead(_ key: ReplyStreamKey) {
        recordAudioLoss(for: key)
        onStreamAbandoned?()
        rollbackPlaybackStart(for: key)
        streams[key] = nil
        queue.removeFirst()
        completed.insert(key)
        drain()
        trimPresentations()
        if activeKey == nil {
            status = queue.isEmpty ? (isMuted ? "Muted" : "Played") : "Waiting for audio"
        }
    }
}

/// #825: ordered membership with constant-time lookup, removal and oldest-first eviction.
/// Links avoid array shifting and tombstone sweeps on the main actor.
struct ReplyClaimWindow: Sequence {
    struct Node {
        var previous: ReplyStreamKey?
        var next: ReplyStreamKey?
    }
    struct Iterator: IteratorProtocol {
        var key: ReplyStreamKey?
        let nodes: [ReplyStreamKey: Node]
        mutating func next() -> ReplyStreamKey? {
            defer { key = key.flatMap { nodes[$0]?.next } }
            return key
        }
    }
    private var nodes: [ReplyStreamKey: Node] = [:]
    private var head: ReplyStreamKey?
    private var tail: ReplyStreamKey?
    #if DEBUG
    private(set) var membershipLookups = 0 // deterministic complexity evidence, never a timing assertion
    #endif
    var count: Int { nodes.count }
    var isEmpty: Bool { nodes.isEmpty }
    func makeIterator() -> Iterator { Iterator(key: head, nodes: nodes) }
    mutating func contains(_ key: ReplyStreamKey) -> Bool { lookup(key) != nil }
    private mutating func lookup(_ key: ReplyStreamKey) -> Node? {
        #if DEBUG
        membershipLookups += 1
        #endif
        return nodes[key]
    }
    mutating func append(_ key: ReplyStreamKey) {
        guard !contains(key) else { return }
        nodes[key] = Node(previous: tail)
        if let tail { nodes[tail]?.next = key } else { head = key }
        tail = key
    }
    mutating func remove(_ key: ReplyStreamKey) {
        guard let node = lookup(key) else { return }
        if let previous = node.previous { nodes[previous]?.next = node.next } else { head = node.next }
        if let next = node.next { nodes[next]?.previous = node.previous } else { tail = node.previous }
        nodes[key] = nil
    }
    @discardableResult mutating func removeFirst() -> ReplyStreamKey? {
        guard let key = head else { return nil }
        remove(key)
        return key
    }
    mutating func subtract(_ keys: Set<ReplyStreamKey>) { for key in keys { remove(key) } }
    mutating func formUnion(_ keys: Set<ReplyStreamKey>) { for key in keys { append(key) } }
}

extension ReplyStreamKey {
    var presentationID: String { "\(endpointID)|\(replyID.uuidString.lowercased())" }
}
