public import Foundation
import Network
import HailProtocol

public enum WebSocketListenerError: Error, Sendable, Equatable {
    case invalidArguments
    case invalidBindAddress(String)
    case invalidReply
    case stoppedBeforeReady
    case failed(String)
}

/// Structured lifecycle data only. Frame payloads and transcript text never enter listener logs.
public struct WebSocketListenerEvent: Codable, Sendable, Equatable {
    public var event: String
    public var sessionID: UUID?
    public var endpoint: String?
    public var detail: String?

    public init(event: String, sessionID: UUID? = nil, endpoint: String? = nil, detail: String? = nil) {
        self.event = event
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.detail = detail
    }
}

/// A bounded, exact-address WebSocket boundary around independent peer actors. Protocol negotiation and
/// authorization remain testable without a socket in `HostSession`.
public actor WebSocketListener {
    public static let subprotocolName = "hail.v1"

    private let bindAddress: String
    private let queue: DispatchQueue
    private let networkListener: NWListener
    private let host: HailHost
    private let authorizer: any HostSessionAuthorizing
    let hostName: String
    private let maxConnections: Int
    private let helloTimeout: Duration
    private let log: @Sendable (WebSocketListenerEvent) -> Void
    var peers: [UUID: WebSocketPeer] = [:]
    private var readyWaiters: [CheckedContinuation<UInt16, any Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var readyResult: Result<UInt16, WebSocketListenerError>?
    private var started = false
    var stopped = false

    public init(
        bindAddress: String, port: UInt16, host: HailHost,
        authorizer: any HostSessionAuthorizing = ConnectionProbeAuthorizer(),
        hostName: String = "haild",
        maxConnections: Int = 64,
        helloTimeout: Duration = .seconds(10),
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }
    ) throws {
        let address = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxConnections > 0, helloTimeout > .zero else {
            throw WebSocketListenerError.invalidArguments
        }
        guard let parsedAddress = parseBindAddress(address) else {
            throw WebSocketListenerError.invalidBindAddress(bindAddress)
        }
        let queue = DispatchQueue(label: "hail.websocket-listener")
        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = PayloadLimits.defaultMaxFrameBytes
        webSocket.setClientRequestHandler(queue) { subprotocols, _ in
            guard subprotocols.contains(Self.subprotocolName) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: Self.subprotocolName)
        }
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: parsedAddress.host, port: endpointPort)
        parameters.allowLocalEndpointReuse = true

        self.bindAddress = parsedAddress.canonical
        self.queue = queue
        self.networkListener = try NWListener(using: parameters)
        self.host = host
        self.authorizer = authorizer
        self.hostName = hostName
        self.maxConnections = maxConnections
        self.helloTimeout = helloTimeout
        self.log = log
    }

    /// Resolves only after Network.framework reports `.ready`, returning the actual port (including when
    /// tests request port zero). A failed bind never looks like a running daemon.
    public func start() async throws -> UInt16 {
        if let readyResult { return try readyResult.get() }
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
            guard !started else { return }
            started = true
            networkListener.stateUpdateHandler = { [weak self] state in
                Task { await self?.listenerChanged(state) }
            }
            networkListener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            networkListener.start(queue: queue)
        }
    }

    public func waitUntilStopped() async {
        if stopped { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    public func stop(reason: String = "requested") async {
        guard !stopped else { return }
        stopped = true
        networkListener.cancel()
        let active = Array(peers.values)
        peers.removeAll()
        for peer in active { await peer.stop(reason: reason) }
        if readyResult == nil { finishReady(.failure(.stoppedBeforeReady)) }
        emit(WebSocketListenerEvent(event: "listener_stopped", detail: reason))
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func listenerChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            guard let port = networkListener.port?.rawValue else {
                finishReady(.failure(.failed("listener ready without a port")))
                return
            }
            emit(WebSocketListenerEvent(event: "listener_ready", endpoint: "\(bindAddress):\(port)"))
            finishReady(.success(port))
        case .waiting(let error):
            emit(WebSocketListenerEvent(event: "listener_waiting", detail: "\(error)"))
        case .failed(let error):
            emit(WebSocketListenerEvent(event: "listener_failed", detail: "\(error)"))
            finishReady(.failure(.failed("\(error)")))
            await stop(reason: "listener failed")
        case .cancelled:
            if !stopped { await stop(reason: "listener cancelled") }
        case .setup:
            break
        @unknown default:
            emit(WebSocketListenerEvent(event: "listener_unknown_state"))
        }
    }

    private func finishReady(_ result: Result<UInt16, WebSocketListenerError>) {
        guard readyResult == nil else { return }
        readyResult = result
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success(let port): waiter.resume(returning: port)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        guard peers.count < maxConnections else {
            connection.cancel()
            emit(WebSocketListenerEvent(
                event: "session_rejected", sessionID: id, endpoint: "\(connection.endpoint)",
                detail: "connection limit reached"
            ))
            return
        }
        let session = HostSession(host: host, authorizer: authorizer, hostName: hostName)
        let peer = WebSocketPeer(
            id: id, connection: connection, session: session, queue: queue,
            helloTimeout: helloTimeout, log: log
        ) { [weak self] endedID in
            Task { await self?.peerEnded(endedID) }
        }
        peers[id] = peer
        await peer.start()
    }

    private func peerEnded(_ id: UUID) { peers[id] = nil }
    private func emit(_ event: WebSocketListenerEvent) { log(event) }
}
