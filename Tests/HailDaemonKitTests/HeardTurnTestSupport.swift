#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic loopback peers only. Text is a fixed fixture marker, never microphone input.
struct HeardTurnRig {
    static let text = "synthetic heard marker"
    static let line = "synthetic refusal"
    static let capabilities = ["probe", AmbientHeard.capability, RequestRefusals.capability, HeardTurns.capability]
    let listener: WebSocketListener
    let port: UInt16
    let pair: FallbackSocketPair
    let connection: UUID
    let log: AmbientEventDetails
    var socket: URLSessionWebSocketTask { pair.sockets[0] }

    static func make(capabilities: [String] = capabilities) async throws -> Self {
        let rig = try await RecipientTestRig.make()
        let log = AmbientEventDetails()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", log: { log.record($0) }
        )
        let port = try await boundedAmbientListenerStart(listener)
        let pair = try await FallbackSocketPair.boundedConnect(
            port: port, selecting: [RecipientTestRig.target], capabilities: capabilities
        )
        let connection = try #require(await listener.heardTurnConnections().first)
        return Self(listener: listener, port: port, pair: pair, connection: connection, log: log)
    }

    func heard(_ request: UUID, connection: UUID? = nil, socket: URLSessionWebSocketTask? = nil) async throws -> UUID? {
        #expect(await listener.showAmbientHeard(
            connection: connection ?? self.connection, target: RecipientTestRig.target,
            text: Self.text, request: request
        ))
        let frame = try await receiveFrame(on: socket ?? self.socket, step: "heard turn")
        guard case .control(.ambientHeard(let target, let text, let turn)) = frame.payload else {
            Issue.record("expected ambient_heard")
            return nil
        }
        #expect(target == RecipientTestRig.target && text == Self.text)
        if turn == nil { try expectLegacy(frame, .ambientHeard(targetID: target, text: text)) }
        return turn
    }

    func refusal(_ request: UUID?, connection: UUID? = nil, socket: URLSessionWebSocketTask? = nil) async throws
        -> UUID? {
        #expect(await listener.showRouteRefusal(Self.line, target: RecipientTestRig.target,
                                                connection: connection ?? self.connection, request: request) == "sent")
        let frame = try await receiveFrame(on: socket ?? self.socket, step: "refused turn")
        guard case .control(.error(let code, let message, let turn)) = frame.payload else {
            Issue.record("expected refusal")
            return nil
        }
        #expect(code == .voiceRouteRefused && message == Self.line)
        if turn == nil { try expectLegacy(frame, .error(code: code, message: message)) }
        return turn
    }

    /// Preserve the original envelope; compare sorted encoded bytes with the pre-turn control payload.
    func expectLegacy(_ frame: Frame, _ control: ControlPayload) throws {
        var legacy = frame
        legacy.payload = .control(control)
        #expect(try FrameCoding.encode(frame) == FrameCoding.encode(legacy))
        #expect(try !String(decoding: FrameCoding.encode(frame), as: UTF8.self).contains("\"turn\""))
    }
}

extension WebSocketListener {
    func heardTurnConnections() async -> Set<UUID> {
        var connections = Set<UUID>()
        for peer in peers.values { connections.insert(await peer.session.connectionID) }
        return connections
    }
    func heardTurnCount(_ connection: UUID) -> Int { heardTurns[connection]?.count ?? 0 }
}
#endif
