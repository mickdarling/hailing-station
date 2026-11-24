import Foundation
@testable import HailCore
import HailProtocol
import Testing

@MainActor
final class PausedReplyRig {
    let player = PausedReplyPlayer()
    let controller: ReplyPlaybackController

    init() {
        controller = ReplyPlaybackController(player: player)
        // All completion is driven by player notifications, never a wall-clock idle deadline.
        controller.idleScheduler = { _, _ in {} }
    }

    func ingest(_ reply: ReplyDescriptor, sequence: Int = 0, final: Bool = true, byte: UInt8) {
        controller.ingest(idleAudio(reply, sequence: sequence, final: final, byte: byte))
    }

    func status(_ reply: ReplyDescriptor) -> String? {
        controller.replies.first { $0.id.hasSuffix(reply.id.uuidString.lowercased()) }.map(controller.status(for:))
    }
}

/// Models the retained playback cursor: pause keeps pending buffers; cancel flushes them.
@MainActor
final class PausedReplyPlayer: ReplyAudioPlaying {
    struct Buffer {
        let payload: AudioPayload
        let completion: (@MainActor @Sendable () -> Void)?
    }
    var scheduled: [AudioPayload] = []
    var played: [AudioPayload] = []
    var pending: [Buffer] = []
    var mutedWhenScheduled: [Bool] = []
    var cancelCount = 0
    var resumeCount = 0
    var paused = false
    var muted = false

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        mutedWhenScheduled.append(muted)
        pending.append(Buffer(payload: payload, completion: onPlayed))
    }
    func cancel() { cancelCount += 1; pending.removeAll(); paused = false }
    func pause() { paused = true }
    func resume() { resumeCount += 1; paused = false }
    func setMuted(_ muted: Bool) { self.muted = muted }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        pending.removeAll()
        for (index, payload) in payloads.enumerated() {
            schedule(payload, onPlayed: index == payloads.count - 1 ? onPlayed : nil)
        }
    }

    func playNext() async throws {
        try #require(!paused, "cannot play while paused")
        let buffer = try #require(pending.first, "expected a playable frame")
        pending.removeFirst()
        let notification = AsyncStream<AudioPayload>.makeStream()
        // Deliver the engine completion asynchronously; the test waits for its notification.
        Task { @MainActor in
            self.played.append(buffer.payload)
            buffer.completion?()
            notification.continuation.yield(buffer.payload)
            notification.continuation.finish()
        }
        var iterator = notification.stream.makeAsyncIterator()
        #expect(await iterator.next() == buffer.payload)
    }
}
