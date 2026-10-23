import Foundation
import HailCore
import HailProtocol
import Testing

/// #825: while the player holds a stalled reply to catch up, the status says so honestly, and it goes back to playing
/// when the reply plays on.
@MainActor
@Suite struct ReplyPlaybackCatchUpTests {
    @Test func aHeldReplyShowsCatchingUpThenPlaying() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        controller.ingest(audio(reply, sequence: 0))
        #expect(controller.status == "Playing")

        player.onCatchingUpChanged?(true)
        #expect(controller.status == "Catching up…")
        #expect(controller.statusForControls == "Catching up…")

        player.onCatchingUpChanged?(false)
        #expect(controller.status == "Playing")
    }

    @Test func catchingUpWithNoReplyPlayingChangesNothing() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        player.onCatchingUpChanged?(true)
        #expect(controller.status == "No replies yet")
    }

    @Test func aMutedReplyGoesBackToMutedNotPlaying() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        controller.ingest(audio(reply, sequence: 0))
        controller.toggleMute()
        player.onCatchingUpChanged?(true)
        player.onCatchingUpChanged?(false)
        #expect(controller.status == "Muted")
    }

    private func audio(_ reply: ReplyDescriptor, sequence: Int) -> HostReplyEvent {
        let payload = AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
            streamID: reply.audioStreamID, isFinal: false, bytes: Data([1, 0]), reply: reply
        )
        let frame = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .audio(payload))
        return HostReplyEvent(endpointID: "main", frame: frame)
    }
}

@MainActor
private final class CatchUpPlayer: ReplyAudioPlaying, ReplyCatchUpReporting {
    var onCatchingUpChanged: (@MainActor (Bool) -> Void)?
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
