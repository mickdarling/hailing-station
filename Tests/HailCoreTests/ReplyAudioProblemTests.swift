import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825, #822: a reply whose audio did not play says so, never silently; a reply that played does not.
@MainActor
@Suite struct ReplyAudioProblemTests {
    @Test func aStreamEndedWithoutItsFinalAudioDidNotArrive() {
        let rig = IdleRig()
        let stuck = idleReply()
        rig.controller.ingest(idleAudio(stuck, sequence: 0, final: false, byte: 10))
        rig.advance(by: .seconds(25))
        let id = presentationID(stuck)
        #expect(rig.controller.audioProblem(replyID: id) == ReplyPlaybackController.audioDidNotArrive)
        #expect(rig.controller.audioProblems == [id: ReplyPlaybackController.audioDidNotArrive])
    }

    @Test func aReplyThatFailedToPlayCouldNotPlay() {
        let controller = ReplyPlaybackController(player: FailingPlayer())
        let reply = idleReply()
        controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 1))
        #expect(controller.audioProblem(replyID: presentationID(reply)) == ReplyPlaybackController.audioCouldNotPlay)
    }

    @Test func aReplyThatPlayedHasNoProblem() {
        let rig = IdleRig()
        let reply = idleReply()
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 1))
        rig.player.completeReply()
        #expect(rig.controller.audioProblem(replyID: presentationID(reply)) == nil)
        #expect(rig.controller.audioProblems.isEmpty)
    }

    @Test func onlyLostAudioStatusesCount() {
        #expect(ReplyPlaybackController.audioProblem("Played") == nil)
        #expect(ReplyPlaybackController.audioProblem("Waiting for audio") == nil)
        #expect(ReplyPlaybackController.audioProblem("Playback failed") == ReplyPlaybackController.audioCouldNotPlay)
        #expect(ReplyPlaybackController.audioProblem(ReplyPlaybackController.abandonedStatus)
            == ReplyPlaybackController.audioDidNotArrive)
    }

    private func presentationID(_ reply: ReplyDescriptor) -> String {
        "main|\(reply.id.uuidString.lowercased())"
    }
}

private final class FailingPlayer: ReplyAudioPlaying {
    struct Failure: Error {}
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws { throw Failure() }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
