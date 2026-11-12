#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioBarrierTests {
    @Test(arguments: ["device", "playback", "privacy", "retired-flight"], [false, true])
    func firstFrameWaitsForSnapshotAndSurvivesTeardown(source: String, teardown: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let holds = QueuedStopSnapshotHolds()
        let waiting = VoiceStopConfirmationHold()
        defer { holds.release() }
        do {
            try await rig.start()
            let listener = rig.env.listener
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let connection = try #require(rig.env.router.activeConnection())
            let peerID = try await peerID(on: listener, connection: connection)
            let reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0, final: true)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: other.sockets[0], step: "B keeps pre-stop text") == text)
            if source == "retired-flight" { try await seedFlightOnlyTarget(connection, on: listener) }
            let stop = Task { await beginStop(source, rig: rig, connection: connection, holds: holds) }
            await holds.entered.wait()
            let publication = Task {
                try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                    try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                })
            }
            await waiting.wait() // Registered continuation: the first frame has actually attempted admission.
            if teardown { await listener.peerEnded(peerID) }
            try await playPostStop(on: other, listener: listener)
            holds.snapshot.release()
            await stop.value
            #expect(try await publication.value == LocalReplyAudioReport(skipped: true))
            try await other.boundedBarrier(step: "B receives no pre-stop audio after snapshot")
        } catch {
            holds.snapshot.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    private func seedFlightOnlyTarget(_ connection: UUID, on listener: WebSocketListener) async throws {
        let id = try await peerID(on: listener, connection: connection)
        let peer = try #require(await listener.peers[id])
        let reply = uncorrelatedDescriptor(audio: true), frame = recipientAudio(reply, sequence: 0)
        let ledger = await listener.lastInput
        ledger.trackFlights([reply.id], frame: frame, connection: connection)
        await peer.session.seedRetiredQueueFlight(reply.id)
    }

    private func beginStop(
        _ source: String, rig: DeviceVoiceStopRig, connection: UUID, holds: QueuedStopSnapshotHolds
    ) async {
        await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await holds.timeout.wait() }, operation: {
            await ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue({
                holds.entered.release()
                await holds.snapshot.wait()
            }, operation: {
                switch source {
                case "device": await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
                case "privacy": rig.env.router.holdReplies(connection, listener: rig.env.listener)
                default: _ = await rig.env.listener.stopReplyPlayback(connection: connection, markQueuedAudio: true)
                }
            })
        })
    }

    private func peerID(
        on listener: WebSocketListener, connection: UUID, excluding: Bool = false
    ) async throws -> UUID {
        for (id, peer) in await listener.peers {
            let matches = await peer.session.connectionID == connection
            if matches != excluding { return id }
        }
        throw QueuedStopTestError.missingPeer
    }

    private func playPostStop(on pair: FallbackSocketPair, listener: WebSocketListener) async throws {
        let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
        let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: frame)).ticket)
        // This completes while the session snapshot is still held. No settle interval or negative timing claim.
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: pair.sockets[0], step: "post-stop ticket bypasses barrier") == frame)
    }
}

extension ReplyQueuedAudioBarrierTests {
    @Test(arguments: [false, true], [false, true])
    func unresolvableSnapshotCutsOnlyUnpublishedJobs(privacy: Bool, closedSession: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            let listener = rig.env.listener, queue = listener.replyAudioQueue
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            _ = try await other.submitInput(on: 0, rig: rig.env.rig)
            let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let route = try #require(await listener.lastInputRoute(frame))
            let originalID = try await peerID(on: listener, connection: route.entry.connection, excluding: true)
            let original = try #require(await listener.peers[originalID])
            let connection = await original.session.connectionID
            let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: frame)).ticket)
            let unrelated = try queue.ticket()
            let stop = try #require(queue.captureStop(connection))
            if closedSession {
                _ = await original.session.failure(.malformed, "synthetic closure", close: true)
            } else { await listener.peerEnded(originalID) }
            if privacy {
                #expect(await listener.dropPrivateReplies(connection: stop.connection, stop: stop) == 0)
            } else {
                _ = await listener.stopReplyPlayback(connection: stop.connection, markQueuedAudio: true,
                    queueStop: stop)
            }
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: frame)).skipped)
            // Unknown queued jobs fail closed, but this is not a cutoff for already-published streams.
            #expect(!queue.valid(old))
            #expect(queue.valid(unrelated))
            #expect(queue.enqueue(unrelated, connection: nil, target: "unrelated", { true }) == .stopped)
            try await playPostStop(on: other, listener: listener)
            try await other.boundedBarrier(step: "unresolvable stop sends no old audio")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
extension HostSession {
    fileprivate func seedRetiredQueueFlight(_ reply: UUID) {
        selectedTarget = "unrelated:selection"
        repliesInFlight = [reply]
    }
}
private struct QueuedStopSnapshotHolds: Sendable {
    let snapshot = VoiceStopConfirmationHold()
    let entered = VoiceStopConfirmationHold()
    let timeout = VoiceStopConfirmationHold()
    func release() { snapshot.release(); timeout.release() }
}
private enum QueuedStopTestError: Error { case missingPeer }
#endif
