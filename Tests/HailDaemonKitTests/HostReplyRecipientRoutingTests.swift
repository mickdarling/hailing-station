import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct HostReplyRecipientRoutingTests {
    @Test(arguments: [false, true])
    func sameTargetInterleavedRequestsStayOnTheirOriginalSocket(reverseOrder: Bool) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test"
        )
        let port = try await listener.start()
        do {
            try await exercise(listener: listener, rig: rig, port: port, reverseOrder: reverseOrder)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exercise(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16, reverseOrder: Bool
    ) async throws {
        let (firstSession, first) = try recipientSocket(port: port)
        let (secondSession, second) = try recipientSocket(port: port)
        defer {
            first.cancel(with: .normalClosure, reason: nil)
            second.cancel(with: .normalClosure, reason: nil)
            firstSession.invalidateAndCancel()
            secondSession.invalidateAndCancel()
        }
        // Deliberately identical display names: a name is never recipient authority.
        for socket in [first, second] {
            try await recipientSocketSend(helloFrame(), on: socket)
            _ = try await recipientSocketReceive(on: socket)
            try await recipientSocketSend(
                sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))), on: socket
            )
            try await recipientSocketBarrier(on: socket)
        }
        let sockets = reverseOrder ? [second, first] : [first, second]
        var replies: [ReplyDescriptor] = []
        for socket in sockets {
            try await recipientSocketSend(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ), on: socket)
            try await recipientSocketBarrier(on: socket)
            replies.append(recipientDescriptor(try #require(await rig.adapter.contexts.last), audio: true))
        }
        #expect(replies[0].requestID != replies[1].requestID)
        for (index, sequence, isText, final) in [
            (1, 0, false, false), (0, 0, true, false), (1, 0, true, false),
            (0, 0, false, false), (1, 1, false, true), (0, 1, false, true)
        ] {
            let reply = replies[index]
            let frame = isText ? recipientText(reply) : recipientAudio(reply, sequence: sequence, final: final)
            try #require(await listener.publish(frame) == 1)
            #expect(try await recipientSocketReceive(on: sockets[index]) == frame)
            try await recipientSocketBarrier(on: sockets[1 - index])
            try await recipientSocketBarrier(on: sockets[index])
        }
        let legacy = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target)
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(recipientText(legacy)) }
        for socket in sockets { try await recipientSocketBarrier(on: socket) }
    }

    /// A spoken request and a locally dispatched one (#188) on the same connection interleave like two
    /// spoken ones; a second connection selecting the same target stays silent throughout.
    @Test func phoneAndDispatchedRequestsInterleaveOnOneConnection() async throws {
        let rig = try await RecipientTestRig.make()
        let (listener, connected) = try dispatchListener(rig: rig)
        let port = try await listener.start()
        do {
            try await exerciseInterleaved(listener: listener, rig: rig, port: port, connected: connected)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseInterleaved(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16, connected: ConnectedPeerIDs
    ) async throws {
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target, RecipientTestRig.target]
        )
        defer { pair.close() }
        let ids = connected.all
        try #require(ids.count == 2)
        let spoken = recipientDescriptor(try await pair.submitInput(on: 0, rig: rig), audio: true)
        let owner = try #require(await listener.dispatch(dispatchRequest(connection: ids[0])))
        let dispatched = recipientDescriptor(try #require(await rig.adapter.contexts.last), audio: true)
        #expect(dispatched.requestID == owner)
        #expect(spoken.requestID != owner)
        for (reply, sequence, isText, final) in [
            (dispatched, 0, false, false), (spoken, 0, true, false), (dispatched, 0, true, false),
            (spoken, 0, false, false), (dispatched, 1, false, true), (spoken, 1, false, true)
        ] {
            let frame = isText ? recipientText(reply) : recipientAudio(reply, sequence: sequence, final: final)
            try #require(await listener.publish(frame) == 1)
            #expect(try await recipientSocketReceive(on: pair.sockets[0]) == frame)
            try await pair.barrier()
        }
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(recipientText(spoken)) }
        try await pair.barrier()
    }
}
