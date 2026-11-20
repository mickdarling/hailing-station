import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ReplyPanelArrivalTests {
    @Test func newestTextDisplaysWhileFirstReplyKeepsControlsAndPlaysInFullBeforeSecond() throws {
        let player = IdlePlayer()
        let playback = ReplyPlaybackController(player: player)
        playback.idleScheduler = { _, _ in {} }
        let first = idleReply()
        let second = ReplyDescriptor(id: UUID(), hostID: "second-mac", targetID: "tmux:other", audioStreamID: UUID())
        func text(_ reply: ReplyDescriptor, _ content: String) -> HostReplyEvent {
            HostReplyEvent(endpointID: "main", frame: Frame(timestamp: 1, source: reply.hostID,
                payload: .text(TextPayload(text: content, reply: reply))))
        }
        playback.ingest(text(first, "First synthetic reply"))
        playback.ingest(idleAudio(first, sequence: 0, final: false, byte: 10))
        playback.ingest(text(second, "Newest synthetic reply"))
        #expect(playback.presentationForDisplay?.transcript == "Newest synthetic reply")
        #expect(playback.presentationForControls?.transcript == "First synthetic reply")
        #expect(playback.presentationForDisplay?.host == second.hostID)
        #expect(playback.presentationForDisplay?.target == second.targetID)
        #expect(playback.presentationForControls?.host == first.hostID)
        #expect(playback.presentationForControls?.target == first.targetID)
        #expect(playback.displayDiffersFromControls)
        #expect(playback.statusForControls == "Playing")
        playback.ingest(idleAudio(second, sequence: 0, final: true, byte: 20))
        playback.ingest(idleAudio(first, sequence: 1, final: true, byte: 11))
        #expect(playback.presentationForDisplay?.transcript == "Newest synthetic reply")
        #expect(playback.presentationForControls?.transcript == "First synthetic reply")
        #expect(player.scheduled.map { $0.bytes.first } == [10, 11])
        player.completeReply()
        #expect(player.scheduled.map { $0.bytes.first } == [10, 11, 20])
        #expect(playback.presentationForControls?.transcript == "Newest synthetic reply")
        #expect(!playback.displayDiffersFromControls)
        player.completeReply()
        #expect(player.cancelCount == 0)
    }
}
