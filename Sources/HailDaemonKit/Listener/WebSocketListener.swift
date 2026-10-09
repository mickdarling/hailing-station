public import Foundation
import Network
public import HailProtocol

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
    let log: @Sendable (WebSocketListenerEvent) -> Void
    var peers: [UUID: WebSocketPeer] = [:]
    private var readyWaiters: [CheckedContinuation<UInt16, any Error>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var readyResult: Result<UInt16, WebSocketListenerError>?
    private var started = false
    /// `stoppedReplyIDs`: replies stopped on any connection (#309), newest last and bounded. Recorded when the
    /// stop is made, so a stop outlives the device that asked for it. `stopsInFlight` holds each stopping session
    /// until then, so its stop is seen even if its peer ends during the await.
    var stopped = false, stoppedReplyIDs: [UUID] = [], stopsInFlight: [UUID: HostSession] = [:]
    /// Opt-in ambient listening (#203): the sink of the authorizer's `AmbientAudioGate`. Nil by default.
    let ambient: (any AmbientListenerWiring)?
    /// Per target, the connection that most recently sent it admitted input (#370). Host-side only.
    let lastInput = LastInputLedger()

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
        // Attached before the admission checks, so no suspension separates them from the insertion below (#370).
        let session = HostSession(host: host, authorizer: authorizer, hostName: hostName)
        await session.attachLastInput(lastInput)
        guard !stopped else { return connection.cancel() }
        let id = UUID()
        guard peers.count < maxConnections else {
            connection.cancel()
            emit(WebSocketListenerEvent(
                event: "session_rejected", sessionID: id, endpoint: "\(connection.endpoint)",
                detail: "connection limit reached"
            ))
            return
        }
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
    /// Stops every child, then waits (bounded) until each is reaped and each run returns.
    func shutdown() async
    /// True while `stream` is the most recent stream `connection` started, active or ended, and the connection
    /// has not ended since; false once it is superseded.
    func isLatest(stream: UUID, connection: UUID) -> Bool
    /// Subscribes to admitted device diagnostics, when the wiring uses them (rightyo#124); the default ignores them.
    func observe(_ diagnostics: DiagnosticLog) async
    /// Told of every reply frame this host delivered, so ambient requests repeating one can be dropped (#269).
    func observeReply(_ frame: Frame)
}

extension AmbientListenerWiring {
    public func observe(_ diagnostics: DiagnosticLog) async {}
}

extension AmbientListenerWiring {
    public func observeReply(_ frame: Frame) {}
}

extension WebSocketListener {
    fileprivate func peerEnded(_ id: UUID) async {
        guard let peer = peers.removeValue(forKey: id) else { return }
        lastInput.forget(connection: peer.session.connectionID)
        await endAmbient(of: peer)
    }

    /// Ends every stream, then waits (bounded) for each ambient child to be reaped and each in-flight dispatch
    /// to finish typing (#203).
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
    ///
    /// `reference` (#230) is the one `referenceAmbient` minted and wrote into this request's reply block; the
    /// session binds it, host-side, to this connection, its selection generation and the exact target binding
    /// (`HostSession.ambientReplyReference`). Nil dispatches exactly as before.
    func dispatchAmbient(_ request: LocalDispatchRequest, reference: UUID? = nil) async throws -> UUID? {
        guard let peer = peers.first(where: { $0.value.session.connectionID == request.connection }) else {
            throw LocalDispatchRefusal.unknownConnection
        }
        var named = request
        named.connection = peer.key
        // The streaming device's own input (#370): a delivered handoff makes it the target's last input device.
        return try await HostSession.$ambientInputDispatch.withValue(true) {
            guard let reference else { return try await dispatch(named) }
            return try await HostSession.$ambientReplyReference.withValue(reference) { try await dispatch(named) }
        }
    }

    /// #230: for a plain legacy target only (an adapter without contextual delivery, such as `tmux:`), mints a fresh
    /// opaque reply reference and writes it into the prompt's own trailing reply block, so the session can answer
    /// with `haild reply <target> --request <ref>`. A contextual adapter keeps its out-of-band context id and the
    /// original block: the UUID must never enter a bridge's model prompt. A prompt that does not end in the
    /// target's block, or would outgrow the dispatch cap, is left unchanged with no reference.
    func referenceAmbient(_ request: LocalDispatchRequest) async -> (LocalDispatchRequest, UUID?) {
        guard let (adapter, _) = try? await host.registry.resolve(request.target),
              !(adapter is any ProviderContextDelivering) else { return (request, nil) }
        let reference = UUID()
        guard let text = RightyoInputEvent.referencing(request.text, target: request.target, request: reference) else {
            return (request, nil)
        }
        var referenced = request
        referenced.text = text
        return (referenced, reference)
    }

    /// Ambient failed for `stream` (#203): end it at the gate if it is still the active one, so audio stops
    /// being admitted and another device may start, and tell the peer with an `ambient`-prefixed error that
    /// keeps the connection open (the phone stops streaming and releases the microphone on it).
    func ambientFailed(stream: UUID, connection: UUID, message: String) async {
        // The phone applies an `ambient` error to whatever stream it is sending now, so a failure is reported
        // only while no newer stream has started on the connection: an active stream, or one that ended
        // normally and is still dispatching after EOF. A superseded stream's failure is logged by the router.
        let latest: @Sendable (UUID, UUID) -> Bool = { [ambient] stream, connection in
            ambient?.isLatest(stream: stream, connection: connection) ?? false
        }
        guard !stopped, let gate = authorizer.ambientAudio,
              await gate.endForFailure(stream: stream, connection: connection, latest: latest),
              let peer = peers.values.first(where: { $0.session.connectionID == connection }),
              let frame = await peer.session.ambientFailureFrame(message) else { return }
        _ = await peer.send(frame)
    }
}

extension WebSocketListener {
    /// Stops reply playback for the dismissing connection (#309) and returns a fixed outcome token:
    /// `stopped` (sent to the device), `cut` (frames refused only: an older device, or the send failed),
    /// `idle` (nothing mid-stream and no device stop), or `no_connection`.
    func stopReplyPlayback(connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        let stop = UUID()
        stopsInFlight[stop] = peer.session
        let (frame, cut) = await peer.session.stopReplyPlayback()
        stoppedReplyIDs.append(contentsOf: cut)
        stopsInFlight[stop] = nil
        stoppedReplyIDs.removeFirst(max(0, stoppedReplyIDs.count - HostSession.playbackStopLimit))
        if let frame, await peer.send(frame) { return "stopped" }
        return cut.isEmpty ? "idle" : "cut"
    }
}

extension AmbientAudioGate {
    /// Ends `stream` only if it is still the active one and `connection` owns it, and says whether its failure
    /// is reportable: it was active, or `latest` says no newer stream has started on `connection`. One actor
    /// hop, and starts are announced from this actor, so a newer stream can neither be ended by a stale failure
    /// nor start between the two checks.
    func endForFailure(stream: UUID, connection: UUID, latest: @Sendable (UUID, UUID) -> Bool) -> Bool {
        guard activeStream == stream else { return latest(stream, connection) }
        end(connection: connection)
        return true
    }
}

extension HostSession {
    /// A non-closing error on this negotiated session; nil before negotiation or after close.
    func ambientFailureFrame(_ message: String) -> Frame? {
        guard case .ready(let version) = state else { return nil }
        return response(.error(code: .notAllowed, message: message), version: version)
    }
}

#if os(macOS)
import Synchronization

/// Ambient listening wiring (#203): the sink of the daemon's one `AmbientAudioGate`. A started stream spawns
/// one `RightyoAmbientPipeline` for its connection; segments are handed to the child without blocking; an ended
/// stream closes the child's input and stops it (EOF, then SIGTERM, then SIGKILL). Admitted requests are
/// dispatched in process on behalf of the streaming peer. A run is never cancelled: teardown stops the child,
/// and an in-flight dispatch finishes typing before its run returns. Any failure (a refused start, a run that
/// throws, a child that ends while its stream is open) ends the stream at the gate and sends the peer an
/// `ambient`-prefixed error. Audio and transcripts are never logged.
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
        /// How long daemon shutdown waits for runs still dispatching. Past it the daemon exits anyway: a tmux
        /// prompt still being typed may be left partly typed and unsubmitted in the pane (as #204's taint rule
        /// describes for an abandoned send); nothing is retried.
        public var shutdownGrace: TimeInterval
        /// Each ambient dispatch is recorded as `pushed(tool: "ambient-dispatch")` (target and byte count, never
        /// text), as the `--reply-to` socket records `local-dispatch`; a failed record refuses the dispatch.
        public var audit: AuditLog?
        /// Acknowledgement clips (rightyo#105): each admitted request plays one on its phone first. Nil is off.
        public var acknowledgements: AmbientAckLibrary?
        /// Reply control (rightyo#124): each child gets `--control-fd`, and `replyPlayback` feeds it. Off by default.
        public var replyControl = false

        public init(executable: URL, config: URL, target: String, binding: String, allowSynthetic: Bool = false,
                    timing: RightyoChildProcess.Timing = .init(),
                    shutdownGrace: TimeInterval = AmbientRightyoRouter.defaultShutdownGrace, audit: AuditLog? = nil,
                    acknowledgements: AmbientAckLibrary? = nil, replyControl: Bool = false) {
            (self.audit, self.acknowledgements, self.replyControl) = (audit, acknowledgements, replyControl)
            (self.executable, self.config, self.target, self.binding) = (executable, config, target, binding)
            (self.allowSynthetic, self.timing, self.shutdownGrace) = (allowSynthetic, timing, shutdownGrace)
        }
    }

    public static let defaultShutdownGrace: TimeInterval = 20
    /// Unreaped children at once: the active stream plus one still finishing.
    public static let maxLiveChildren = 2
    /// Replies this host delivered recently; an ambient request repeating one is the assistant's echo (#269).
    let spokenReplies = RecentSpokenReplies()

    public func observeReply(_ frame: Frame) { spokenReplies.observe(frame) }
    /// Runs at once, including those whose child is reaped but whose dispatch is still typing. A run stuck in a
    /// dispatch therefore blocks new starts only once this many are stuck.
    public static let maxRuns = 4

    fileprivate struct Run {
        let connection: UUID
        let pipeline: RightyoAmbientPipeline
        var reaped = false
        /// Why the gate ended the stream (idle, final, malformed, …), reported in `ambient_ended` (#282).
        var gateEnd: AmbientStreamEndReason?
        var task: Task<Void, Never>?
    }
    fileprivate struct State {
        var listener: WeakListener?
        var active: (stream: UUID, pipeline: RightyoAmbientPipeline)?
        var runs: [UUID: Run] = [:]
        var shuttingDown = false
        var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Each live connection's most recent started stream (one entry per connection, dropped when it ends),
        /// so a normally ended stream's late failure is still reported until the connection starts another.
        var latest: [UUID: UUID] = [:]
    }
    fileprivate struct WeakListener { weak var value: WebSocketListener? }

    public let configuration: Configuration
    fileprivate let state = Mutex(State())
    fileprivate let log: @Sendable (WebSocketListenerEvent) -> Void

    public init(configuration: Configuration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }) {
        (self.configuration, self.log) = (configuration, log)
    }

    public func attach(_ listener: WebSocketListener) {
        state.withLock { $0.listener = WeakListener(value: listener) }
    }

    /// Called in order from the gate's actor; only spawns, enqueues or signals, never awaits.
    public func ambientAudio(_ event: AmbientAudioEvent) {
        switch event {
        case .started(let stream, let connection):
            state.withLock { $0.latest[connection] = stream }
            start(stream, connection: connection)
        case .segment(let stream, _, let bytes):
            let pipeline = state.withLock { $0.active?.stream == stream ? $0.active?.pipeline : nil }
            // Overload drops the oldest audio; it never blocks the gate. Refused input means the child is gone
            // (its run may still be finishing a dispatch), so the stream ends instead of absorbing audio.
            if let pipeline, !pipeline.send(audio: bytes) { inputClosed(stream) }
        case .ended(let stream, let reason):
            let pipeline = state.withLock { state -> RightyoAmbientPipeline? in
                state.runs[stream]?.gateEnd = reason
                guard let active = state.active, active.stream == stream else { return nil }
                state.active = nil
                return active.pipeline
            }
            if pipeline != nil { retire(stream) }
        }
    }

    /// With reply control on, every admitted diagnostic batch passes through `replyPlayback` (rightyo#124).
    public func observe(_ diagnostics: DiagnosticLog) async {
        guard configuration.replyControl else { return }
        await diagnostics.observe { [weak self] events, connection in
            self?.replyPlayback(events, connection: connection)
        }
    }

    /// The phone's own playback reports for `connection` (rightyo#124), from its admitted diagnostics: the last
    /// `reply_playback_start` or `_end` among them goes to that connection's active stream, if reply control is on.
    /// Never awaits; a full or closed control pipe drops the report.
    public func replyPlayback(_ events: [DiagnosticEvent], connection: UUID) {
        guard configuration.replyControl,
              let phase = events.reversed().lazy.compactMap({ event -> RightyoReplyPhase? in
                  switch event.name {
                  case .replyPlaybackStart: .started
                  case .replyPlaybackEnd, .replyPlaybackError: .ended
                  default: nil
                  }
              }).first else { return }
        let pipeline = state.withLock { state -> RightyoAmbientPipeline? in
            guard let stream = state.latest[connection], let active = state.active, active.stream == stream else {
                return nil
            }
            return active.pipeline
        }
        guard let pipeline else { return }
        emit("ambient_reply", detail: "phase=\(phase.rawValue) reported=\(pipeline.reportReply(phase))")
    }

    public func stop(connection: UUID) {
        let streams = state.withLock { state -> [UUID] in
            state.latest[connection] = nil
            if let active = state.active, state.runs[active.stream]?.connection == connection { state.active = nil }
            return state.runs.filter { $0.value.connection == connection }.map(\.key)
        }
        streams.forEach(retire)
    }

    public func shutdown() async {
        let pipelines = state.withLock { state in
            state.shuttingDown = true
            state.active = nil
            state.latest = [:]
            return state.runs.values.map(\.pipeline)
        }
        await withTaskGroup(of: Void.self) { group in
            for pipeline in pipelines { group.addTask { await pipeline.stop() } }
        }
        if await !drain(within: configuration.shutdownGrace) {
            emit("ambient_shutdown_timeout", detail: "runs=\(liveRuns)")
        }
    }

    public func isLatest(stream: UUID, connection: UUID) -> Bool {
        state.withLock { $0.latest[connection] == stream }
    }

    /// Runs not yet returned (tests).
    var liveRuns: Int { state.withLock { $0.runs.count } }

    /// Waits for every current run to return (tests).
    func settle() async {
        for task in state.withLock({ $0.runs.values.compactMap(\.task) }) { await task.value }
    }
}

extension AmbientRightyoRouter {
    /// Closes the child's input and stops it; once it is reaped it no longer counts against `maxLiveChildren`.
    fileprivate func retire(_ stream: UUID) {
        guard let pipeline = state.withLock({ $0.runs[stream]?.pipeline }) else { return }
        pipeline.finishInput()
        Task {
            await pipeline.stop()
            self.state.withLock { $0.runs[stream]?.reaped = true }
        }
    }

    /// The active child refused audio: end its stream at the gate and tell the peer, once.
    fileprivate func inputClosed(_ stream: UUID) {
        let (connection, listener) = state.withLock { state -> (UUID?, WebSocketListener?) in
            guard state.active?.stream == stream else { return (nil, nil) }
            state.active = nil
            return (state.runs[stream]?.connection, state.listener?.value)
        }
        guard let connection else { return }
        retire(stream)
        emit("ambient_input_closed", detail: nil)
        Task { await listener?.ambientFailed(stream: stream, connection: connection,
                                             message: "ambient stopped: listener input closed") }
    }

    /// True once no run remains; false when `grace` passes first.
    fileprivate func drain(within grace: TimeInterval) async -> Bool {
        let id = UUID()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let empty = state.withLock { state -> Bool in
                if state.runs.isEmpty { return true }
                state.drainWaiters[id] = waiter
                return false
            }
            if empty { return waiter.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                self.state.withLock { $0.drainWaiters.removeValue(forKey: id) }?.resume()
            }
        }
        return state.withLock { $0.runs.isEmpty }
    }

    fileprivate func start(_ stream: UUID, connection: UUID) {
        let (listener, refusal) = state.withLock { state -> (WebSocketListener?, String?) in
            let live = state.runs.values.filter { !$0.reaped }.count
            if state.shuttingDown { return (nil, "stopping") }
            if live >= Self.maxLiveChildren || state.runs.count >= Self.maxRuns { return (nil, "busy") }
            return (state.listener?.value, state.listener?.value == nil ? "stopping" : nil)
        }
        guard let listener, refusal == nil else {
            return refuse(stream, connection: connection, reason: refusal ?? "stopping")
        }
        let pipeline: RightyoAmbientPipeline
        do {
            var settings = RightyoAmbientPipeline.Configuration(
                executable: configuration.executable, config: configuration.config, target: configuration.target,
                binding: configuration.binding, connection: connection,
                allowSynthetic: configuration.allowSynthetic, timing: configuration.timing,
                isEcho: { [spokenReplies] heard in spokenReplies.isEcho(heard) },
                onDismiss: dismissed(on: connection, listener: listener),
                onAcknowledge: acknowledged(on: connection, listener: listener)
            )
            (settings.replyControl, settings.onAcknowledgementSkipped) = (configuration.replyControl, skipped())
            pipeline = try RightyoAmbientPipeline(configuration: settings,
                                                  dispatcher: AmbientListenerDispatcher(listener: listener,
                                                                                        audit: configuration.audit))
        } catch {
            return refuse(stream, connection: connection, reason: Self.describe(error))
        }
        let admitted = state.withLock { state -> Bool in
            guard !state.shuttingDown else { return false }
            state.active = (stream, pipeline)
            state.runs[stream] = Run(connection: connection, pipeline: pipeline)
            // Created under the lock, so the run's own removal cannot precede its registration. The run's own task
            // emits `ambient_started` first, so it always precedes that run's `ambient_ended`, even when a child
            // exits at once beside another live run (#273).
            state.runs[stream]?.task = Task { [weak self] in
                self?.emit("ambient_started", detail: nil)
                await self?.run(pipeline, stream, connection)
            }
            return true
        }
        guard admitted else {
            Task { await pipeline.stop() }
            return
        }
    }

    /// Plays an acknowledgement clip on the phone that heard an admitted request (rightyo#105), in the addressed
    /// persona's voice or the `default` folder's, then logs tokens and counts only: the persona key comes from the
    /// clip folders, never from transcript text. `rightyo_ms` and `host_ms` are separate clocks, never summed.
    private func acknowledged(
        on connection: UUID, listener: WebSocketListener
    ) -> (@Sendable (AmbientAckRequest) -> Void)? {
        guard let library = configuration.acknowledgements else { return nil }
        let target = configuration.target
        return { [weak self, weak listener] request in
            Task { [weak self] in
                let named = request.persona.flatMap { library.clips[$0] == nil ? nil : $0 }
                guard let persona = named ?? (library.clips["default"] == nil ? nil : "default"),
                      let (index, clip) = library.next(for: persona) else {
                    self?.emit("ambient_acknowledged", detail: "outcome=skipped reason=no_clips")
                    return
                }
                let outcome = await listener?.acknowledgeAmbient(connection: connection, target: target, clip: clip)
                    ?? "no_connection"
                let host = request.readAt.duration(to: .now).components
                let hostMs = host.seconds * 1_000 + host.attoseconds / 1_000_000_000_000_000
                self?.emit("ambient_acknowledged", detail: "persona=\(persona) clip=\(index) "
                           + "rightyo_ms=\(request.rightyoMs) host_ms=\(hostMs) outcome=\(outcome)")
            }
        }
    }

    /// A request RightyO marked not to acknowledge (rightyo#132) plays nothing; its skip is logged with labels and
    /// numbers only, never transcript text.
    private func skipped() -> @Sendable (AmbientAckSkip) -> Void {
        { [weak self] skip in self?.emit("ambient_acknowledged", detail: skip.detail) }
    }

    /// A `dismiss` with `playback` in scope stops reply playback on its connection (#309) before it is logged, so
    /// the diagnostic says what happened; any other dismissal is logged at once. Neither ends the stream.
    private func dismissed(
        on connection: UUID, listener: WebSocketListener
    ) -> @Sendable (RightyoDismissReceipt) -> Void {
        { [weak self, weak listener] receipt in
            guard receipt.stopsPlayback else {
                self?.emit("ambient_dismissed", detail: Self.describe(receipt, playback: "none"))
                return
            }
            Task { [weak self] in
                let playback = await listener?.stopReplyPlayback(connection: connection) ?? "no_connection"
                self?.emit("ambient_dismissed", detail: Self.describe(receipt, playback: playback))
            }
        }
    }

    private func run(_ pipeline: RightyoAmbientPipeline, _ stream: UUID, _ connection: UUID) async {
        var failure: String?
        do {
            let summary = try await pipeline.run()
            let gateEnd = state.withLock { $0.runs[stream]?.gateEnd.map { "\($0)" } } ?? "none"
            emit("ambient_ended", detail: "delivered=\(summary.delivered) written=\(summary.child.writtenBytes)"
                 + " dropped=\(summary.child.droppedBytes) echo=\(await pipeline.echoDropped) ended=\(gateEnd)"
                 + " exit=\(summary.exit)")
        } catch {
            failure = Self.describe(error)
            emit("ambient_ended", detail: failure)
        }
        let (stillActive, listener, waiters) = state.withLock { state in
            state.runs[stream] = nil
            let active = state.active?.stream == stream
            if active { state.active = nil }
            let waiters = state.runs.isEmpty ? Array(state.drainWaiters.values) : []
            if state.runs.isEmpty { state.drainWaiters = [:] }
            return (active, state.shuttingDown ? nil : state.listener?.value, waiters)
        }
        waiters.forEach { $0.resume() }
        // A clean run whose stream already ended is the normal path; anything else ends the stream and tells
        // the phone, even a refusal after the stream ended (for example confirmation required).
        guard failure != nil || stillActive, let listener else { return }
        await listener.ambientFailed(stream: stream, connection: connection,
                                     message: "ambient stopped: \(failure ?? "listener exited")")
    }

    private func refuse(_ stream: UUID, connection: UUID, reason: String) {
        emit("ambient_refused", detail: reason)
        let listener = state.withLock { $0.listener?.value }
        Task { await listener?.ambientFailed(stream: stream, connection: connection,
                                             message: "ambient unavailable: \(reason)") }
    }

    /// Tokens and counts only (rightyo#98). `playback` is the outcome token from `stopReplyPlayback` (#309), or
    /// `none` when the scope did not ask; the stream itself keeps listening.
    fileprivate static func describe(_ receipt: RightyoDismissReceipt, playback: String) -> String {
        "reason=\(receipt.reason) scope=\(receipt.scope.joined(separator: "+")) withdrawn=\(receipt.withdrawn)"
            + " delivered=\(receipt.alreadyDelivered) playback=\(playback)"
    }

    /// Rule names only: every error reaching here is a content-free case.
    fileprivate static func describe(_ error: any Error) -> String {
        switch error {
        case let error as RightyoChildError: "child \(error)"
        case let error as RightyoInputError: "input \(error)"
        case let error as LocalDispatchRefusal: "dispatch \(error.rawValue)"
        case let error as LocalReplyRefusal: "dispatch \(error.rawValue)"
        default: "failed"
        }
    }

    fileprivate func emit(_ event: String, detail: String?) {
        log(WebSocketListenerEvent(event: event, detail: detail))
    }
}

/// The pipeline's delivery step: the listener's own in-process dispatch for the streaming peer.
struct AmbientListenerDispatcher: RightyoAmbientDispatching {
    let listener: WebSocketListener
    let audit: AuditLog?
    /// The reply reference (#230) is written first, so the fail-closed audit record carries the final prompt size.
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        let (prepared, reference) = await listener.referenceAmbient(request)
        if let audit {
            do {
                _ = try await audit.record(.pushed(tool: "ambient-dispatch", target: prepared.target,
                                                   bytes: prepared.text.utf8.count))
            } catch { throw LocalReplyRefusal.auditFailure }
        }
        return try await listener.dispatchAmbient(prepared, reference: reference)
    }
}
#endif
