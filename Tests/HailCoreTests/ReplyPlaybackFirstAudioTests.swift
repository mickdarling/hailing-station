import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825: text promises audio; these arrival deadlines use the idle rig's clock, never real sleeps.
@MainActor
@Suite struct ReplyPlaybackFirstAudioTests {
    @Test func missingFirstAudioIsReportedAndSpokenOnce() async throws {
        let rig = IdleRig(), reply = idleReply()
        let renderer = CountingRenderer(), fallback = FirstAudioFallbacks()
        let announcer = Announcer(playback: rig.controller, renderer: renderer) { fallback.record($0, $1) }
        announcer.watchReplyAudio { true }
        rig.controller.ingest(firstAudioText(reply))
        #expect(rig.status(of: reply) == "Received")
        rig.advance(by: .seconds(19))
        #expect(rig.abandoned == 0)
        rig.advance(by: .seconds(1))
        let presentation = try #require(rig.controller.replies.first)
        #expect(rig.status(of: reply) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.controller.audioProblem(replyID: presentation.id) == ReplyPlaybackController.audioDidNotArrive)
        await settleFirstAudio()
        #expect(renderer.rendered == [.replyAudioLost])
        #expect(rig.player.scheduled.last?.isFinal == true)
        #expect(fallback.announcements.isEmpty)
        rig.controller.ingest(firstAudioText(reply))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
        rig.advance(by: .seconds(30))
        await settleFirstAudio()
        #expect(renderer.rendered == [.replyAudioLost])
        #expect(rig.abandoned == 1)
        withExtendedLifetime(announcer) {}
    }

    @Test func arrivalCancelsTheDeadlineEvenWhenPlaybackIsHeld() {
        for hold in ["none", "pause", "capture", "interruption"] {
            let rig = IdleRig(), reply = idleReply()
            rig.controller.ingest(firstAudioText(reply))
            #expect(rig.liveDeadlineCount == 1)
            if hold == "pause" { rig.controller.togglePause() }
            if hold == "capture" { rig.controller.beginCaptureSuppression() }
            if hold == "interruption" { rig.controller.audioInterruption(began: true) }
            rig.advance(by: .seconds(19))
            rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 7))
            rig.advance(by: .seconds(60))
            #expect(rig.abandoned == 0)
            #expect(rig.status(of: reply) != ReplyPlaybackController.abandonedStatus)
            #expect(rig.controller.replies.allSatisfy { rig.controller.audioProblem(replyID: $0.id) == nil })
        }
    }

    @Test func hostStopCancelsPendingAudioOnlyForItsEndpoint() {
        let rig = IdleRig(), stopped = idleReply(), other = idleReply()
        rig.controller.ingest(firstAudioText(stopped))
        rig.controller.ingest(firstAudioText(other, endpoint: "other"))
        #expect(rig.liveDeadlineCount == 2)
        rig.controller.ingest(firstAudioControl(.stopPlayback))
        rig.advance(by: .seconds(20))
        #expect(rig.status(of: stopped) == "Stopped")
        #expect(rig.status(of: other) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.abandoned == 1)
        rig.controller.ingest(idleAudio(stopped, sequence: 0, final: true, byte: 7))
        #expect(rig.player.scheduled.isEmpty)
    }

    @Test func muteCancelsPendingDeadlinesAndDoesNotArmNewOnes() {
        for pendingVoiceMute in [false, true] {
            let rig = IdleRig(), reply = idleReply()
            if pendingVoiceMute {
                rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 1))
            }
            rig.controller.ingest(firstAudioText(reply))
            #expect(rig.liveDeadlineCount == 1)
            if pendingVoiceMute { rig.controller.ingest(firstAudioControl(.setReplyMute(muted: true))) }
            else { rig.controller.toggleMute() }
            #expect(rig.liveDeadlineCount == 0)
            let muted = idleReply()
            rig.controller.ingest(firstAudioText(muted))
            rig.advance(by: .seconds(60))
            #expect(rig.abandoned == 0)
            #expect(rig.status(of: reply) == "Received")
            #expect(rig.status(of: muted) == "Received")
            if pendingVoiceMute { rig.player.completeReply() }
            rig.controller.toggleMute()
            rig.advance(by: .seconds(60))
            #expect(rig.abandoned == 0, "unmute never revives a cancelled deadline")
        }
    }

    @Test func aNewAudioReplySupersedesPausedPendingAudio() {
        let rig = IdleRig(), old = idleReply(), new = idleReply()
        rig.controller.ingest(firstAudioText(old))
        #expect(rig.liveDeadlineCount == 1)
        rig.controller.togglePause()
        rig.controller.ingest(idleAudio(new, sequence: 0, final: true, byte: 2))
        rig.advance(by: .seconds(60))
        #expect(rig.status(of: old) == "Skipped")
        #expect(rig.abandoned == 0)
        rig.controller.ingest(idleAudio(old, sequence: 0, final: true, byte: 1))
        #expect(rig.player.scheduled.map(\.bytes.first) == [2])
    }

    @Test func repliesHaveIndependentDeadlinesAndDuplicateTextDoesNotExtendThem() {
        let rig = IdleRig(), first = idleReply(), second = idleReply()
        rig.controller.ingest(firstAudioText(first))
        rig.advance(by: .seconds(10))
        rig.controller.ingest(firstAudioText(second, endpoint: "other"))
        rig.controller.ingest(firstAudioText(first))
        rig.advance(by: .seconds(10))
        #expect(rig.status(of: first) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.status(of: second) == "Received")
        rig.advance(by: .seconds(10))
        #expect(rig.status(of: second) == ReplyPlaybackController.abandonedStatus)
        #expect(rig.abandoned == 2)
    }

    @Test func refusedFirstAudioRetainsItsActualFailure() {
        for malformed in [false, true] {
            let rig = IdleRig(), reply = idleReply()
            rig.controller.ingest(firstAudioText(reply))
            #expect(rig.liveDeadlineCount == 1)
            var event = idleAudio(reply, sequence: 0, final: true, byte: 7)
            if case .audio(var audio) = event.frame.payload {
                if malformed { audio.bytes = Data([1]) } else { audio.codec = .opus }
                event.frame.payload = .audio(audio)
            }
            rig.controller.ingest(event)
            rig.advance(by: .seconds(60))
            let expected = malformed ? ReplyPlaybackController.audioCouldNotBeDecoded
                : ReplyPlaybackController.audioFormatNotPlayable
            #expect(rig.status(of: reply) == expected)
            #expect(rig.abandoned == 0)
        }
    }

    @Test func textOnlyAndAlreadyCompletedRepliesDoNotAcquireDeadlines() {
        let rig = IdleRig(), textOnly = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "target")
        let completed = idleReply()
        rig.controller.ingest(firstAudioText(completed))
        #expect(rig.liveDeadlineCount == 1)
        rig.controller.ingest(idleAudio(completed, sequence: 0, final: true, byte: 7))
        rig.player.completeReply()
        rig.controller.ingest(firstAudioText(completed))
        rig.controller.ingest(firstAudioText(textOnly))
        rig.advance(by: .seconds(60))
        #expect(rig.abandoned == 0)
        #expect(rig.liveDeadlineCount == 0)
        #expect(rig.status(of: completed) == "Played")
    }
}

func firstAudioText(_ reply: ReplyDescriptor, endpoint: HostEndpoint.Identifier = "main") -> HostReplyEvent {
    HostReplyEvent(endpointID: endpoint, frame: Frame(timestamp: 0, target: reply.targetID, source: reply.hostID,
                   payload: .text(TextPayload(text: "Synthetic reply", reply: reply))))
}

func firstAudioControl(_ control: ControlPayload) -> HostReplyEvent {
    HostReplyEvent(endpointID: "main", frame: Frame(timestamp: 0, source: "host", payload: .control(control)))
}

@MainActor
final class FirstAudioFallbacks {
    var announcements: [Announcement] = []
    var reasons: [Announcer.Fallback] = []
    func record(_ announcement: Announcement, _ reason: Announcer.Fallback) {
        announcements.append(announcement)
        reasons.append(reason)
    }
}

@MainActor
func settleFirstAudio() async {
    for _ in 0..<20 { await Task.yield() }
}
