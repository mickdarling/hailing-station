import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Loopback proof of #188 local dispatch: the named connection, and only it, owns the reply.
@Suite(.serialized) struct LocalDispatchTests {
    @Test func dispatchedReplyReachesOnlyTheNamedConnection() async throws {
        let rig = try await RecipientTestRig.make()
        let (listener, connected) = try dispatchListener(rig: rig)
        let port = try await listener.start()
        do {
            try await exerciseNamedConnection(listener: listener, rig: rig, port: port, connected: connected)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseNamedConnection(
        listener: WebSocketListener, rig: RecipientTestRig, port: UInt16, connected: ConnectedPeerIDs
    ) async throws {
        // Both connections select the same target; only the one named by its listener id may hear.
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target, RecipientTestRig.target]
        )
        defer { pair.close() }
        let ids = connected.all
        try #require(ids.count == 2)
        let owner = try #require(await listener.dispatch(dispatchRequest(connection: ids[0])))
        let context = try #require(await rig.adapter.contexts.last)
        #expect(context.id == owner)
        let peer = try #require(await listener.peers[ids[0]])
        let ownerConnection = await peer.session.connectionID
        #expect(context.connectionID == ownerConnection)
        let reply = recipientText(recipientDescriptor(context))
        try #require(await listener.publish(reply) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[0]) == reply)
        try await pair.barrier()
        // The other connection is reachable only by its own id, and the first owner's duplicate is refused.
        let second = try #require(await listener.dispatch(
            dispatchRequest(connection: ids[1], text: "second synthetic input")
        ))
        #expect(second != owner)
        let secondReply = recipientText(recipientDescriptor(try #require(await rig.adapter.contexts.last)))
        try #require(await listener.publish(secondReply) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[1]) == secondReply)
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(reply) }
        try await pair.barrier()
    }

    @Test func responseShapeDistinguishesDispatchFromReply() throws {
        let owner = UUID()
        // Reply answers are the exact bytes the endpoint wrote before this slice; no sorting, no `request` key.
        let success = try JSONEncoder().encode(LocalReplyResponse(delivered: 1))
        #expect(success == Data(#"{"delivered":1}"#.utf8))
        let refused = try JSONEncoder().encode(LocalReplyResponse(delivered: 0, error: "x", code: .noRecipient))
        #expect(String(data: refused, encoding: .utf8)?.contains("request") == false)
        for (response, expected) in [
            (LocalReplyResponse(delivered: 0, error: "x", code: .noRecipient),
             #"{"code":"noRecipient","delivered":0,"error":"x"}"#),
            (.dispatch(delivered: 1, request: owner), #"{"delivered":1,"request":"\#(owner.uuidString)"}"#),
            (.dispatch(delivered: 1, request: nil), #"{"delivered":1,"request":null}"#),
            (.dispatch(delivered: 1, request: nil, error: "e", code: .publicationFailed),
             #"{"code":"publicationFailed","delivered":1,"error":"e","request":null}"#)
        ] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(response)
            #expect(String(data: data, encoding: .utf8) == expected)
            #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: data) == response)
        }
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: success) == LocalReplyResponse(delivered: 1))
        #expect(LocalReplyResponse(delivered: 1) != .dispatch(delivered: 1, request: nil))
    }
}
