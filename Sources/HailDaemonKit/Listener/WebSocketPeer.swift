import Foundation
import Network
import HailProtocol

func parseBindAddress(_ address: String) -> (host: NWEndpoint.Host, canonical: String)? {
    if let ipv4 = IPv4Address(address), !ipv4.rawValue.allSatisfy({ $0 == 0 }) {
        return (.ipv4(ipv4), "\(ipv4)")
    }
    if let ipv6 = IPv6Address(address) {
        let raw = ipv6.rawValue
        let mappedIPv4 = raw.prefix(10).allSatisfy { $0 == 0 }
            && raw.dropFirst(10).prefix(2).allSatisfy { $0 == 0xff }
        if !raw.allSatisfy({ $0 == 0 }), !mappedIPv4 { return (.ipv6(ipv6), "\(ipv6)") }
    }
    return nil
}

/// One socket and one `HostSession`; receive calls are serialized per peer while different peers progress
/// independently. The parent listener owns bounded admission and shutdown.
actor WebSocketPeer {
    private let id: UUID
    private let connection: NWConnection
    let session: HostSession
    private let queue: DispatchQueue
    private let helloTimeout: Duration
    private let log: @Sendable (WebSocketListenerEvent) -> Void
    private let onEnd: @Sendable (UUID) -> Void
    private var helloTimer: Task<Void, Never>?
    var ended = false

    init(
        id: UUID, connection: NWConnection, session: HostSession, queue: DispatchQueue,
        helloTimeout: Duration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void,
        onEnd: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.session = session
        self.queue = queue
        self.helloTimeout = helloTimeout
        self.log = log
        self.onEnd = onEnd
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.connectionChanged(state) }
        }
        startHelloTimer()
        connection.start(queue: queue)
    }

    func stop(reason: String) { finish(reason: reason) }

    private func connectionChanged(_ state: NWConnection.State) {
        guard !ended else { return }
        switch state {
        case .ready:
            emit("session_connected", endpoint: "\(connection.endpoint)")
            receiveNext()
        case .failed(let error): finish(reason: "failed: \(error)")
        case .cancelled: finish(reason: "cancelled")
        case .waiting(let error): emit("session_waiting", detail: "\(error)")
        case .setup, .preparing: break
        @unknown default: finish(reason: "unknown state")
        }
    }

    private func startHelloTimer() {
        helloTimer = Task { [weak self, helloTimeout] in
            do {
                try await Task.sleep(for: helloTimeout)
            } catch {
                return
            }
            await self?.helloTimedOut()
        }
    }

    private func helloTimedOut() {
        guard helloTimer != nil else { return }
        finish(reason: "hello timeout")
    }

    private func receiveNext() {
        guard !ended else { return }
        connection.receiveMessage { [weak self] data, context, _, error in
            Task { await self?.received(data, context: context, error: error) }
        }
    }

    private func received(
        _ data: Data?, context: NWConnection.ContentContext?, error: NWError?
    ) async {
        guard !ended else { return }
        if let error {
            finish(reason: "receive failed: \(error)")
            return
        }
        guard let metadata = context?.protocolMetadata(
            definition: NWProtocolWebSocket.definition
        ) as? NWProtocolWebSocket.Metadata else {
            await close(reason: "missing WebSocket metadata")
            return
        }
        switch metadata.opcode {
        case .close:
            finish(reason: "peer closed")
        case .ping, .pong:
            receiveNext()
        case .text, .binary:
            guard let data else {
                await close(reason: "WebSocket message had no content")
                return
            }
            await process(data)
        default:
            await close(reason: "unsupported WebSocket message")
        }
    }

    private func process(_ data: Data) async {
        let result = await session.receive(data)
        if result.frames.contains(where: { frame in
            if case .control(.hello) = frame.payload { return true }
            return false
        }) {
            helloTimer?.cancel()
            helloTimer = nil
        }
        for frame in result.frames {
            guard await send(frame) else {
                finish(reason: "send failed")
                return
            }
        }
        guard !ended else { return }
        switch result.disposition {
        case .keepOpen: receiveNext()
        case .close: await close(reason: "protocol closed")
        }
    }

    func send(_ frame: Frame) async -> Bool {
        guard let data = try? FrameCoding.encode(frame) else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hail.frame", metadata: [metadata])
        return await withCheckedContinuation { continuation in
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { continuation.resume(returning: $0 == nil) }
            )
        }
    }

    private func close(reason: String) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.protocolError)
        let context = NWConnection.ContentContext(identifier: "hail.close", isFinal: true, metadata: [metadata])
        await withCheckedContinuation { continuation in
            connection.send(
                content: nil, contentContext: context, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
        finish(reason: reason)
    }

    func finish(reason: String) {
        guard !ended else { return }
        ended = true
        helloTimer?.cancel()
        helloTimer = nil
        connection.cancel()
        emit("session_disconnected", detail: reason)
        onEnd(id)
    }

    private func emit(_ event: String, endpoint: String? = nil, detail: String? = nil) {
        log(WebSocketListenerEvent(event: event, sessionID: id, endpoint: endpoint, detail: detail))
    }
}
