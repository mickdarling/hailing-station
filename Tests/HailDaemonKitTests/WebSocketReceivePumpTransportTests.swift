import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func transportProtocolErrorRetiresBeforeSingleCloseSubmission() async throws {
        let (host, _) = try await sessionHost()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let submitted = SelectionPreflightSignal<Void>()
        let ended = SelectionPreflightSignal<Void>()
        let callback = Mutex<(@Sendable () -> Void)?>(nil)
        let submissions = Mutex(0)
        let peerBox = Mutex<WebSocketPeer?>(nil)
        let peer = WebSocketPeer(
            id: UUID(), connection: connection, session: HostSession(host: host),
            queue: DispatchQueue(label: "test.transport-close"), helloTimeout: .seconds(30),
            log: { _ in }, onEnd: { _ in ended.finish(.success(())) }, submitClose: { completion in
                #expect(peerBox.withLock { $0?.replyTransport.isRetired } == true)
                submissions.withLock { $0 += 1 }
                callback.withLock { $0 = completion }
                submitted.finish(.success(()))
            }
        )
        peerBox.withLock { $0 = peer }
        let transport = PumpTransport()
        let pump = WebSocketIngressPump(lifecycle: peer.replyTransport, receive: { transport.receive($0) })
        defer { pump.stop(); connection.cancel() }
        pump.start(process: { _ in Issue.record("terminal must not process") }, onEnd: { reason, protocolError in
            #expect(protocolError)
            Task { await peer.close(reason: reason) }
        })
        let metadata = NWProtocolWebSocket.Metadata(opcode: .cont)
        let context = NWConnection.ContentContext(identifier: "test.cont", metadata: [metadata])
        transport.deliver(WebSocketIngressPump.classify(Data(), context: context, error: nil))
        #expect(peer.replyTransport.isRetired)
        try await submitted.wait("transport close submission")
        // A concurrent application disposition cannot submit another close while transport closure is suspended.
        await peer.close(reason: "concurrent protocol closed")
        #expect(submissions.withLock { $0 } == 1)
        let complete = try #require(callback.withLock { $0 })
        complete()
        try await ended.wait("single transport closure complete")
        #expect(await peer.ended)
        peerBox.withLock { $0 = nil }
    }

    @Test(arguments: [UInt8(0x80), UInt8(0x83)])
    func networkWireProtocolErrorClosesWithCode1002(opcode: UInt8) async throws {
        let (host, _) = try await sessionHost()
        let ended = SelectionPreflightSignal<String>()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host) { event in
            if event.event == "session_disconnected" { ended.finish(.success(event.detail ?? "")) }
        }
        let port = try #require(NWEndpoint.Port(rawValue: await listener.start()))
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { client.cancel() }
        let ready = SelectionPreflightSignal<Void>()
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.finish(.success(())) }
            if case .failed(let error) = state { ready.finish(.failure(error)) }
        }
        client.start(queue: DispatchQueue(label: "test.continuation-client"))
        try await ready.wait("continuation wire ready")
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Protocol: \(WebSocketListener.subprotocolName)\r\n\r\n"
        try await pumpWireSend(Data(request.utf8), on: client)
        let response = try await pumpWireReceive(on: client)
        #expect(String(data: response, encoding: .utf8)?.contains("101") == true)
        let peers = await listener.peers
        let peer = try #require(peers.values.first)
        try await pumpWireSend(Data([opcode, 0x80, 1, 2, 3, 4]), on: client)
        let close = try await pumpWireReceive(on: client, minimum: 4)
        #expect(Array(close) == [0x88, 2, 3, 0xea])
        let reason = try await ended.wait("wire protocol disconnect")
        // Network reports a protocol error before exposing these opcodes as application metadata.
        #expect(reason == "receive failed: \(NWError.posix(.EPROTO))")
        #expect(peer.replyTransport.isRetired)
        await listener.stop(reason: "test complete")
    }
}

private func pumpWireSend(_ data: Data, on connection: NWConnection) async throws {
    let sent = SelectionPreflightSignal<Void>()
    connection.send(content: data, completion: .contentProcessed { error in
        if let error { sent.finish(.failure(error)) } else { sent.finish(.success(())) }
    })
    try await sent.wait("raw wire send")
}

private func pumpWireReceive(on connection: NWConnection, minimum: Int = 1) async throws -> Data {
    let received = SelectionPreflightSignal<Data>()
    connection.receive(minimumIncompleteLength: minimum, maximumLength: 4_096) { data, _, _, error in
        if let data { received.finish(.success(data)) } else {
            received.finish(.failure(error ?? NWError.posix(.EPROTO)))
        }
    }
    return try await received.wait("raw wire receive")
}
