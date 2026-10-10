#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #230 over loopback sockets: a reply with no request reference, with two devices selecting its target and no
/// last input yet (a restart, or ten quiet minutes), goes to the device the user is listening on instead of being
/// refused. Synthetic only; not device hearing.
@Suite(.serialized) struct AmbientOwnerReplyRoutingTests {
    /// Reports `owner` as the connection whose ambient stream feeds the active child.
    final class FakeWiring: AmbientListenerWiring {
        let owner = Mutex<UUID?>(nil)
        func attach(_ listener: WebSocketListener) {}
        func stop(connection: UUID) {}
        func shutdown() async {}
        func isLatest(stream: UUID, connection: UUID) -> Bool { false }
        func activeConnection() -> UUID? { owner.withLock { $0 } }
    }

    /// Two loopback devices selecting the legacy target; device `listening`, if any, owns the active stream.
    private func withTwoDevices(
        listening: Int?, _ body: (WebSocketListener, RoutedReplyEvents, FallbackSocketPair) async throws -> Void
    ) async throws {
        let rig = try await LegacyReferenceRig.make()
        let wiring = FakeWiring()
        let (listener, events) = try rig.routedListener(ambient: wiring)
        let port = try await listener.start()
        let devices = try await FallbackSocketPair.connect(
            port: port, selecting: Array(repeating: LegacyReferenceRig.target, count: 2)
        )
        defer { devices.close() }
        do {
            if let listening {
                let owner = try await listener.sessionConnection(of: events.connected[listening])
                wiring.owner.withLock { $0 = owner }
            }
            try await body(listener, events, devices)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func itGoesToTheDeviceTheUserIsListeningOn() async throws {
        try await withTwoDevices(listening: 1) { listener, events, devices in
            let frame = recipientText(referenceDescriptor(nil))
            #expect(await listener.lastInputRoute(frame) == nil, "no device input yet: a fresh restart")
            #expect(try await listener.publish(frame) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[1]) == frame)
            try await devices.barrier()
            #expect(events.routes.map(\.0) == [events.connected[1]])
            #expect(events.routes.map(\.1) == ["path=ambient_owner"])
        }
    }

    @Test func withNobodyListeningItIsRefusedAsBefore() async throws {
        try await withTwoDevices(listening: nil) { listener, events, _ in
            let frame = recipientText(referenceDescriptor(nil))
            await #expect(throws: LocalReplyRefusal.notUniqueRecipient) { try await listener.publish(frame) }
            #expect(events.routes.isEmpty)
        }
    }
}

#endif
