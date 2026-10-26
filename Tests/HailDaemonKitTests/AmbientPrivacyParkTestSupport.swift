#if os(macOS)
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's off settings a test sets (#941): the probe's wait (haild's three seconds unless a test that expects no
/// pong shortens it; a pong ends the wait at once) and a hook before the off decides.
struct PrivacyOffSettings: Sendable {
    static let silent = Self(probeTimeout: .milliseconds(500))
    var probeTimeout: Duration = .seconds(3)
    var offScoping: (@Sendable (UUID) async -> Void)?
}

/// A device whose WebSocket stack never answers a ping (`autoReplyPing` off, and nothing read once it is set up), as
/// a dropped phone's socket haild still holds open. The app's own transport, `URLSessionWebSocketTask`, answers pings
/// itself, as the rig's other devices do. Synthetic only; every wait bounded.
final class SilentPeer: @unchecked Sendable {
    let connection: NWConnection

    init(port: UInt16) throws {
        let options = NWProtocolWebSocket.Options(.version13)
        options.autoReplyPing = false
        options.setSubprotocols([WebSocketListener.subprotocolName])
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
        connection = NWConnection(to: .url(url), using: parameters)
        connection.start(queue: .global())
    }

    func send(_ frame: Frame) async throws {
        let context = NWConnection.ContentContext(identifier: "silent", metadata: [
            NWProtocolWebSocket.Metadata(opcode: .binary)
        ])
        let data = try FrameCoding.encode(frame)
        try await bounded { done in
            self.connection.send(content: data, contentContext: context, isComplete: true,
                                 completion: .contentProcessed { done($0.map { $0 as any Error }) })
        }
    }

    /// The next frame, skipping control messages (it never answers a ping).
    func receive() async throws -> Frame {
        while true {
            let message = Mutex<(Data, Bool)?>(nil)
            try await bounded { done in
                self.connection.receiveMessage { data, context, _, error in
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    let control = metadata.map { $0.opcode != .binary && $0.opcode != .text } ?? true
                    message.withLock { $0 = (data ?? Data(), control) }
                    done(error)
                }
            }
            if let received = message.withLock({ $0 }), !received.1 { return try FrameCoding.decode(received.0) }
        }
    }

    func cancel() { connection.cancel() }

    /// Runs `operation` until it calls back, or cancels the connection after 15 s, so no wait outlives the suite.
    private func bounded(_ operation: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let connection = connection
        let timer = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// The restore rig's pieces for #941's privacy park tests: segments told apart by their bytes, a held child let go,
/// and what each child read. Synthetic only.
extension RestoreRig {
    /// A synthetic segment of `fill` bytes, the first one of a `resume` start when asked.
    static func segment(_ stream: UUID, _ sequence: Int, fill: UInt8, resume: Bool = false) -> Frame {
        var frame = audio(stream, sequence)
        if case .audio(var payload) = frame.payload {
            (payload.isResume, payload.bytes) = (resume, Data(repeating: fill, count: payload.bytes.count))
            frame.payload = .audio(payload)
        }
        return frame
    }

    /// A device with the app's own claims (#941: Hello name "hail terminal", class `kind`) that never answers a ping,
    /// selecting the rig's target, and its connection id.
    func connectSilent(kind: String? = "phone") async throws -> (SilentPeer, UUID) {
        let before = await Self.connections(of: env.listener)
        let peer = try SilentPeer(port: env.port)
        try await peer.send(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: ["probe"], deviceName: Self.appName, deviceKind: kind
        )))))
        _ = try await peer.receive()
        try await peer.send(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let nonce = UUID().uuidString
        try await peer.send(sessionFrame(payload: .control(.ping(nonce: nonce))))
        while try await peer.receive().payload != .control(.pong(nonce: nonce)) {}
        let after = await Self.connections(of: env.listener)
        return (peer, try #require(after.subtracting(before).first))
    }

    /// The Hello name every app sends (`HostConnection.deviceName`'s default; `HostConnectionStore` sets no other).
    static let appName = "hail terminal"

    /// Lets a held child write its `started` (`holdStarted`, `holdSpawn`).
    func release() throws { try Data().write(to: fake.directory.appendingPathComponent("go")) }

    /// What the `spawn`th child read from its stdin, once the rig has finished.
    func heard(_ spawn: Int) -> Data {
        (try? Data(contentsOf: fake.directory.appendingPathComponent("audio.\(spawn).raw"))) ?? Data()
    }
}
#endif
