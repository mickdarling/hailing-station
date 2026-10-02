import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic rig support for #188 local dispatch: loopback sockets or never-started transports only.
/// The connection id under test is the listener's own peer UUID as logged on `session_connected`.
final class ConnectedPeerIDs: Sendable {
    private let ids = Mutex<[UUID]>([])
    var all: [UUID] { ids.withLock { $0 } }
    func record(_ event: WebSocketListenerEvent) {
        guard event.event == "session_connected", let id = event.sessionID else { return }
        ids.withLock { $0.append(id) }
    }
}

func dispatchListener(rig: RecipientTestRig) throws -> (WebSocketListener, ConnectedPeerIDs) {
    let connected = ConnectedPeerIDs()
    let listener = try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: rig.host, authorizer: PersonalTerminalAuthorizer(),
        hostName: "mac-test", log: { connected.record($0) }
    )
    return (listener, connected)
}

func dispatchRequest(
    connection: UUID, target: String = RecipientTestRig.target, binding: String = "reply-binding",
    text: String = "synthetic input"
) -> LocalDispatchRequest {
    LocalDispatchRequest(connection: connection, target: target, binding: binding, text: text)
}

extension HostSession {
    /// Test-only: a selection no authorizer granted, to prove the dispatch authorizer gate is not transitive.
    func forceSelection(_ target: String) { selectedTarget = target }
}

extension WebSocketListener {
    func connectionID(of peer: WebSocketPeer) -> UUID? {
        peers.first { $0.value === peer }?.key
    }
}

extension LocalReplyEndpoint {
    /// Spends the whole per-minute admission budget so the next request of either kind is rate limited.
    func exhaustAdmissionBudget() {
        let now = clock.now
        for _ in 0..<Self.maxFramesPerMinute { limiter.record("local-reply", at: now) }
    }
}
