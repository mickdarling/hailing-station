#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230 over loopback sockets: two devices select the same legacy target, as the iPhone and iPad did. A reply naming
/// an ambient reference reaches only the device whose dispatch minted it; the request-less shape reaches the last
/// input device (#370).
/// Synthetic only; not device hearing.
@Suite(.serialized) struct AmbientReplyReferenceRoutingTests {
    @Test func aReferencedReplyReachesOnlyTheOriginatingDeviceInBothOrders() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, connected) = try rig.listener()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [LegacyReferenceRig.target, LegacyReferenceRig.target]
        )
        defer { pair.close() }
        do {
            for origin in [0, 1, 0] {
                let connection = try await listener.sessionConnection(of: connected.all[origin])
                let owner = try #require(
                    try await ambientDispatch(listener, LegacyReferenceRig.request(connection: connection))
                )
                // The pane received the prompt with the reference in its own trailing block.
                let typed = try #require(await rig.adapter.deliveries.last?.text)
                #expect(typed == "synthetic input"
                    + RightyoInputEvent.replyBlock(target: LegacyReferenceRig.target, request: owner))
                #expect(blockReference(in: typed) == owner)
                let reply = referenceDescriptor(owner, audio: true)
                for frame in [recipientText(reply), recipientAudio(reply, sequence: 0),
                              recipientAudio(reply, sequence: 1, final: true)] {
                    #expect(try await listener.publish(frame) == 1)
                    #expect(try await recipientSocketReceive(on: pair.sockets[origin]) == frame)
                }
                // The other device heard nothing; the request-less shape follows the last input device (#370).
                try await pair.barrier()
                let requestless = recipientText(referenceDescriptor(nil))
                #expect(try await listener.publish(requestless) == 1)
                #expect(try await recipientSocketReceive(on: pair.sockets[origin]) == requestless)
                try await pair.barrier()
            }
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func unknownWrongTargetSelectedAwayAndDisconnectedReferencesReachNobody() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, connected) = try rig.listener()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [LegacyReferenceRig.target, LegacyReferenceRig.target]
        )
        defer { pair.close() }
        do {
            try await exerciseRefusals(listener: listener, connected: connected, pair: pair)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseRefusals(
        listener: WebSocketListener, connected: ConnectedPeerIDs, pair: FallbackSocketPair
    ) async throws {
        let first = try await listener.sessionConnection(of: connected.all[0])
        let second = try await listener.sessionConnection(of: connected.all[1])
        let owner = try #require(try await ambientDispatch(listener, LegacyReferenceRig.request(connection: first)))
        // Unknown, and the right reference on the wrong target: refused, never redirected or broadcast.
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(UUID())))
        }
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(owner, target: LegacyReferenceRig.other)))
        }
        // The originating device selects away: its reference dies with that selection.
        try await pair.select(LegacyReferenceRig.other, on: 0)
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(owner)))
        }
        // The other device's reference stops working once it disconnects; nobody else hears it.
        let gone = try #require(try await ambientDispatch(listener, LegacyReferenceRig.request(connection: second)))
        pair.sockets[1].cancel(with: .normalClosure, reason: nil)
        #expect(await eventually { await listener.peers.count == 1 })
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(gone)))
        }
        try await recipientSocketBarrier(on: pair.sockets[0])
    }

    @Test func aRebindBetweenDispatchAndReplyRefusesThePublication() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, connected) = try rig.listener(fallback: false)
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [LegacyReferenceRig.target])
        defer { pair.close() }
        do {
            let connection = try await listener.sessionConnection(of: connected.all[0])
            let owner = try #require(
                try await ambientDispatch(listener, LegacyReferenceRig.request(connection: connection))
            )
            await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "rebound")])
            await #expect(throws: LocalReplyRefusal.publicationFailed) {
                try await listener.publish(recipientText(referenceDescriptor(owner)))
            }
            // The record is gone, so a retry is refused before any enqueue.
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.publish(recipientText(referenceDescriptor(owner)))
            }
            try await pair.barrier()
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
