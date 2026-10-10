#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #230: a reply with no request reference, with several devices selecting its target and no current last input
/// (a restart, or ten quiet minutes), goes to the device the user is listening on, instead of being refused.
@Suite struct AmbientOwnerReplyRoutingTests {
    final class FakeWiring: AmbientListenerWiring {
        let owner = Mutex<UUID?>(nil)
        func attach(_ listener: WebSocketListener) {}
        func stop(connection: UUID) {}
        func shutdown() async {}
        func isLatest(stream: UUID, connection: UUID) -> Bool { false }
        func activeConnection() -> UUID? { owner.withLock { $0 } }
    }

    final class Routes: Sendable {
        let details = Mutex<[String]>([])
    }

    private func setUp(listening: Int?, routes: Routes = Routes()) async throws -> WebSocketListener {
        let rig = try await LegacyReferenceRig.make()
        let wiring = FakeWiring()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", singleTerminalReplyFallback: true, ambient: wiring,
            log: { event in
                if event.event == "reply_routed" { routes.details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let sessions = [await rig.session(), await rig.session()]
        _ = await listener.installFallbackSyntheticPeers(sessions)
        if let listening {
            let owner = await sessions[listening].connectionID
            wiring.owner.withLock { $0 = owner }
        }
        return listener
    }

    @Test func itGoesToTheDeviceTheUserIsListeningOn() async throws {
        let routes = Routes()
        let listener = try await setUp(listening: 1, routes: routes)
        let frame = recipientText(referenceDescriptor(nil))
        #expect(await listener.lastInputRoute(frame) == nil, "no device input yet: a fresh restart")
        #expect(try await listener.publish(frame) == 1)
        #expect(routes.details.withLock { $0 } == ["path=ambient_owner"])
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func withNobodyListeningItIsRefusedAsBefore() async throws {
        let listener = try await setUp(listening: nil)
        let frame = recipientText(referenceDescriptor(nil))
        await #expect(throws: LocalReplyRefusal.notUniqueRecipient) { try await listener.publish(frame) }
        await listener.stop(reason: "synthetic test complete")
    }
}

#endif
