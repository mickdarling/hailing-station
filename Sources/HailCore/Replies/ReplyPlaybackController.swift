import Foundation
public import HailProtocol
public import Observation

@MainActor
public protocol ReplyAudioPlaying: AnyObject {
    func schedule(_ payload: AudioPayload) throws
    func pause()
    func resume() throws
    func setMuted(_ muted: Bool)
    func replaceQueue(with payloads: [AudioPayload]) throws
}

public struct ReplyPresentation: Identifiable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var target: String
    public var transcript: String?
}

private struct ReplyStreamKey: Hashable {
    var endpointID: HostEndpoint.Identifier
    var replyID: UUID
}

private struct ReplyStreamState {
    var segments: [Int: AudioPayload] = [:]
    var nextSequence = 0
}

/// Terminal-owned FIFO arbitration for identified reply streams. Frames may arrive out of order;
/// only a contiguous sequence is scheduled, and the next reply cannot enter the player until the
/// current reply's explicit final segment has been scheduled.
@MainActor
@Observable
public final class ReplyPlaybackController {
    public static let presentationLimit = 100
    public static let seenFrameLimit = 1_024

    public private(set) var replies: [ReplyPresentation] = []
    public private(set) var isPaused = false
    public private(set) var isMuted = false
    public private(set) var status = "No replies yet"

    private let player: any ReplyAudioPlaying
    private var streams: [ReplyStreamKey: ReplyStreamState] = [:]
    private var queue: [ReplyStreamKey] = []
    private var completed: Set<ReplyStreamKey> = []
    private var lastAudio: [AudioPayload] = []
    private var seenFrames: [UUID] = []
    private var seenFrameSet: Set<UUID> = []

    public init(player: any ReplyAudioPlaying) {
        self.player = player
    }

    public var latest: ReplyPresentation? { replies.last }

    public func ingest(_ event: HostReplyEvent) {
        guard remember(event.frame.id), let descriptor = descriptor(in: event.frame) else { return }
        upsertPresentation(event, descriptor: descriptor)
        guard case .audio(let audio) = event.frame.payload else { return }
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: descriptor.id)
        guard !completed.contains(key), audio.codec == .pcm16, audio.channels == 1 else {
            if audio.codec != .pcm16 || audio.channels != 1 { status = "Audio format is not yet playable" }
            return
        }
        var stream = streams[key] ?? ReplyStreamState()
        if let existing = stream.segments[audio.sequence], existing != audio {
            status = "Conflicting audio segment refused"
            return
        }
        stream.segments[audio.sequence] = audio
        if streams[key] == nil { queue.append(key) }
        streams[key] = stream
        drain()
    }

    public func togglePause() {
        if isPaused {
            do {
                try player.resume()
                isPaused = false
                status = "Playing"
            } catch {
                status = "Playback could not resume"
            }
        } else {
            player.pause()
            isPaused = true
            status = "Paused"
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        player.setMuted(isMuted)
        status = isMuted ? "Muted" : "Playing"
    }

    public func replayLatest() {
        guard !lastAudio.isEmpty else { return }
        do {
            try player.replaceQueue(with: lastAudio)
            for key in queue { streams[key]?.nextSequence = 0 }
            isPaused = false
            status = "Replaying"
            drain()
        } catch {
            status = "Replay failed"
        }
    }

    private func drain() {
        while let key = queue.first, var stream = streams[key],
              let segment = stream.segments[stream.nextSequence] {
            do {
                try player.schedule(segment)
            } catch {
                status = "Playback failed"
                return
            }
            stream.nextSequence += 1
            streams[key] = stream
            status = isMuted ? "Muted" : "Playing"
            guard segment.isFinal else { continue }
            lastAudio = stream.segments.keys.sorted().compactMap { stream.segments[$0] }
            completed.insert(key)
            streams[key] = nil
            queue.removeFirst()
        }
    }

    private func upsertPresentation(_ event: HostReplyEvent, descriptor: ReplyDescriptor) {
        let id = "\(event.endpointID)|\(descriptor.id.uuidString.lowercased())"
        let transcript: String?
        if case .text(let text) = event.frame.payload { transcript = text.text } else { transcript = nil }
        if let index = replies.firstIndex(where: { $0.id == id }) {
            if let transcript { replies[index].transcript = transcript }
        } else {
            replies.append(ReplyPresentation(
                id: id, host: descriptor.hostID, target: descriptor.targetID, transcript: transcript
            ))
            if replies.count > Self.presentationLimit { replies.removeFirst(replies.count - Self.presentationLimit) }
        }
    }

    private func remember(_ id: UUID) -> Bool {
        guard seenFrameSet.insert(id).inserted else { return false }
        seenFrames.append(id)
        if seenFrames.count > Self.seenFrameLimit {
            for expired in seenFrames.prefix(seenFrames.count - Self.seenFrameLimit) { seenFrameSet.remove(expired) }
            seenFrames.removeFirst(seenFrames.count - Self.seenFrameLimit)
        }
        return true
    }

    private func descriptor(in frame: Frame) -> ReplyDescriptor? {
        switch frame.payload {
        case .text(let text): text.reply
        case .audio(let audio): audio.reply
        default: nil
        }
    }
}
