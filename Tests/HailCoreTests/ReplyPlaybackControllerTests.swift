import Foundation
import HailCore
import HailProtocol
import Testing

@MainActor
@Suite struct ReplyPlaybackControllerTests {
    @Test func gapsAndOverlappingRepliesStayInTheirOwnFIFOStreams() throws {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = descriptor(id: UUID(), stream: UUID())
        let second = descriptor(id: UUID(), stream: UUID())

        controller.ingest(event(first, sequence: 0, final: false, byte: 10))
        #expect(controller.latest?.endpointID == "main")
        controller.ingest(event(second, sequence: 0, final: true, byte: 20))
        #expect(controller.presentationForControls?.id.contains(first.id.uuidString.lowercased()) == true)
        controller.ingest(event(first, sequence: 2, final: true, byte: 12))
        #expect(player.scheduled.map(\.sequence) == [0])
        controller.ingest(event(first, sequence: 1, final: false, byte: 11))

        #expect(player.scheduled.map(\.bytes.first) == [10, 11, 12])
        #expect(controller.presentationForControls?.id.contains(first.id.uuidString.lowercased()) == true)
        player.completeNextReply()
        #expect(player.scheduled.map(\.bytes.first) == [10, 11, 12, 20])
        #expect(controller.presentationForControls?.id.contains(second.id.uuidString.lowercased()) == true)
    }

    @Test func replayUsesTheAudibleReplyAndThenResumesTheQueue() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = descriptor(id: UUID(), stream: UUID())
        let second = descriptor(id: UUID(), stream: UUID())

        controller.ingest(event(first, sequence: 0, final: true, byte: 10))
        controller.ingest(event(second, sequence: 0, final: true, byte: 20))
        controller.replayLatest()

        #expect(player.replaced.map(\.bytes.first) == [10])
        player.completeNextReply() // Completion from the queue replaced by replay is stale.
        #expect(player.scheduled.map(\.bytes.first) == [10])
        player.completeNextReply()
        #expect(player.scheduled.map(\.bytes.first) == [10, 20])
        #expect(controller.presentationForControls?.id.contains(second.id.uuidString.lowercased()) == true)
    }

    @Test func replayDoesNotReplaceAnIncompleteAudibleReply() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = descriptor(id: UUID(), stream: UUID())
        let second = descriptor(id: UUID(), stream: UUID())

        controller.ingest(event(first, sequence: 0, final: true, byte: 10))
        player.completeNextReply()
        controller.ingest(event(second, sequence: 0, final: false, byte: 20))
        controller.replayLatest()

        #expect(player.replaced.isEmpty)
        #expect(controller.status == "Replay available when this reply finishes")
        #expect(controller.presentationForControls?.id.contains(second.id.uuidString.lowercased()) == true)
    }

    @Test func boundedHistoryRetainsTheActiveReplyPresentation() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let active = descriptor(id: UUID(), stream: UUID())
        controller.ingest(event(active, sequence: 0, final: false, byte: 10))

        for index in 0...ReplyPlaybackController.presentationLimit {
            let reply = descriptor(id: UUID(), stream: UUID())
            let text = Frame(
                timestamp: Int64(index), target: reply.targetID, source: reply.hostID,
                payload: .text(TextPayload(text: "Reply \(index)", reply: reply))
            )
            controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        }

        #expect(controller.replies.count == ReplyPlaybackController.presentationLimit)
        #expect(controller.presentationForControls?.id.contains(active.id.uuidString.lowercased()) == true)
    }

    @Test func textOnlyReplyBecomesVisibleUntilAudioActuallyReplays() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let spoken = descriptor(id: UUID(), stream: UUID())
        controller.ingest(event(spoken, sequence: 0, final: true, byte: 10))
        player.completeNextReply()

        let textOnly = descriptor(id: UUID(), stream: UUID())
        let text = Frame(
            timestamp: 1, target: textOnly.targetID, source: textOnly.hostID,
            payload: .text(TextPayload(text: "Text only", reply: textOnly))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        #expect(controller.presentationForControls?.id.contains(textOnly.id.uuidString.lowercased()) == true)
        #expect(controller.statusForControls == "Received")

        controller.replayLatest()
        #expect(controller.presentationForControls?.id.contains(spoken.id.uuidString.lowercased()) == true)
    }

    @Test func newlyQueuedReplyIsProtectedBeforeHistoryTrims() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let first = descriptor(id: UUID(), stream: UUID())
        controller.ingest(event(first, sequence: 0, final: false, byte: 1))

        var newest = first
        var queued: [ReplyDescriptor] = []
        for index in 1...ReplyPlaybackController.presentationLimit {
            newest = descriptor(id: UUID(), stream: UUID())
            queued.append(newest)
            controller.ingest(event(newest, sequence: 1, final: true, byte: UInt8(index)))
        }

        #expect(controller.replies.count == ReplyPlaybackController.presentationLimit + 1)
        #expect(controller.replies.contains { $0.id.contains(newest.id.uuidString.lowercased()) })

        let textOnly = descriptor(id: UUID(), stream: UUID())
        let text = Frame(
            timestamp: 101, target: textOnly.targetID, source: textOnly.hostID,
            payload: .text(TextPayload(text: "Newest text", reply: textOnly))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        #expect(controller.replies.count == ReplyPlaybackController.presentationLimit + 2)
        #expect(controller.latest?.id.contains(textOnly.id.uuidString.lowercased()) == true)

        controller.ingest(event(first, sequence: 1, final: true, byte: 2))
        player.completeNextReply()
        controller.ingest(event(queued[0], sequence: 0, final: false, byte: 3))
        player.completeNextReply()
        #expect(controller.latest?.id.contains(textOnly.id.uuidString.lowercased()) == true)
    }

    @Test func transcriptControlsAndReplayAreImmediate() {
        let player = FakeReplyPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = descriptor(id: UUID(), stream: UUID())
        let text = Frame(
            timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "All checks passed", reply: reply))
        )
        controller.ingest(HostReplyEvent(endpointID: "main", frame: text))
        controller.ingest(event(reply, sequence: 0, final: true, byte: 1))
        controller.togglePause()
        controller.toggleMute()
        controller.replayLatest()

        #expect(controller.latest?.transcript == "All checks passed")
        #expect(player.pauseCount == 1 && player.muted)
        #expect(player.replaced.count == 1)
    }

    @Test func standaloneGapIsWaitingForAudio() {
        let controller = ReplyPlaybackController(player: FakeReplyPlayer())
        let reply = descriptor(id: UUID(), stream: UUID())
        controller.ingest(event(reply, sequence: 1, final: true, byte: 1))
        #expect(controller.statusForControls == "Waiting for audio")
    }
}

@MainActor
private final class FakeReplyPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var replaced: [AudioPayload] = []
    var pauseCount = 0
    var muted = false
    var replyCompletions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { replyCompletions.append(onPlayed) }
    }
    func cancel() {}
    func pause() { pauseCount += 1 }
    func resume() {}
    func setMuted(_ muted: Bool) { self.muted = muted }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {
        replaced = payloads
        if let onPlayed { replyCompletions.append(onPlayed) }
    }

    func completeNextReply() { replyCompletions.removeFirst()() }
}

private func descriptor(id: UUID, stream: UUID) -> ReplyDescriptor {
    ReplyDescriptor(id: id, hostID: "main-mac", targetID: "tmux:codex", audioStreamID: stream)
}

private func event(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8) -> HostReplyEvent {
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: Data([byte, 0]), reply: reply
    )
    let frame = Frame(
        timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID, payload: .audio(audio)
    )
    return HostReplyEvent(endpointID: "main", frame: frame)
}
