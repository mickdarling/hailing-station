public import Foundation
import Network
import HailProtocol

// The listener and its opt-in ambient RightyO wiring (#203) share one peer lifecycle boundary.
// swiftlint:disable file_length

public enum WebSocketListenerError: Error, Sendable, Equatable {
    case invalidArguments
    case invalidBindAddress(String)
    case invalidReply
    case sourceHostMismatch
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
    let authorizer: any HostSessionAuthorizing
    let hostName: String
    /// Opt-in single-terminal bridge (#188): uncorrelated replies may reach the one connection selecting
    /// their target. Off by default; multi-terminal hosts keep owner-only delivery.
    let singleTerminalReplyFallback: Bool
    private let maxConnections: Int
    private let helloTimeout: Duration
    private let log: @Sendable (WebSocketListenerEvent) -> Void
    var peers: [UUID: WebSocketPeer] = [:]
    private var readyWaiters: [CheckedContinuation<UInt16, any Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var readyResult: Result<UInt16, WebSocketListenerError>?
    private var started = false
    var stopped = false
    /// Opt-in ambient listening (#203): the sink of the authorizer's `AmbientAudioGate`. Nil by default.
    let ambient: (any AmbientListenerWiring)?

    public init(
        bindAddress: String, port: UInt16, host: HailHost,
        authorizer: any HostSessionAuthorizing = ConnectionProbeAuthorizer(),
        hostName: String = "haild",
        maxConnections: Int = 64,
        helloTimeout: Duration = .seconds(10),
        singleTerminalReplyFallback: Bool = false,
        ambient: (any AmbientListenerWiring)? = nil,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }
    ) throws {
        let address = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxConnections > 0, helloTimeout > .zero else { throw WebSocketListenerError.invalidArguments }
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
        (self.host, self.authorizer) = (host, authorizer)
        (self.hostName, self.singleTerminalReplyFallback) = (hostName, singleTerminalReplyFallback)
        (self.maxConnections, self.helloTimeout) = (maxConnections, helloTimeout)
        (self.log, self.ambient) = (log, ambient)
        ambient?.attach(self)
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
        await stopAmbient(active)
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

    private func emit(_ event: WebSocketListenerEvent) { log(event) }
}

/// The listener's view of ambient listening (#203): bound once to the listener, told when a connection ends,
/// and drained on shutdown.
public protocol AmbientListenerWiring: AnyObject, Sendable {
    func attach(_ listener: WebSocketListener)
    /// Stops every child serving `connection`; never cancels a run, so an in-flight dispatch finishes typing.
    func stop(connection: UUID)
    /// Stops every child, then waits until each is reaped and each run (with any in-flight dispatch) returns.
    func shutdown() async
}

extension WebSocketListener {
    fileprivate func peerEnded(_ id: UUID) async {
        guard let peer = peers.removeValue(forKey: id) else { return }
        await endAmbient(of: peer)
    }

    /// Ends every stream, then waits for each ambient child to be reaped and each in-flight dispatch to finish
    /// typing (#203).
    fileprivate func stopAmbient(_ peers: [WebSocketPeer]) async {
        for peer in peers { await endAmbient(of: peer) }
        await ambient?.shutdown()
    }

    /// Ends the peer's ambient stream, if it owns one, and stops its children. Never cancels a run (#203).
    fileprivate func endAmbient(of peer: WebSocketPeer) async {
        guard let gate = authorizer.ambientAudio else { return }
        let connection = peer.session.connectionID
        await gate.end(connection: connection)
        ambient?.stop(connection: connection)
    }

    /// An ambient request names the `HostSession` connection the gate saw; it is dispatched on behalf of the
    /// listener peer that owns that session, through the same `dispatch(_:)` as `--reply-to`.
    func dispatchAmbient(_ request: LocalDispatchRequest) async throws -> UUID? {
        guard let peer = peers.first(where: { $0.value.session.connectionID == request.connection }) else {
            throw LocalDispatchRefusal.unknownConnection
        }
        var named = request
        named.connection = peer.key
        return try await dispatch(named)
    }
}

#if os(macOS)
import Synchronization

/// Ambient listening wiring (#203): the sink of the daemon's one `AmbientAudioGate`. A started stream spawns
/// one `RightyoAmbientPipeline` for its connection; segments are handed to the child without blocking; an ended
/// stream closes the child's input and stops it (EOF, then SIGTERM, then SIGKILL). Admitted requests are
/// dispatched in process on behalf of the streaming peer. A run is never cancelled: teardown stops the child,
/// and an in-flight dispatch finishes typing before its run returns. Audio and transcripts are never logged.
public final class AmbientRightyoRouter: AmbientAudioSink, AmbientListenerWiring {
    public struct Configuration: Sendable {
        public var executable: URL
        public var config: URL
        public var target: String
        /// The target's binding, pinned when the daemon started; a rebind refuses dispatch rather than following.
        public var binding: String
        /// Admit turns that are not `live-microphone`. Tests only; the daemon leaves it false.
        public var allowSynthetic: Bool
        public var timing: RightyoChildProcess.Timing

        public init(executable: URL, config: URL, target: String, binding: String, allowSynthetic: Bool = false,
                    timing: RightyoChildProcess.Timing = .init()) {
            (self.executable, self.config, self.target, self.binding) = (executable, config, target, binding)
            (self.allowSynthetic, self.timing) = (allowSynthetic, timing)
        }
    }

    /// Children alive at once: the active stream plus one still finishing. A start past this spawns nothing.
    public static let maxLiveChildren = 2

    private struct Run {
        let connection: UUID
        let pipeline: RightyoAmbientPipeline
        var task: Task<Void, Never>?
    }
    private struct State {
        var listener: WeakListener?
        var active: (stream: UUID, pipeline: RightyoAmbientPipeline)?
        var runs: [UUID: Run] = [:]
        var shuttingDown = false
    }
    private struct WeakListener { weak var value: WebSocketListener? }

    public let configuration: Configuration
    private let state = Mutex(State())
    private let log: @Sendable (WebSocketListenerEvent) -> Void

    public init(configuration: Configuration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }) {
        (self.configuration, self.log) = (configuration, log)
    }

    public func attach(_ listener: WebSocketListener) {
        state.withLock { $0.listener = WeakListener(value: listener) }
    }

    /// Called in order from the gate's actor; only spawns, enqueues or signals, never awaits.
    public func ambientAudio(_ event: AmbientAudioEvent) {
        switch event {
        case .started(let stream, let connection): start(stream, connection: connection)
        case .segment(let stream, _, let bytes):
            let pipeline = state.withLock { $0.active?.stream == stream ? $0.active?.pipeline : nil }
            // Overload and a child that already ended both drop audio; neither blocks the gate.
            pipeline?.send(audio: bytes)
        case .ended(let stream, _):
            let pipeline = state.withLock { state -> RightyoAmbientPipeline? in
                guard let active = state.active, active.stream == stream else { return nil }
                state.active = nil
                return active.pipeline
            }
            if let pipeline { Self.retire(pipeline) }
        }
    }

    public func stop(connection: UUID) {
        let pipelines = state.withLock { state -> [RightyoAmbientPipeline] in
            if let active = state.active, state.runs[active.stream]?.connection == connection { state.active = nil }
            return state.runs.values.filter { $0.connection == connection }.map(\.pipeline)
        }
        pipelines.forEach(Self.retire)
    }

    public func shutdown() async {
        let (pipelines, tasks) = state.withLock { state in
            state.shuttingDown = true
            state.active = nil
            return (state.runs.values.map(\.pipeline), state.runs.values.compactMap(\.task))
        }
        await withTaskGroup(of: Void.self) { group in
            for pipeline in pipelines { group.addTask { await pipeline.stop() } }
        }
        for task in tasks { await task.value }
    }

    /// Children not yet reaped and runs not yet returned (tests).
    var liveRuns: Int { state.withLock { $0.runs.count } }

    /// Waits for every current run to return (tests).
    func settle() async {
        for task in state.withLock({ $0.runs.values.compactMap(\.task) }) { await task.value }
    }

    private static func retire(_ pipeline: RightyoAmbientPipeline) {
        pipeline.finishInput()
        Task { await pipeline.stop() }
    }

    private func start(_ stream: UUID, connection: UUID) {
        let listener = state.withLock { state in
            state.shuttingDown || state.runs.count >= Self.maxLiveChildren ? nil : state.listener?.value
        }
        guard let listener else { return emit("ambient_refused", detail: "busy") }
        let pipeline: RightyoAmbientPipeline
        do {
            pipeline = try RightyoAmbientPipeline(configuration: .init(
                executable: configuration.executable, config: configuration.config, target: configuration.target,
                binding: configuration.binding, connection: connection,
                allowSynthetic: configuration.allowSynthetic, timing: configuration.timing
            ), dispatcher: AmbientListenerDispatcher(listener: listener))
        } catch {
            return emit("ambient_refused", detail: Self.describe(error))
        }
        let admitted = state.withLock { state -> Bool in
            guard !state.shuttingDown else { return false }
            state.active = (stream, pipeline)
            state.runs[stream] = Run(connection: connection, pipeline: pipeline)
            // Created under the lock, so the run's own removal cannot precede its registration.
            state.runs[stream]?.task = Task { [weak self] in
                let detail: String
                do {
                    let summary = try await pipeline.run()
                    detail = "delivered=\(summary.delivered) written=\(summary.child.writtenBytes)"
                        + " dropped=\(summary.child.droppedBytes) exit=\(summary.exit)"
                } catch { detail = Self.describe(error) }
                self?.finished(stream, detail: detail)
            }
            return true
        }
        guard admitted else { return Self.retire(pipeline) }
        emit("ambient_started", detail: nil)
    }

    private func finished(_ stream: UUID, detail: String) {
        state.withLock { state in
            state.runs[stream] = nil
            if state.active?.stream == stream { state.active = nil }
        }
        emit("ambient_ended", detail: detail)
    }

    /// Rule names only: every error reaching here is a content-free case.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as RightyoChildError: "child \(error)"
        case let error as RightyoInputError: "input \(error)"
        case let error as LocalDispatchRefusal: "dispatch \(error.rawValue)"
        default: "failed"
        }
    }

    private func emit(_ event: String, detail: String?) {
        log(WebSocketListenerEvent(event: event, detail: detail))
    }
}

/// The pipeline's delivery step: the listener's own in-process dispatch for the streaming peer.
struct AmbientListenerDispatcher: RightyoAmbientDispatching {
    let listener: WebSocketListener
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        try await listener.dispatchAmbient(request)
    }
}
#endif
