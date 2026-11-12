#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioRoundTwoTests {
    @Test(arguments: [false, true])
    func admittedCheckClearsDeadlineBeforeDelayedPublish(newStop: Bool) async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { clock.release(); timeout.release() }
        let rig = try await clock.makeRig()
        do {
            let listener = rig.env.listener, queue = listener.replyAudioQueue, connection = UUID()
            queue.register(connection)
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            let stop = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                try #require(queue.captureStop(connection))
            })
            let checking = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                    try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio))
                })
            }
            await waiting.wait()
            await clock.sleepEntered.wait()
            queue.resolve(stop, targets: [])
            #expect(try await checking.value == LocalReplyAudioReport())
            clock.advance(.milliseconds(500))
            if newStop {
                let later = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                    try #require(queue.captureStop(connection))
                })
                #expect(queue.enqueue(ticket, connection: nil, target: RecipientTestRig.target, { true }) == .pending)
                queue.resolve(later, targets: [])
            }
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "delayed first frame plays once") == audio)
            #expect(queue.outstandingCount == 0)
            #expect(rig.details("reply_audio_skipped").isEmpty)
            try await rig.pair.boundedBarrier(step: "one publication only")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
    @Test(arguments: [false, true])
    func pruningResumesRegisteredWaiterExactlyOnce(cancel: Bool) async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { clock.release(); timeout.release() }
        let queue = clock.queue(), connection = UUID(), completions = Mutex(0)
        queue.register(connection)
        let ticket = try queue.ticket()
        let stop = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
        let task = Task {
            defer { completions.withLock { $0 += 1 } }
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(ticket)
            })
        }
        await waiting.wait()
        #expect(queue.waiterCount == 1)
        clock.advance(ReplyAudioQueue.jobLifetime)
        #expect(!queue.valid(ticket)) // Prune wakes the continuation before any cancellation cleanup.
        if cancel { task.cancel() }
        _ = try? await task.value
        queue.finish(ticket)
        queue.resolve(stop, targets: [])
        #expect(completions.withLock { $0 } == 1)
        #expect(queue.waiterCount == 0)
        #expect(queue.outstandingCount == 0)
    }
    @Test func capturedTimeoutReleasesUncoveredBarrierButMarksCoveredTicket() async throws {
        let clock = QueuedAudioClock(), timeout = QueuedAudioGate(), waiting = VoiceStopConfirmationHold()
        defer { clock.release(); timeout.release() }
        let queue = clock.queue(), connection = UUID()
        queue.register(connection)
        let covered = try queue.ticket(), uncovered = try queue.ticket()
        let stop = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
        let task = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(uncovered)
            })
        }
        await waiting.wait()
        #expect(queue.captureTargets(["T"], through: stop) == ["T"])
        clock.advance(.milliseconds(250))
        queue.resolve(stop, targets: nil)
        try await task.value
        #expect(queue.enqueue(covered, connection: nil, target: "T", { true }) == .stopped)
        #expect(queue.enqueue(uncovered, connection: nil, target: "U", { true }) == .sent(true))
    }
    @Test func releaseRequiresIssuingCapabilityAndCannotResurrect() throws {
        let clock = QueuedAudioClock(), queue = clock.queue()
        let ticket = try queue.ticket(), other = try queue.ticket()
        for _ in 2..<ReplyAudioQueue.jobLimit { _ = try queue.ticket() }
        #expect(throws: ReplyAudioQueue.Refusal.capacity) { try queue.ticket() }
        queue.release(.init(epoch: ticket.epoch, position: other.position, releaseKey: ticket.releaseKey))
        #expect(queue.valid(other))
        queue.release(ticket)
        queue.release(ticket)
        #expect(!queue.valid(ticket))
        #expect(queue.outstandingCount == ReplyAudioQueue.jobLimit - 1)
        let replacement = try queue.ticket()
        #expect(queue.valid(replacement))
        queue.associate(ticket, frame: recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0))
        #expect(queue.enqueue(ticket, connection: nil, target: "U", { true }) == .expired)
        queue.finish(other)
        queue.release(other)
        let expired = try queue.ticket()
        clock.advance(ReplyAudioQueue.jobLifetime)
        queue.release(expired)
        queue.release(.init(epoch: UUID(), position: 123))
        #expect(queue.outstandingCount == 0)
    }
    @Test func finishRemovesDestinationBeforeLaterStop() throws {
        let queue = ReplyAudioQueue(), connection = UUID(), reply = uncorrelatedDescriptor(audio: true)
        queue.register(connection)
        let first = try queue.ticket(frame: recipientAudio(reply, sequence: 0))
        queue.deliveredText(reply.id, to: connection)
        queue.finish(first)
        let second = try queue.ticket(frame: recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0))
        queue.stop(connection, targets: [])
        #expect(queue.enqueue(second, connection: nil, target: reply.targetID, { true }) == .sent(true))
    }
}

extension ReplyQueuedAudioRoundTwoTests {
    @Test(arguments: ["check", "publish", "routing"])
    func expiryKeepsCorrelatedTextAndRequest(action: String) async throws {
        let clock = QueuedAudioClock(), entered = VoiceStopConfirmationHold(), hold = VoiceStopConfirmationHold()
        let rig = try await clock.makeRig()
        defer { hold.release(); clock.release() }
        do {
            let listener = rig.env.listener
            let context = try await rig.pair.submitInput(on: 0, rig: rig.env.rig)
            let peer = try #require(await listener.peers.values.first)
            let reply = recipientDescriptor(context, audio: true), text = queuedTextCard(reply)
            let audio = recipientAudio(reply, sequence: 0, final: true)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text and card delivered") == text)
            let report: LocalReplyAudioReport
            if action == "routing" {
                let task = Task {
                    try await ReplyAudioEnqueueTesting.$beforeEnqueue.withValue({
                        entered.release(); await hold.wait()
                    }, operation: {
                        try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                    })
                }
                await entered.wait()
                clock.advance(ReplyAudioQueue.jobLifetime)
                hold.release()
                report = try await task.value
            } else {
                clock.advance(ReplyAudioQueue.jobLifetime)
                report = try await listener.replyAudio(.init(action: action, ticket: ticket, frame: audio))
            }
            #expect(report.skipped)
            #expect(rig.details("reply_audio_skipped") == [
                "reason=expired request=\(context.id.uuidString) ticket=\(ticket.position)"
            ])
            #expect(await peer.session.hasRoundTwoRequest(context.id))
            try await rig.pair.boundedBarrier(step: "expired audio leaves text and request intact")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
    @Test func recoveryAllowsOnlyTerminalAfterTransientStreamRefusal() throws {
        let queue = ReplyAudioQueue(), reply = uncorrelatedDescriptor(audio: true)
        let first = recipientAudio(reply, sequence: 0)
        let ticket = try queue.ticket(frame: first)
        let terminal = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .audio(.init(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 1,
                streamID: reply.audioStreamID, isFinal: true, bytes: Data([0, 0]), reply: reply)))
        #expect(queue.recoveryTerminal(ticket, frame: terminal))
        #expect(!queue.recoveryTerminal(ticket, frame: first))
        #expect(!queue.recoveryTerminal(ticket,
            frame: recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 1, final: true)))
        #expect(queue.enqueue(ticket, connection: nil, target: "T", publishing: true, { true }) == .sent(true))
        #expect(queue.allowRecovery(ticket))
        #expect(queue.enqueue(ticket, connection: nil, target: "T", { true }) == .terminalOnly)
        #expect(queue.enqueue(ticket, connection: nil, target: "T", terminal: true, { true }) == .sent(true))
        queue.finish(ticket)
        #expect(queue.enqueue(ticket, connection: nil, target: "T", terminal: true, { true }) == .expired)
    }
}
extension HostSession {
    fileprivate func hasRoundTwoRequest(_ id: UUID) -> Bool { replyRequests[id] != nil }
}
#endif
