#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioRetirementTests {
    @Test func retiredTargetSurvivesPostCutoffFlightTrackingDuringStopSend() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        let wire = VoiceStopConfirmationHold(), entered = VoiceStopConfirmationHold()
        let timeout = VoiceStopConfirmationHold()
        var stopping: Task<String, Never>?
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port,
                selecting: ["recipient:other", RecipientTestRig.target], capabilities: [PlaybackStop.capability])
            defer { pair.close() }
            let session = try await stoppingSession(listener)
            let connection = await session.connectionID
            let ledger = await listener.lastInput
            let flight = uncorrelatedDescriptor(audio: true)
            await seedFlight(flight, session: session, ledger: ledger)
            let reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), oldAudio = recipientAudio(reply, sequence: 0, final: true)
            let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: oldAudio)).ticket)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: pair.sockets[1], step: "B retains text") == text)
            stopping = heldStop(listener, connection: connection, timeout: timeout, afterSend: {
                entered.release(); await wire.wait()
            })
            await entered.wait()
            #expect(try await receiveFrame(on: pair.sockets[0], step: "A wire stop").payload == .control(.stopPlayback))
            #expect(await session.repliesInFlight.isEmpty)
            try await pruneFlight(on: pair, listener: listener)
            #expect(!ledger.targets(on: connection, inFlight: [flight.id]).contains(RecipientTestRig.target))
            wire.release()
            #expect(await stopping?.value == "stopped")
            try await verifyOldAndFresh(old, audio: oldAudio, on: pair, listener: listener)
        } catch {
            wire.release(); timeout.release()
            _ = await stopping?.value
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        timeout.release()
        await listener.stop(reason: "synthetic complete")
    }
    private func stoppingSession(_ listener: WebSocketListener) async throws -> HostSession {
        for peer in await listener.peers.values where await peer.session.selectedTarget == "recipient:other" {
            return await peer.session
        }
        throw RetirementTestError.missingSession
    }
}

extension ReplyQueuedAudioRetirementTests {
    @Test func unrelatedPendingStopPreservesCorrelatedRequestAtFinalEnqueue() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        let enqueue = VoiceStopConfirmationHold(), routed = VoiceStopConfirmationHold()
        let waiting = VoiceStopConfirmationHold(), timeout = VoiceStopConfirmationHold()
        let snapshot = VoiceStopConfirmationHold(), captured = VoiceStopConfirmationHold()
        var stopping: Task<String, Never>?
        var publication: Task<LocalReplyAudioReport, any Error>?
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port,
                selecting: ["recipient:other", RecipientTestRig.target], capabilities: [PlaybackStop.capability])
            defer { pair.close() }
            let connection = try await stoppingSession(listener).connectionID
            let reply = try await correlatedReply(on: pair, rig: rig, listener: listener)
            let audio = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            publication = heldPublication(listener, ticket: ticket, audio: audio,
                holds: EnqueueHolds(enqueue: enqueue, routed: routed, waiting: waiting))
            await routed.wait()
            stopping = heldStop(listener, connection: connection, timeout: timeout, beforeSnapshot: {
                captured.release(); await snapshot.wait()
            })
            try await observeStop(on: pair, captured: captured)
            enqueue.release()
            await waiting.wait() // The final enqueue returned pending and the caller registered its retry.
            snapshot.release()
            #expect(await stopping?.value == "stopped")
            #expect(try await publication?.value == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: pair.sockets[1], step: "B correlated audio") == audio)
            try await finishReply(reply, ticket: ticket, on: pair, listener: listener)
            try await pair.boundedBarrier(step: "B delivered in full")
        } catch {
            enqueue.release(); snapshot.release(); timeout.release()
            _ = await stopping?.value
            _ = try? await publication?.value
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        timeout.release()
        await listener.stop(reason: "synthetic complete")
    }
}

extension ReplyQueuedAudioRetirementTests {
    private func seedFlight(_ flight: ReplyDescriptor, session: HostSession, ledger: LastInputLedger) async {
        let connection = await session.connectionID
        ledger.trackFlights([flight.id], frame: recipientAudio(flight, sequence: 0), connection: connection)
        await session.seedRetiringFlight(flight.id)
        #expect(ledger.targets(on: connection, inFlight: [flight.id]) == [RecipientTestRig.target])
        #expect(ledger.targets(on: connection, inFlight: []).isEmpty)
    }
    private func correlatedReply(
        on pair: FallbackSocketPair, rig: RecipientTestRig, listener: WebSocketListener
    ) async throws -> ReplyDescriptor {
        let context = try await pair.submitInput(on: 1, rig: rig)
        let reply = recipientDescriptor(context, audio: true), text = recipientText(reply)
        #expect(try await listener.publish(text) == 1)
        #expect(try await receiveFrame(on: pair.sockets[1], step: "B correlated text") == text)
        return reply
    }
    private func observeStop(on pair: FallbackSocketPair, captured: VoiceStopConfirmationHold) async throws {
        await captured.wait()
        #expect(try await receiveFrame(on: pair.sockets[0], step: "unrelated A stop").payload
            == .control(.stopPlayback))
    }

    private func heldStop(
        _ listener: WebSocketListener, connection: UUID, timeout: VoiceStopConfirmationHold,
        afterSend: (@Sendable () async -> Void)? = nil, beforeSnapshot: (@Sendable () async -> Void)? = nil
    ) -> Task<String, Never> {
        Task {
            await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                await ReplyAudioEnqueueTesting.$afterStopSend.withValue(afterSend, operation: {
                    await ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue(beforeSnapshot, operation: {
                        await listener.stopReplyPlayback(connection: connection, markQueuedAudio: true)
                    })
                })
            })
        }
    }

    private func pruneFlight(on pair: FallbackSocketPair, listener: WebSocketListener) async throws {
        let freshA = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "recipient:other",
                                     audioStreamID: UUID())
        let postAudio = recipientAudio(freshA, sequence: 0)
        let post = try #require(await listener.replyAudio(.init(action: "enqueue", frame: postAudio)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: post, frame: postAudio))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[0], step: "A tracks post-cutoff flight") == postAudio)
    }

    private func verifyOldAndFresh(
        _ old: LocalReplyAudioTicket, audio oldAudio: Frame, on pair: FallbackSocketPair, listener: WebSocketListener
    ) async throws {
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: oldAudio)).skipped)
        try await pair.boundedBarrier(step: "B pre-stop audio is silent and text remains")
        let freshB = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
        let later = try #require(await listener.replyAudio(.init(action: "enqueue", frame: freshB)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: later, frame: freshB))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[1], step: "B post-cutoff target plays") == freshB)
    }

    private func heldPublication(
        _ listener: WebSocketListener, ticket: LocalReplyAudioTicket, audio: Frame,
        holds: EnqueueHolds
    ) -> Task<LocalReplyAudioReport, any Error> {
        let enqueue = holds.enqueue, routed = holds.routed, waiting = holds.waiting
        return Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await ReplyAudioEnqueueTesting.$beforeEnqueue.withValue({
                    routed.release(); await enqueue.wait()
                }, operation: {
                    try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                })
            })
        }
    }

    private func finishReply(
        _ reply: ReplyDescriptor, ticket: LocalReplyAudioTicket,
        on pair: FallbackSocketPair, listener: WebSocketListener
    ) async throws {
        let terminal = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .audio(.init(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 1,
                streamID: reply.audioStreamID, isFinal: true, bytes: Data(), reply: reply)))
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: terminal))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[1], step: "B correlated terminal marker") == terminal)
    }
}

extension HostSession {
    fileprivate func seedRetiringFlight(_ reply: UUID) { repliesInFlight = [reply] }
}
private struct EnqueueHolds: Sendable {
    let enqueue: VoiceStopConfirmationHold
    let routed: VoiceStopConfirmationHold
    let waiting: VoiceStopConfirmationHold
}
private enum RetirementTestError: Error { case missingSession }
#endif
