import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

/// Synthetic rig support for the #188 single-terminal fallback: loopback sockets or never-started
/// transports only. No device, provider process, renderer or microphone is involved.
func fallbackListener(rig: RecipientTestRig, enabled: Bool) throws -> WebSocketListener {
    try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: rig.host, authorizer: PersonalTerminalAuthorizer(),
        hostName: "mac-test", singleTerminalReplyFallback: enabled
    )
}

/// No request reference at all: the shape `haild reply --say` produces without `--request`.
func uncorrelatedDescriptor(audio: Bool = false) -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                    audioStreamID: audio ? UUID() : nil)
}

extension WebSocketListener {
    @discardableResult
    func installFallbackSyntheticPeers(_ sessions: [HostSession]) async -> [WebSocketPeer] {
        readyResult = .success(0)
        // As `accept` does: every session on this listener records into its last-input ledger (#370).
        for session in sessions { await session.attachLastInput(lastInput) }
        return sessions.map { session in
            let id = UUID()
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let peer = WebSocketPeer(id: id, connection: connection, session: session,
                                     queue: DispatchQueue(label: "synthetic.fallback"),
                                     helloTimeout: .seconds(1), log: { _ in }, onEnd: { _ in })
            peers[id] = peer
            return peer
        }
    }
}

struct FallbackSocketPair {
    let sessions: [URLSession]
    let sockets: [URLSessionWebSocketTask]

    /// Two negotiated loopback clients; each selects the given target (nil leaves it unselected).
    static func connect(port: UInt16, selecting targets: [String?]) async throws -> Self {
        var sessions: [URLSession] = []
        var sockets: [URLSessionWebSocketTask] = []
        for target in targets {
            let (session, socket) = try recipientSocket(port: port)
            sessions.append(session)
            sockets.append(socket)
            try await recipientSocketSend(helloFrame(), on: socket)
            _ = try await recipientSocketReceive(on: socket)
            if let target {
                try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: socket)
            }
            try await recipientSocketBarrier(on: socket)
        }
        return Self(sessions: sessions, sockets: sockets)
    }

    func close() {
        for socket in sockets { socket.cancel(with: .normalClosure, reason: nil) }
        for session in sessions { session.invalidateAndCancel() }
    }

    /// Every socket must be idle: a stray reply is a failure, never a timing inference.
    func barrier() async throws {
        for socket in sockets { try await recipientSocketBarrier(on: socket) }
    }

    func select(_ target: String, on index: Int) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: sockets[index])
        try await recipientSocketBarrier(on: sockets[index])
    }

    func submitInput(on index: Int, rig: RecipientTestRig) async throws -> ProviderTurnContext {
        let before = await rig.adapter.contexts.count
        try await recipientSocketSend(sessionFrame(
            target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
        ), on: sockets[index])
        try await recipientSocketBarrier(on: sockets[index])
        let contexts = await rig.adapter.contexts
        try #require(contexts.count == before + 1)
        return try #require(contexts.last)
    }
}
