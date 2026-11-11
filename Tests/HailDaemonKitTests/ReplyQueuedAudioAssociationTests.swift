#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioAssociationTests {
    @Test func stopSnapshotsSelectedCoveredPinnedInFlightAndRequestOwnerTargets() async throws {
        let rig = try await RecipientTestRig.make()
        let routes = try VoiceRoutes(defaultTarget: "selected:one", routes: [
            .init(target: "selected:one", name: "Selected"), .init(target: "covered:one", name: "Covered")
        ])
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer().naming(routes), hostName: "mac-test")
        let port = try await listener.start()
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port,
                selecting: [RecipientTestRig.target], capabilities: [PlaybackStop.capability])
            defer { pair.close() }
            let context = try await pair.submitInput(on: 0, rig: rig)
            let session = try #require(await listener.peers.values.first?.session)
            let ledger = await listener.lastInput
            let flight = UUID()
            let entry = LastInputLedger.Entry(connection: context.connectionID, generation: UUID(), at: .now)
            ledger.pin(UUID(), target: "pinned:one", to: entry)
            ledger.trackFlights([flight], frame: Frame(timestamp: 1, target: "flight:one", source: "mac-test",
                payload: .text(TextPayload(text: "synthetic", reply: .init(
                    id: flight, hostID: "mac-test", targetID: "flight:one"
                )))), connection: context.connectionID)
            await session.seedQueueStopAssociations(selected: "selected:one", flight: flight)
            let ticket = try await queuedAudioTicket(listener)
            #expect(await listener.stopReplyPlayback(connection: context.connectionID, markQueuedAudio: true)
                == "stopped")
            #expect(try await receiveFrame(on: pair.sockets[0], step: "association stop")
                .payload == .control(.stopPlayback))
            let queue = await listener.replyAudioQueue
            expectAssociations(queue, ticket: ticket)
            try await pair.boundedBarrier(step: "association snapshot complete")
        } catch {
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        await listener.stop(reason: "synthetic complete")
    }

    private func expectAssociations(_ queue: ReplyAudioQueue, ticket: LocalReplyAudioTicket) {
        for target in ["selected:one", "covered:one", "pinned:one", "flight:one", RecipientTestRig.target] {
            if case .stopped = queue.enqueue(ticket, connection: nil, target: target, { true }) {} else {
                Issue.record("missing host target association: \(target)")
            }
        }
        if case .sent(true) = queue.enqueue(ticket, connection: nil, target: "unrelated:one", { true }) {} else {
            Issue.record("a stop must not mark an unrelated target")
        }
    }

    @Test func targetStopWinsFinalEnqueueOnAnotherConnection() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let hold = VoiceStopConfirmationHold()
        do {
            try await rig.start()
            let listener = rig.env.listener
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            let context = try await other.submitInput(on: 0, rig: rig.env.rig)
            let frame = recipientAudio(recipientDescriptor(context, audio: true), sequence: 0, final: true)
            let ticket = try await queuedAudioTicket(listener)
            let publication = Task {
                try await ReplyAudioEnqueueTesting.$beforeEnqueue.withValue({ await hold.wait() }, operation: {
                    try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
                })
            }
            try #require(await eventually { hold.entered })
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "A stops shared target")
                .payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            hold.release()
            #expect(try await publication.value == LocalReplyAudioReport(skipped: true))
            try await other.boundedBarrier(step: "B final enqueue refused by target mark")
            try await rig.pair.boundedBarrier(step: "A complete")
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}

extension HostSession {
    /// Synthetic bookkeeping isolates each stop association independently of ordinary route selection.
    fileprivate func seedQueueStopAssociations(selected: String, flight: UUID) {
        selectedTarget = selected
        repliesInFlight = [flight]
    }
}
#endif
