#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioRoutingTests {
    @Test(arguments: [false, true])
    func correlatedDestinationDeterminesWhichStopApplies(stopOwner: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let events = Mutex<[WebSocketListenerEvent]>([])
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test",
            log: { event in events.withLock { $0.append(event) } })
        let port = try await listener.start()
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port,
                selecting: [RecipientTestRig.target, RecipientTestRig.target], capabilities: [PlaybackStop.capability])
            defer { pair.close() }
            let contextA = try await pair.submitInput(on: 0, rig: rig)
            let contextB = try await pair.submitInput(on: 1, rig: rig)
            let reply = recipientDescriptor(contextB, audio: true)
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: pair.sockets[1], step: "owned text") == text)
            let ticket = try await queuedAudioTicket(listener)
            let connection = stopOwner ? contextB.connectionID : contextA.connectionID
            #expect(await listener.stopReplyPlayback(connection: connection) == "stopped")
            #expect(try await receiveFrame(on: pair.sockets[stopOwner ? 1 : 0], step: "scoped stop")
                .payload == .control(.stopPlayback))
            let result = try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
            #expect(result.skipped == stopOwner)
            if stopOwner {
                let request = try #require(reply.requestID)
                #expect(events.withLock { $0.filter { $0.event == "reply_audio_skipped" }.map(\.detail) }
                    == ["reason=stopped request=\(request.uuidString) ticket=\(ticket.position)"])
                try await expectRetainedRequest(contextB, frame: audio, listener: listener)
            } else {
                #expect(try await receiveFrame(on: pair.sockets[1], step: "other connection audio") == audio)
                #expect(events.withLock { $0.allSatisfy { $0.event != "reply_audio_skipped" } })
            }
            try await pair.boundedBarrier(step: "scoped queue decision complete")
        } catch {
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        await listener.stop(reason: "synthetic complete")
    }

    private func expectRetainedRequest(
        _ context: ProviderTurnContext, frame: Frame, listener: WebSocketListener
    ) async throws {
        for peer in await listener.peers.values {
            let session = await peer.session
            if await session.connectionID == context.connectionID {
                #expect(await session.replyRequests[context.id] != nil)
                #expect(await session.replyPublicationStatus(frame) == .ready)
                return
            }
        }
        Issue.record("expected the request's live owning session")
    }

    @Test func ticketEpochAndBoundsFailClosed() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            let issued = try await queuedAudioTicket(rig.env.listener)
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0)
            for ticket in [LocalReplyAudioTicket(epoch: UUID(), position: issued.position),
                           LocalReplyAudioTicket(epoch: issued.epoch, position: 0),
                           LocalReplyAudioTicket(epoch: issued.epoch, position: issued.position + 1)] {
                await #expect(throws: LocalReplyRefusal.invalidReplyPayload) {
                    try await rig.env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio))
                }
            }
            try await barrier(on: rig.socket, step: "invalid tickets send nothing")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
