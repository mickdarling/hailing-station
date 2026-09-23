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
    public var host: String
    public var target: String
    public var transcript: String?
}

struct ReplyStreamKey: Hashable {
    var endpointID: HostEndpoint.Identifier
    var replyID: UUID
}

private struct ReplyStreamState {
    var segments: [Int: AudioPayload] = [:]
    var nextSequence = 0
}

/// Terminal-owned FIFO arbitration for identified reply streams. Frames may arrive out of order;
/// only a contiguous sequence is scheduled, and the next reply cannot enter the player until the
/// current reply's explicit final segment has actually played.
@MainActor
@Observable
public final class ReplyPlaybackController {
    public static let presentationLimit = 100
    public static let seenFrameLimit = 1_024

    public internal(set) var replies: [ReplyPresentation] = []
    public internal(set) var isPaused = false
    public internal(set) var isMuted = false
    public internal(set) var isCaptureSuppressed = false
    public internal(set) var status = "No replies yet"

    let player: any ReplyAudioPlaying
    private var streams: [ReplyStreamKey: ReplyStreamState] = [:]
    private var queue: [ReplyStreamKey] = []
    private var completed: Set<ReplyStreamKey> = []
    var lastAudio: [AudioPayload] = []
    var lastKey: ReplyStreamKey?
    var playbackOrder: [ReplyStreamKey] = []
    var activeKey: ReplyStreamKey?
    var playbackGeneration: UInt = 0
    var seenFrames: [UUID] = []
    var seenFrameSet: Set<UUID> = []
    var presentationStatuses: [String: String] = [:]

    var presentationKeysToRetain: Set<ReplyStreamKey> {
        var keys = Set(queue)
        keys.formUnion(playbackOrder)
        if let activeKey { keys.insert(activeKey) }
        if let lastKey { keys.insert(lastKey) }
        return keys
    }

    var hasQueuedPlayback: Bool { !queue.isEmpty }

    public init(player: any ReplyAudioPlaying) {
        self.player = player
    }

    public var latest: ReplyPresentation? { replies.last }
    public var presentationForControls: ReplyPresentation? {
        presentation(for: activeKey ?? queue.first) ?? latest
    }

    public func ingest(_ event: HostReplyEvent) {
        guard remember(event.frame.id), let descriptor = descriptor(in: event.frame) else { return }
        guard case .audio(let audio) = event.frame.payload else {
            let presentationID = upsertPresentation(event, descriptor: descriptor)
            let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
            if presentationStatuses[presentationID] == nil,
               streams[key] == nil, !completed.contains(key) {
                presentationStatuses[presentationID] = "Received"
            }
            return
        }
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        guard !completed.contains(key) else { return }
        guard audio.codec == .pcm16, audio.channels == 1 else {
            let presentationID = upsertPresentation(event, descriptor: descriptor)
            presentationStatuses[presentationID] = "Audio format is not yet playable"
            return
        }
        var stream = streams[key] ?? ReplyStreamState()
        if let existing = stream.segments[audio.sequence], existing != audio {
            setPresentationStatus("Conflicting audio segment refused", for: key)
            return
        }
        stream.segments[audio.sequence] = audio
        if streams[key] == nil { queue.append(key) }
        streams[key] = stream
        let presentationID = upsertPresentation(event, descriptor: descriptor)
        presentationStatuses[presentationID] = nil
        drain()
        if let pending = streams[key], !playbackOrder.contains(key) {
            presentationStatuses[presentationID] = pending.segments[pending.nextSequence] == nil
                ? "Waiting for audio" : "Queued"
        }
    }

    func playbackFinished(_ key: ReplyStreamKey, generation: UInt) {
        guard generation == playbackGeneration,
              let index = playbackOrder.firstIndex(of: key) else { return }
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

    private func failPlayback(for key: ReplyStreamKey) {
        player.cancel()
        playbackGeneration &+= 1
        rollbackPlaybackStart(for: key)
        streams[key] = nil
        queue.removeAll { $0 == key }
        completed.insert(key)
        isPaused = false
    }

    func drain() {
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
            let onPlayed: (@MainActor @Sendable () -> Void)?
            if segment.isFinal {
                onPlayed = { [weak self] in
                    self?.playbackFinished(key, generation: generation)
                }
            } else {
                onPlayed = nil
            }
            do {
                try player.schedule(segment, onPlayed: onPlayed)
            } catch {
                failPlayback(for: key)
                setPresentationStatus("Playback failed", for: key)
                drain()
                return
            }
            stream.nextSequence += 1
            streams[key] = stream
            setPresentationStatus(nil, for: key)
            status = isMuted ? "Muted" : "Playing"
            guard segment.isFinal else { continue }
            lastAudio = (0..<stream.nextSequence).compactMap { stream.segments[$0] }
            lastKey = key
            completed.insert(key)
            return
        }
    }
}
