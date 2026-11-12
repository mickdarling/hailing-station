#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioBudgetTests {
    @Test(arguments: [false, true])
    func overlappingSuccessfulStopsShareFirstDeadline(finalEnqueue: Bool) async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { timeout.release(); clock.release() }
        let queue = clock.queue(), connection = UUID()
        queue.register(connection)
        let old = try queue.ticket()
        let first = try capture(queue, connection, timeout)
        let task: Task<Void, any Error>
        if finalEnqueue {
            #expect(queue.enqueue(old, connection: nil, target: "U", { true }) == .pending)
            task = Task {} // First barrier was encountered only at the final enqueue.
        } else {
            task = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                    try await queue.waitForStops(old)
                })
            }
            await waiting.wait()
        }
        await clock.sleepEntered.wait()
        let deadline = try #require(clock.deadline.withLock { $0 })
        #expect(deadline == clock.origin.advanced(by: .milliseconds(250)))
        clock.advance(.milliseconds(100))
        let second = try capture(queue, connection, timeout)
        queue.resolve(first, targets: ["T"])
        clock.advance(.milliseconds(100))
        let third = try capture(queue, connection, timeout)
        queue.resolve(second, targets: ["T"])
        #expect(queue.enqueue(old, connection: nil, target: "U", { true }) == .pending)
        clock.advance(.milliseconds(49))
        #expect(queue.enqueue(old, connection: nil, target: "U", { true }) == .pending)
        try await expectPostCutoffPlays(queue)
        clock.advance(.milliseconds(1))
        clock.release()
        try await task.value
        assertBudgetSkip(queue, ticket: old)
        queue.resolve(third, targets: ["T"])
        assertBudgetSkip(queue, ticket: old)
        queue.finish(old)
    }

    @Test func cancellationRetiresRecordAndWaiter() async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { timeout.release(); clock.release() }
        let queue = clock.queue(), connection = UUID()
        queue.register(connection)
        let ticket = try queue.ticket(), stop = try capture(queue, connection, timeout)
        let task = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(ticket)
            })
        }
        await waiting.wait()
        #expect(queue.waiterCount == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(queue.waiterCount == 0)
        #expect(queue.outstandingCount == 0)
        #expect(!queue.valid(ticket))
        queue.associate(ticket, frame: recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0))
        #expect(!queue.valid(ticket))
        queue.resolve(stop, targets: [])
    }

    private func assertBudgetSkip(_ queue: ReplyAudioQueue, ticket: LocalReplyAudioTicket) {
        #expect(queue.enqueue(ticket, connection: nil, target: "U", {
            Issue.record("wait budget must never publish at its deadline"); return true
        }) == .waitBudget)
        #expect(queue.waiterCount == 0)
    }

    private func expectPostCutoffPlays(_ queue: ReplyAudioQueue) async throws {
        let post = try queue.ticket()
        try await queue.waitForStops(post)
        #expect(queue.enqueue(post, connection: nil, target: "T", { true }) == .sent(true))
    }

    private func capture(
        _ queue: ReplyAudioQueue, _ connection: UUID, _ timeout: QueuedAudioGate
    ) throws -> ReplyAudioQueue.Stop {
        try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
    }
}

#endif
