import Foundation
public import HailProtocol
public import Observation

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
    public var id: String
    public var endpointID: HostEndpoint.Identifier
    public var host: String
    public var target: String
    public var transcript: String?
}

struct ReplyStreamKey: Hashable {
    var endpointID: HostEndpoint.Identifier
    var replyID: UUID
}

struct ReplyStreamState {
    var segments: [Int: AudioPayload] = [:]
    var nextSequence = 0
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
    var streams: [ReplyStreamKey: ReplyStreamState] = [:]
    var queue: [ReplyStreamKey] = []
    var completed: Set<ReplyStreamKey> = []
    var lastAudio: [AudioPayload] = []
    var lastKey: ReplyStreamKey?
    var playbackOrder: [ReplyStreamKey] = []
    /// A reply starting or ending claims or frees the headset's pause (`+Headset`).
    var activeKey: ReplyStreamKey? { didSet { if (oldValue == nil) != (activeKey == nil) { replyActivityChanged() } } }
    var playbackGeneration: UInt = 0
    var seenFrames: [UUID] = []
    var seenFrameSet: Set<UUID> = []
    var presentationStatuses: [String: String] = [:]
    /// The head stream's idle watch, its injectable clock and scheduler, and its diagnostics hook (#469, `+Idle`).
    @ObservationIgnored var idleWatch = ReplyIdleWatch()
    @ObservationIgnored var firstAudio: [ReplyStreamKey: ReplyIdleWatch] = [:] // arrival deadlines (#825)
    @ObservationIgnored var cancelledFirstAudio: Set<ReplyStreamKey> = [] // mute cancels the claim, not the reply
    @ObservationIgnored var idleNow: @MainActor () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored var idleScheduler: @MainActor (Duration, @escaping @MainActor () -> Void)
        -> @MainActor () -> Void = ReplyPlaybackController.sleepThenFire
    @ObservationIgnored public var onStreamAbandoned: (@MainActor () -> Void)?
    @ObservationIgnored var pendingMuteAfter: ReplyStreamKey? { // a waiting voice mute (#404, `+Stop`)
        didSet { cancelMutedFirstAudio() }
    }

    var presentationKeysToRetain: Set<ReplyStreamKey> {
        var keys = Set(queue).union(firstAudio.keys).union(cancelledFirstAudio)
        keys.formUnion(playbackOrder)
        if let activeKey { keys.insert(activeKey) }
        if let lastKey { keys.insert(lastKey) }
        return keys
    }

    var hasQueuedPlayback: Bool { !queue.isEmpty }
    public init(player: any ReplyAudioPlaying) {
        self.player = player
        observeAudioInterruptions(on: .default)
        observeCatchUp()
    }

    public var latest: ReplyPresentation? { replies.last }
    /// An unmuted reply still owns the output path. This is intentionally conservative across
    /// segment gaps: accessibility speech must not compete with a reply that may resume.
    public var isReplyAudioOutputBusy: Bool {
        activeKey != nil && !isPaused && !isMuted && !isCaptureSuppressed
    }
    public var presentationForControls: ReplyPresentation? {
        presentation(for: activeKey ?? queue.first) ?? latest
    }

    public func ingest(_ event: HostReplyEvent) {
        if case .control(let control) = event.frame.payload { return handlePlaybackControl(control, event) }
        guard remember(event.frame.id), let descriptor = descriptor(in: event.frame) else { return }
        guard case .audio(let audio) = event.frame.payload else {
            receiveText(event, descriptor: descriptor)
            return
        }
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        guard !completed.contains(key) else { return }
        cancelFirstAudio(for: [key])
        guard !refuseUnplayableAudio(audio, event: event, descriptor: descriptor, key: key) else { return }
        var stream = streams[key] ?? ReplyStreamState()
        if let existing = stream.segments[audio.sequence], existing != audio {
            setPresentationStatus("Conflicting audio segment refused", for: key)
            return
        }
        stream.segments[audio.sequence] = audio
        if streams[key] == nil { supersedePausedReplies(); queue.append(key) }
        streams[key] = stream
        let presentationID = upsertPresentation(event, descriptor: descriptor)
        presentationStatuses[presentationID] = nil
        drain(noting: key)
        if let pending = streams[key], !playbackOrder.contains(key) {
            presentationStatuses[presentationID] = pending.segments[pending.nextSequence] == nil
                ? "Waiting for audio" : "Queued"
        }
    }

    private func finished(_ key: ReplyStreamKey, generation: UInt) -> @MainActor @Sendable () -> Void {
        { [weak self] in self?.playbackFinished(key, generation: generation) }
    }

    func playbackFinished(_ key: ReplyStreamKey, generation: UInt) {
        guard generation == playbackGeneration,
              let index = playbackOrder.firstIndex(of: key) else { return }
        setPresentationStatus("Played", for: key)
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

    func drain() {
        watchHeadIfChanged() // before any segment of a new head is scheduled (#469)
        dropAbandonedHold() // an abandoned reply's held tail never plays before the next (#825)
        applyPendingMuteIfDue() // before the next reply starts, so it plays silently (#404)
        guard !isCaptureSuppressed, !isPaused else {
            status = isCaptureSuppressed ? "Paused while listening" : "Paused"
            return
        }
        while let key = queue.first, var stream = streams[key],
              let segment = stream.segments[stream.nextSequence] {
            let beginsPlayback = stream.nextSequence == 0 && !playbackOrder.contains(key)
            if beginsPlayback {
                playbackOrder.append(key)
                if activeKey == nil { activeKey = key }
            }
            let generation = playbackGeneration
            let onPlayed = segment.isFinal ? finished(key, generation: generation) : nil
            do {
                try player.schedule(segment, onPlayed: onPlayed)
            } catch {
                lastPlaybackError = error as NSError
                failPlayback(for: key)
                setPresentationStatus(Self.playbackFailed, for: key)
                drain()
                return
            }
            stream.nextSequence += 1
            streams[key] = stream
            noteScheduled(segment)
            setPresentationStatus(nil, for: key)
            status = playingStatus
            guard segment.isFinal else { continue }
            if !key.isAnnouncement { lastAudio = (0..<stream.nextSequence).compactMap { stream.segments[$0] } }
            if !key.isAnnouncement { lastKey = key } // Replay replays the last reply, never an announcement (#825).
            completed.insert(key)
            return
        }
    }
}
