import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveReplyArrivalTests {
    @Test func sameThreadProgressAudioNeverCountsAsAnAnswerToThePendingOwnerTurn() throws {
        let rig = try makeRig()
        #expect(rig.playback.replies.first { $0.id == rig.progressID }?.isSessionUpdate == true)
        #expect(rig.playback.replies.first { $0.id == rig.ordinaryID }?.isSessionUpdate == false)
        #expect(rig.log.threadReplyIDs(endpointID: "mac", targetID: "tmux:work",
                                      among: rig.playback.replies, addressed: true) == [rig.ordinaryID])
    }

    @Test func progressDiscriminatorSurvivesEvictionOfItsConversationCard() throws {
        let rig = try makeRig()
        for index in 0..<ConversationLog.limit {
            rig.log.noteSent("Synthetic other turn \(index)", endpointID: "mac", targetID: "tmux:other")
        }
        #expect(rig.log.entries.allSatisfy { $0.updatePriority == nil })
        #expect(rig.playback.replies.contains { $0.id == rig.progressID && $0.isSessionUpdate })
        #expect(rig.log.threadReplyIDs(endpointID: "mac", targetID: "tmux:work",
                                      among: rig.playback.replies) == [rig.ordinaryID])
    }

    private struct Rig {
        let log: ConversationLog
        let playback: ReplyPlaybackController
        let progressID: String
        let ordinaryID: String
    }

    private func makeRig() throws -> Rig {
        let log = ConversationLog(now: { Date(timeIntervalSince1970: 1) })
        let playback = ReplyPlaybackController(player: IdlePlayer())
        playback.idleScheduler = { _, _ in {} }
        playback.proactive.authorize = { _, _, _ in true }
        let update = UUID(), answer = UUID()
        log.noteSent("Pending question", pasted: "Synthetic pending draft", endpointID: "mac",
                     targetID: "tmux:work")
        let card = HostReplyEvent(endpointID: "mac", frame: Frame(timestamp: 1, target: "tmux:work", source: "host",
            payload: .control(.sessionUpdate(update: update, session: "Work", priority: "info",
                                             text: "Progress only."))))
        log.noteSessionUpdate(card)
        let progress = ReplyDescriptor(id: update, hostID: "host", targetID: "tmux:work", audioStreamID: UUID(),
                                       priority: .background, sessionUpdateID: update)
        let ordinary = ReplyDescriptor(id: answer, hostID: "host", targetID: "tmux:work")
        HostNoticeOrigin.$generation.withValue(UUID()) {
            playback.ingest(idleAudio(progress, sequence: 0, final: true, byte: 1, endpoint: "mac"))
            playback.ingest(HostReplyEvent(endpointID: "mac", frame: Frame(timestamp: 2,
                target: "tmux:work", source: "host",
                payload: .text(TextPayload(text: "Ordinary requested answer.", reply: ordinary)))))
        }
        #expect(log.entries.first?.pasteState == .pending)
        return Rig(log: log, playback: playback, progressID: "mac|\(update.uuidString.lowercased())",
                   ordinaryID: "mac|\(answer.uuidString.lowercased())")
    }
}
