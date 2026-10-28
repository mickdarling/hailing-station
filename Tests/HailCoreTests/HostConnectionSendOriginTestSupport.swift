import Foundation
import HailProtocol
import Testing
@testable import HailCore

actor SendOriginRecorder {
    private(set) var events: [HostReplyEvent] = []
    private(set) var origins: [UUID?] = []
    private(set) var streams: [UUID?] = []
    func append(_ event: HostReplyEvent) {
        events.append(event)
        origins.append(HostNoticeOrigin.generation)
        streams.append(HostNoticeOrigin.streamID)
    }
}

struct SendOriginRig {
    let connection: HostConnection
    let socket: ScriptedSocket
    let recorder: SendOriginRecorder

    static func ready(reportRefusals: Bool = false) async throws -> Self {
        let endpoint = try endpoint()
        let connector = ScriptedConnector()
        let socket = ScriptedSocket()
        let recorder = SendOriginRecorder()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector, deviceName: "Synthetic",
            deadlineSleep: { _ in throw CancellationError() }, wallNow: { 42 },
            reportsAmbientRefusals: reportRefusals, replyObserver: { await recorder.append($0) }
        )
        await connection.connect()
        try await awaitHello(connection, socket, capabilities: ["select_target", "stream_audio", "receive_replies"])
        let selection = Task { try await connection.selectTarget(ambientTarget) }
        try await waitUntil { try await socket.sentFrames().count >= 5 }
        guard case .control(.ping(let nonce)) = try await socket.sentFrames()[4].payload else {
            throw SocketTestError.unavailable
        }
        try await socket.push(.pong(nonce: nonce))
        try await selection.value
        return Self(connection: connection, socket: socket, recorder: recorder)
    }

    func process(_ control: ControlPayload) async throws {
        let frame = Frame(timestamp: 1, source: "Synthetic", payload: .control(control))
        try await connection.process(FrameCoding.encode(frame), generation: 0)
    }
}
