import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Negotiates a text-only destination and acknowledges each selection on its own socket.
@MainActor
struct TalkDestinationStoreFixture {
    let store: HostConnectionStore
    let connector: ScriptedConnector
    let host: HostEndpoint
    let socket: TalkDestinationSocket

    static func make(wallNow: @escaping HostConnection.WallNow = { 1 }) async throws -> Self {
        let connector = ScriptedConnector()
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() },
                                        wallNow: wallNow)
        let host = try endpoint()
        let socket = try await connect(host, store: store, connector: connector)
        return Self(store: store, connector: connector, host: host, socket: socket)
    }

    static func connect(_ host: HostEndpoint, store: HostConnectionStore,
                        connector: ScriptedConnector) async throws -> TalkDestinationSocket {
        let socket = TalkDestinationSocket()
        await connector.enqueue(.socket(socket), for: host.url)
        try await socket.base.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
            capabilities: ["ping", "select_target", "send_text", PastedText.capability], deviceName: "Fixture")))
        await store.upsert(host)
        await store.connect(host.id)
        await arrivalObserved { store.snapshots[host.id]?.state == .ready }
        return socket
    }

    func select(_ target: String) async throws {
        try await store.selectTarget(host: host.id, targetID: target)
    }

    func binding(_ target: String) throws -> TalkDestinationBinding {
        try #require(store.talkBinding(for: TalkDestinationID(endpointID: host.id, targetID: target)))
    }
}

actor TalkDestinationSocket: WebSocketTransport {
    let base = ScriptedSocket()

    func send(_ data: Data) async throws {
        await base.send(data)
        if case .control(.ping(let nonce)) = try FrameCoding.decode(data).payload {
            try await base.push(.pong(nonce: nonce))
        }
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }

    func transcripts() async throws -> [TextPayload] {
        try await base.sentFrames().compactMap {
            guard case .text(let payload) = $0.payload else { return nil }
            return payload
        }
    }
}
