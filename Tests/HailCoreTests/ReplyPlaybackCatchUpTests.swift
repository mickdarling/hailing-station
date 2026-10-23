import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: while the player holds a stalled reply to catch up, the status says so honestly, through the echo guard
/// the app wraps its player in, and whatever frames arrive meanwhile; a pause keeps its own status; and a reply
/// abandoned while held never leaves its held tail to play before the next reply.
@MainActor
@Suite struct ReplyPlaybackCatchUpTests {
    private let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())

    @Test func aHeldReplyShowsCatchingUpThenPlaying() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply, sequence: 0))
        #expect(controller.status == "Playing")

        player.hold(true)
        #expect(controller.status == "Catching up…")
        #expect(controller.statusForControls == "Catching up…")

        player.hold(false)
        #expect(controller.status == "Playing")
    }

    @Test func theStatusSeesTheHoldThroughTheEchoGuard() {
        let player = CatchUpPlayer()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { .now })
        let controller = ReplyPlaybackController(player: echoGuard.guarding(player))
        controller.ingest(audio(reply, sequence: 0))
        player.hold(true)
        #expect(controller.statusForControls == "Catching up…", "the app's player is always echo-guarded")
    }

    @Test func aLateFrameWhileHeldKeepsCatchingUp() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply, sequence: 0))
        player.hold(true)
        controller.ingest(audio(reply, sequence: 1)) // Below the target: the player still holds.
        #expect(controller.statusForControls == "Catching up…")
    }

    @Test func aPauseDuringTheHoldShowsPausedAndTheHoldShowsAgainAfter() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply, sequence: 0))
        player.hold(true)
        controller.togglePause()
        #expect(controller.statusForControls == "Paused")
        player.onCatchingUpChanged?(true) // A late report never overwrites the pause.
        #expect(controller.statusForControls == "Paused")
        controller.togglePause()
        #expect(controller.statusForControls == "Catching up…")
    }

    @Test func catchingUpWithNoReplyPlayingChangesNothing() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        player.hold(true)
        #expect(controller.status == "No replies yet")
    }

    @Test func aMutedReplyGoesBackToMutedNotPlaying() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(audio(reply, sequence: 0))
        controller.toggleMute()
        player.hold(true)
        player.hold(false)
        #expect(controller.status == "Muted")
    }

    @Test func aReplyAbandonedWhileHeldDropsItsHeldTail() {
        let player = CatchUpPlayer()
        let controller = ReplyPlaybackController(player: player)
        var now = ContinuousClock.now
        var timers: [(due: ContinuousClock.Instant, fire: @MainActor () -> Void)] = []
        controller.idleNow = { now }
        controller.idleScheduler = { delay, fire in
            timers.append((now.advanced(by: delay), fire))
            return {}
        }
        controller.ingest(audio(reply, sequence: 0))
        player.hold(true)
        now = now.advanced(by: .seconds(30))
        for timer in timers where timer.due <= now { timer.fire() }
        #expect(controller.status(for: controller.replies[0]) == ReplyPlaybackController.abandonedStatus)
        #expect(player.cancelCount == 1, "the held tail of the abandoned reply is dropped, not left to play later")
    }

    private func audio(_ reply: ReplyDescriptor, sequence: Int) -> HostReplyEvent {
        let payload = AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
            streamID: reply.audioStreamID, isFinal: false, bytes: Data([1, 0]), reply: reply
        )
        let frame = Frame(timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID,
                          payload: .audio(payload))
        return HostReplyEvent(endpointID: "main", frame: frame)
    }
}

/// Shaped like `PCM16AudioPlayer`: it also counts gaps, which is how the echo guard hands out its inner player.
@MainActor
private final class CatchUpPlayer: ReplyAudioPlaying, ReplyCatchUpReporting, PlayoutGapReporting {
    var onCatchingUpChanged: (@MainActor (Bool) -> Void)?
    func takePlayoutGaps() -> PlayoutGapMeter.Gaps { .init() }
    private(set) var isCatchingUp = false
    private(set) var cancelCount = 0
    func hold(_ held: Bool) {
        isCatchingUp = held
        onCatchingUpChanged?(held)
    }
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {
        cancelCount += 1
        isCatchingUp = false
    }
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
