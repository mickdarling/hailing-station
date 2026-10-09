#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Listener lifecycle and `reply_routed` events (#370), so a test can name which path delivered a reply.
final class RoutedReplyEvents: Sendable {
    private let events = Mutex<[WebSocketListenerEvent]>([])
    func record(_ event: WebSocketListenerEvent) { events.withLock { $0.append(event) } }
    var connected: [UUID] {
        events.withLock { $0.filter { $0.event == "session_connected" }.compactMap(\.sessionID) }
    }
    /// `(listener connection id, path)` for every routed reply, oldest first.
    var routes: [(UUID?, String?)] {
        events.withLock { $0.filter { $0.event == "reply_routed" }.map { ($0.sessionID, $0.detail) } }
    }
}

extension LegacyReferenceRig {
    func routedListener() throws -> (WebSocketListener, RoutedReplyEvents) {
        let events = RoutedReplyEvents()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", singleTerminalReplyFallback: true, log: { events.record($0) }
        )
        return (listener, events)
    }
}

extension FallbackSocketPair {
    /// Tap-to-talk: one final text frame to the legacy target, delivered as typed.
    func tap(on index: Int, rig: LegacyReferenceRig, text: String = "synthetic tap") async throws {
        let before = await rig.adapter.deliveries.count
        try await recipientSocketSend(sessionFrame(
            target: LegacyReferenceRig.target, payload: .text(TextPayload(text: text))
        ), on: sockets[index])
        try await recipientSocketBarrier(on: sockets[index])
        try #require(await rig.adapter.deliveries.count == before + 1)
    }
}
#endif
