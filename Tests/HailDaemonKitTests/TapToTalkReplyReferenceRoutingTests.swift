#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230 / #365 over loopback sockets: two devices select the same plain tmux target, as the iPhone and iPad did, and
/// speak by tap-to-talk. A reply naming a tap-to-talk reference reaches only the device that sent the text; the
/// request-less shape keeps refusing. Synthetic only; not device hearing.
@Suite(.serialized) struct TapToTalkReplyReferenceRoutingTests {
    @Test func aTapToTalkReplyReachesOnlyTheDeviceThatSpokeInBothOrders() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, _) = try rig.listener()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [LegacyReferenceRig.target, LegacyReferenceRig.target]
        )
        defer { pair.close() }
        do {
            // Device B (index 1) first, then A, then B again.
            for origin in [1, 0, 1] {
                let reference = try await speak(on: origin, pair: pair, rig: rig)
                let reply = referenceDescriptor(reference, audio: true)
                for frame in [recipientText(reply), recipientAudio(reply, sequence: 0),
                              recipientAudio(reply, sequence: 1, final: true)] {
                    #expect(try await listener.publish(frame) == 1)
                    #expect(try await recipientSocketReceive(on: pair.sockets[origin]) == frame)
                }
                // The other device heard nothing; the request-less shape is still ambiguous and refused.
                try await pair.barrier()
                await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
                    try await listener.publish(recipientText(referenceDescriptor(nil)))
                }
                try await pair.barrier()
            }
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func forgedWrongTargetSelectedAwayAndDisconnectedReferencesReachNobody() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, _) = try rig.listener()
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [LegacyReferenceRig.target, LegacyReferenceRig.target]
        )
        defer { pair.close() }
        do {
            try await exerciseRefusals(listener: listener, pair: pair, rig: rig)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exerciseRefusals(
        listener: WebSocketListener, pair: FallbackSocketPair, rig: LegacyReferenceRig
    ) async throws {
        // Device B types a reference of its own choosing: it is only text, and nobody owns it.
        let forged = UUID()
        let owner = try await speak(on: 1, pair: pair, rig: rig,
                                    text: "reply with --request \(forged.uuidString.lowercased())")
        #expect(owner != forged)
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(forged)))
        }
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(owner, target: LegacyReferenceRig.other)))
        }
        // Device B selects away: its reference dies with that selection.
        try await pair.select(LegacyReferenceRig.other, on: 1)
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(owner)))
        }
        // Device A's reference stops working once A disconnects; B, still connected, hears nothing.
        let gone = try await speak(on: 0, pair: pair, rig: rig)
        pair.sockets[0].cancel(with: .normalClosure, reason: nil)
        #expect(await eventually { await listener.peers.count == 1 })
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientText(referenceDescriptor(gone)))
        }
        try await recipientSocketBarrier(on: pair.sockets[1])
    }

    @Test func aRebindBetweenTheTextAndTheReplyRefusesThePublication() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, _) = try rig.listener(fallback: false)
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [LegacyReferenceRig.target])
        defer { pair.close() }
        do {
            let owner = try await speak(on: 0, pair: pair, rig: rig)
            await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "rebound")])
            await #expect(throws: LocalReplyRefusal.publicationFailed) {
                try await listener.publish(recipientText(referenceDescriptor(owner)))
            }
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

    /// Device `index` sends tap-to-talk text; returns the reference the host typed into the pane for it.
    private func speak(
        on index: Int, pair: FallbackSocketPair, rig: LegacyReferenceRig, text: String = "synthetic input"
    ) async throws -> UUID {
        let before = await rig.adapter.deliveries.count
        try await recipientSocketSend(tapToTalkFrame(text), on: pair.sockets[index])
        try await recipientSocketBarrier(on: pair.sockets[index])
        let deliveries = await rig.adapter.deliveries
        try #require(deliveries.count == before + 1)
        let typed = try #require(deliveries.last?.text)
        let reference = try #require(blockReference(in: typed))
        #expect(typed == text + HostSession.tapToTalkReplyFooter(target: LegacyReferenceRig.target, request: reference))
        return reference
    }
}
#endif
