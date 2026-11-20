#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioSelectionAcceptanceTests {
    @Test func acceptanceRetainsAdmittedTargetWhenRouterAdvances() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let ticket = try queue.ticket()
        queue.selectionWillChange(connection, retiring: [], to: .init(target: "original", generation: UUID()))
        let stop = try #require(queue.captureStop(connection))
        queue.selectionWillChange(connection, retiring: [], to: .init(target: "later", generation: UUID()))
        queue.resolve(stop, targets: [])
        expectStopped(queue, ticket: ticket, target: "original")
        if case .sent(true) = queue.enqueue(ticket, connection: nil, target: "later", { true }) {} else {
            Issue.record("router changes after acceptance must not change the accepted target set")
        }
    }

    @Test func resolutionDoesNotAddTextDestinationsLearnedAfterAcceptance() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let original = uncorrelatedDescriptor(audio: true)
        let later = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other", audioStreamID: UUID())
        let old = try queue.ticket(frame: recipientAudio(original, sequence: 0))
        let unrelated = try queue.ticket(frame: recipientAudio(later, sequence: 0))
        queue.deliveredText(original.id, to: connection)
        let stop = try #require(queue.captureStop(connection))
        queue.deliveredText(later.id, to: connection)
        queue.resolve(stop, targets: [])
        expectStopped(queue, ticket: old, target: original.targetID)
        if case .sent(true) = queue.enqueue(unrelated, connection: nil, target: later.targetID, { true }) {} else {
            Issue.record("resolution must not add a text destination learned after acceptance")
        }
    }

    private func expectStopped(_ queue: ReplyAudioQueue, ticket: LocalReplyAudioTicket, target: String) {
        if case .stopped = queue.enqueue(ticket, connection: nil, target: target, { true }) {} else {
            Issue.record("pre-cutoff target must be silent")
        }
    }
}
#endif
