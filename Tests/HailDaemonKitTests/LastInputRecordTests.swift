#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #370 on never-started transports and the rig's injected clock: lifetime, and what may and may not record input.
@Suite struct LastInputRecordTests {
    private static let tap = sessionFrame(
        target: LegacyReferenceRig.target, payload: .text(TextPayload(text: "synthetic tap"))
    )

    @Test func anExpiredLastInputFallsBackToTheSingleSelectorRule() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, _) = try rig.listener()
        let (first, second) = (await rig.session(), await rig.session())
        let peers = await listener.installFallbackSyntheticPeers([first, second])
        #expect(await first.receive(Self.tap).frames.isEmpty)
        let frame = recipientText(referenceDescriptor(nil))
        let route = try #require(await listener.lastInputRoute(frame))
        #expect(route.entry.connection == (await first.connectionID) && !route.pinned)
        #expect(await peers[0].admitsRequestlessReply(frame, lastInput: route))
        #expect(!(await peers[1].admitsRequestlessReply(frame, lastInput: route)))
        rig.clock.advance(Int64(LastInputLedger.lifetime.components.seconds) * 1_000 - 1)
        #expect(await peers[0].admitsRequestlessReply(frame, lastInput: route))
        rig.clock.advance(1)
        #expect(!(await peers[0].admitsRequestlessReply(frame, lastInput: route)))
        // Expired: both select the target, so the reply is refused as before #370.
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) { try await listener.publish(frame) }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func onlyDeliveredDeviceInputRecords() async throws {
        let rig = try await LegacyReferenceRig.make()
        let (listener, _) = try rig.listener()
        let session = await rig.session()
        await listener.installFallbackSyntheticPeers([session])
        let frame = recipientText(referenceDescriptor(nil))
        // The local socket's `dispatch` kind (`haild rightyo --reply-to`) is not device input.
        _ = try await session.dispatch(LegacyReferenceRig.request(connection: UUID()))
        #expect(await listener.lastInputRoute(frame) == nil)
        // A refused tap (target denied) delivered nothing and records nothing.
        _ = try await rig.host.deny(LegacyReferenceRig.target)
        #expect(await session.receive(Self.tap).frames.count == 1)
        #expect(await listener.lastInputRoute(frame) == nil)
        // Ambient dispatch records only when bound by the listener's own ambient path.
        _ = try await rig.host.allow(LegacyReferenceRig.target, tier: .open)
        _ = try await HostSession.$ambientInputDispatch.withValue(true) {
            try await session.dispatch(LegacyReferenceRig.request(connection: UUID()))
        }
        let recorded = await listener.lastInputRoute(frame)?.entry.connection
        #expect(recorded == (await session.connectionID))
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
