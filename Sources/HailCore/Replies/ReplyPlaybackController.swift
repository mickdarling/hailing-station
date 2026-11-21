import Foundation
public import HailProtocol
public import Observation
// Receipt bookkeeping stays beside ingest and scheduling so the two counts share one boundary (#1227).
// swiftlint:disable file_length
@MainActor
public protocol ReplyAudioPlaying: AnyObject {
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws
    func cancel()
    func pause()
    func resume() throws
    func setMuted(_ muted: Bool)
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws
}
public struct ReplyPresentation: Identifiable, Equatable, Sendable {
    #if DEBUG
    private var identity: String
    public var id: String {
        get { ReplyTraversal.onVisit?(); return identity }
        set { identity = newValue }
    }
    init(id: String, endpointID: HostEndpoint.Identifier, host: String, target: String, transcript: String? = nil) {
        identity = id; self.endpointID = endpointID
        self.host = host; self.target = target; self.transcript = transcript
    }
    #else
    public var id: String
    #endif
    public var endpointID: HostEndpoint.Identifier
    public var host: String
    public var target: String
    public var transcript: String?
    public var isSessionUpdate = false
}
/// Terminal-owned FIFO arbitration for identified reply streams. Frames may arrive out of order;
/// only a contiguous sequence is scheduled, and the next reply cannot enter the player until the
/// current reply's explicit final segment has actually played.
@MainActor
@Observable
public final class ReplyPlaybackController {
    @ObservationIgnored private(set) var lastPlaybackError: NSError? // behind the last "Playback failed" (#282)
    public static let presentationLimit = 100
    public static let seenFrameLimit = 1_024
    public internal(set) var replies: [ReplyPresentation] = []
    public internal(set) var isPaused = false
    public internal(set) var isMuted = false {
        didSet { pendingMuteAfter = nil; cancelMutedFirstAudio() }
    }
    public internal(set) var isCaptureSuppressed = false
    public internal(set) var status = "No replies yet"
    let player: any ReplyAudioPlaying
    var streams: [ReplyStreamKey: ReplyStreamState] = [:] { didSet { pruneStreamReceipts() } }
    @ObservationIgnored var receiptStreamCount = 0
    @ObservationIgnored var streamReceipts: [ReplyStreamKey: (sequence: Int, at: ContinuousClock.Instant)] = [:]
    var queue: [ReplyStreamKey] = []
    var completed: Set<ReplyStreamKey> = []
    var lastAudio: [AudioPayload] = []
    var lastKey: ReplyStreamKey?
    var playbackOrder: [ReplyStreamKey] = []
    /// A reply starting or ending claims or frees the headset's pause (`+Headset`).
    var activeKey: ReplyStreamKey? {
        didSet {
            // A Replay of a completed reply owns the player without a live stream. Reserve its
            // FIFO turn so drain and the idle watch both wait for the player's completion.
            if let activeKey, streams[activeKey] == nil, queue.first != activeKey {
                queue.insert(activeKey, at: 0)
                watchHeadIfChanged()
            }
            if oldValue != activeKey {
                if activeKey != stopMuteWindow?.key { stopMuteWindow = nil }
                clearSegmentBoundary()
            }
            if (oldValue == nil) != (activeKey == nil) { replyActivityChanged() }
        }
    }
    var playbackGeneration: UInt = 0 {
        didSet {
            stopMuteWindow = nil
            clearSegmentBoundary()
        }
    }
    public var segmentSettings = ReplySegmentSettings.saved()
    public internal(set) var segmentPause: ReplySegmentPause?
    public internal(set) var lastSegmentYield: ReplySegmentPause?
    @ObservationIgnored var segmentBoundary: ReplyStreamKey?
    @ObservationIgnored var segmentBoundarySequence: Int?
    @ObservationIgnored var playedSegmentEnds = 0
    @ObservationIgnored var cancelSegmentPause: (@MainActor () -> Void)?
    var seenFrames: [UUID] = []
    var seenFrameSet: Set<UUID> = []
    var presentationStatuses: [String: String] = [:]
    /// The head stream's idle watch, its injectable clock and scheduler, and its diagnostics hook (#469, `+Idle`).
    @ObservationIgnored let proactive = ProactiveReplyPlaybackState()
    @ObservationIgnored var pausedAudioBudget = PausedReplyAudioBudget()
    @ObservationIgnored var idleWatch = ReplyIdleWatch()
    @ObservationIgnored var firstAudio: [ReplyStreamKey: ReplyIdleWatch] = [:] // arrival deadlines (#825)
    @ObservationIgnored var firstAudioByEndpoint: [HostEndpoint.Identifier: Set<ReplyStreamKey>] = [:]
    @ObservationIgnored var cancelledFirstAudio = ReplyClaimWindow() // mute cancels the claim, not the reply
    @ObservationIgnored var expiredFirstAudio = ReplyClaimWindow() // bounded silence claims, still playable
    @ObservationIgnored var undeliveredLosses = ReplyClaimWindow() // awaiting observation, oldest first
    // #825: inject a small overflow bound in tests; production retains 1,024 claims.
    @ObservationIgnored var firstAudioClaimLimit = ReplyPlaybackController.seenFrameLimit
    /// Captured when a suppression ledger starts watching; each player can supply its own sleep (#965, #977).
    @ObservationIgnored var captureLivenessSleep: CaptureLivenessSleep = { try await Task.sleep(for: $0) }
    @ObservationIgnored var idleNow: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored var idleScheduler: @MainActor (Duration, @escaping @MainActor () -> Void)
        -> @MainActor () -> Void = ReplyPlaybackController.sleepThenFire
    @ObservationIgnored public var onStreamAbandoned: (@MainActor () -> Void)?
    @ObservationIgnored var pendingMuteAfter: ReplyStreamKey? { // a waiting voice mute (#404, `+Stop`)
        didSet { cancelMutedFirstAudio() }
    }
    @ObservationIgnored var stopMuteWindow: (key: ReplyStreamKey, deadline: ContinuousClock.Instant)?
    public init(player: any ReplyAudioPlaying) {
        self.player = player
        observeAudioInterruptions(on: .default)
        observeCatchUp()
        observeSegmentDiscards()
    }
    /// An unmuted reply still owns the output path. This is intentionally conservative across
    /// segment gaps: accessibility speech must not compete with a reply that may resume.
    public var isReplyAudioOutputBusy: Bool {
        activeKey != nil && !isPaused && !isMuted && !isCaptureSuppressed
    }
    public var presentationForControls: ReplyPresentation? {
        presentation(for: activeKey ?? queue.first) ?? latest
    }
    public func ingest(_ event: HostReplyEvent) {
        if case .audio = event.frame.payload { noteEndpointAudio(event.endpointID) }
        if case .control(let control) = event.frame.payload { return handlePlaybackControl(control, event) }
        guard remember(event.frame.id), let descriptor = descriptor(in: event.frame),
              acceptProactiveFrame(event, descriptor: descriptor) else { return }
        guard case .audio(let audio) = event.frame.payload else {
            receiveText(event, descriptor: descriptor)
            return
        }
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        guard !completed.contains(key) else { return }
        cancelFirstAudio(for: [key])
        guard retainAudioWhilePaused(audio, event: event, descriptor: descriptor, key: key) else { return }
        var stream = streams[key] ?? ReplyStreamState()
        if let existing = stream.segments[audio.sequence], existing != audio {
            setPresentationStatus("Conflicting audio segment refused", for: key)
            return
        }
        expiredFirstAudio.remove(key)
        undeliveredLosses.remove(key) // Accepted late audio clears the loss without another notice.
        stream.segments[audio.sequence] = audio
        enqueueStreamIfNeeded(key, descriptor: descriptor)
        streams[key] = stream
        streamReceipts[key] = (audio.sequence, idleNow())
        let presentationID = upsertPresentation(event, descriptor: descriptor)
        presentationStatuses[presentationID] = nil
        drain(noting: key)
        if let pending = streams[key], !playbackOrder.contains(key) {
            presentationStatuses[presentationID] = pending.segments[pending.nextSequence] == nil
                ? "Waiting for audio" : "Queued"
        }
    }
}
extension ReplyPlaybackController {
    func playbackFinished(_ key: ReplyStreamKey, generation: UInt) {
        guard generation == playbackGeneration,
              let index = playbackOrder.firstIndex(of: key) else { return }
        if proactive.identities[key] != nil { proactive.cancelWatch?(); proactive.cancelWatch = nil }
        if streams[key]?.audioNotKeptWhilePaused != true { setPresentationStatus("Played", for: key) }
        playbackOrder.remove(at: index)
        if activeKey == key { activeKey = playbackOrder.first }
        if queue.first == key {
            streams[key] = nil
            queue.removeFirst()
        }
        drain()
        trimPresentations()
        if activeKey == nil {
            status = queue.isEmpty ? (isMuted ? "Muted" : "Played") : "Waiting for audio"
        }
    }
    func drain(afterStop: Bool = false) {
        let ready = prepareDrain()
        if afterStop, let key = queue.first, !key.isAnnouncement, !isMuted {
            // Promotion starts the window even when the head is waiting for frame zero.
            stopMuteWindow = (key, idleNow() + .milliseconds(100))
        }
        guard ready else { return }
        guard !isCaptureSuppressed, !isPaused else {
            status = isCaptureSuppressed ? "Paused while listening" : "Paused"
            return
        }
        while let key = queue.first, var stream = streams[key],
              let segment = nextRetainedSegment(in: stream) {
            let beginsPlayback = stream.nextSequence == 0 && !playbackOrder.contains(key)
            guard beginPlaybackIfNeeded(key, begins: beginsPlayback) else { return }
            do {
                try schedule(segment, for: key)
            } catch {
                lastPlaybackError = error as NSError
                failPlayback(for: key)
                setPresentationStatus(Self.playbackFailed, for: key)
                drain(afterStop: afterStop)
                return
            }
            stream.nextSequence = segment.sequence + 1
            streams[key] = stream
            noteScheduled(segment)
            if !stream.audioNotKeptWhilePaused { setPresentationStatus(nil, for: key) }
            status = playingStatus
            if segment.isSegmentEnd { syncIdleHold(); return }
            guard segment.isFinal else { continue }
            if !key.isAnnouncement, let audio = retainedReplayAudio(in: stream) {
                // Replay replays the last complete reply, never an announcement or text-only reply.
                lastAudio = audio
                lastKey = key
            }
            completed.insert(key)
            return
        }
    }

    private func schedule(_ segment: AudioPayload, for key: ReplyStreamKey) throws {
        let generation = playbackGeneration
        let onPlayed = completion(for: segment, key: key, generation: generation)
        guard stopMuteWindow?.key == key, segment.sequence == 0, !segment.isFinal else {
            return try player.schedule(segment, onPlayed: onPlayed)
        }
        try player.schedule(segment) { [weak self] in
            if let self, playbackGeneration == generation, stopMuteWindow?.key == key { stopMuteWindow = nil }
            onPlayed?()
        }
    }
}
extension ReplyPlaybackController {
    /// Content follows receipt order even while another reply retains the FIFO audio turn.
    public var presentationForDisplay: ReplyPresentation? { latest }
    public var displayDiffersFromControls: Bool {
        presentationForDisplay?.id != presentationForControls?.id
    }
    func pruneStreamReceipts() {
        // Cache only the count: retaining oldValue here would force dictionary copies on every frame.
        defer { receiptStreamCount = streams.count }
        if streams.count < receiptStreamCount { streamReceipts = streamReceipts.filter { streams[$0.key] != nil } }
    }
    /// Called synchronously by the abandonment hook, before the head is removed. The same hook also reports
    /// first-audio timeouts: those must never borrow an unrelated head's counters (#1227).
    func abandonedStreamDiagnostics() -> [DiagnosticField: DiagnosticValue] {
        guard let key = queue.first, undeliveredLosses.contains(key),
              let stream = streams[key], let receipt = streamReceipts[key] else { return [:] }
        var expected = 0
        for sequence in stream.segments.keys.sorted() {
            guard sequence == expected else { break }
            expected += 1
        }
        func integer(_ value: Int) -> DiagnosticValue { .integer(Int64(Int32(clamping: value))) }
        let elapsed = max(.zero, receipt.at.duration(to: idleNow())) / .milliseconds(1)
        return [
            .lastSequence: integer(receipt.sequence), .expectedSequence: integer(expected),
            .gap: .boolean(stream.segments.keys.contains { $0 > expected }),
            .receivedFrames: integer(stream.segments.count), .scheduledFrames: integer(stream.nextSequence),
            .terminal: .boolean(stream.segments.values.contains { $0.isFinal }),
            .lastFrameMs: .integer(Int64(min(Double(Int32.max), elapsed)))
        ]
    }
    func descriptor(in frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }
}
