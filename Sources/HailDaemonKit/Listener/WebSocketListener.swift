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
    let host: HailHost
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
    /// `replyHold`: connections whose agent replies are refused while private (#735 S-2c); the ambient router sets it.
    let (lastInput, replyHold) = (LastInputLedger(), PrivateReplyHold())
    /// Sessions' unsolicited updates (#609): off unless `--session-updates`. The quiet switch lasts until restart.
    var sessionUpdates = SessionUpdateQueue(), sessionUpdatesQuiet = false

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

extension AmbientAudioEvent {
    /// The stream every event names.
    var stream: UUID {
        switch self {
        case .started(let stream, _, _), .segment(let stream, _, _), .ended(let stream, _): stream
        }
    }
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
    /// Restarts the active stream's child with the current install (#405); the stream and the phone are untouched.
    func reload() async -> AmbientReloadOutcome
    /// The active stream, if any, and the live children (#405). Never transcript content.
    func status() -> AmbientRouterStatus
    /// The connection whose ambient stream feeds the active child, or nil (#230): the device the user is listening on,
    /// the recipient of last resort for a reply with no request reference. The default has none.
    func activeConnection() -> UUID?
    /// Whether the owner's spoken media mode (#551) is on for `connection`. The default has none.
    func mediaMode(connection: UUID) -> Bool
}

extension AmbientListenerWiring {
    public func observe(_ diagnostics: DiagnosticLog) async {}
}

extension AmbientListenerWiring {
    public func observeReply(_ frame: Frame) {}
}

extension AmbientListenerWiring {
    /// A wiring that cannot reload refuses rather than touching the stream.
    public func reload() async -> AmbientReloadOutcome { .refused("unsupported") }
    public func status() -> AmbientRouterStatus { AmbientRouterStatus() }
    public func activeConnection() -> UUID? { nil }
    public func mediaMode(connection: UUID) -> Bool { false }
}

/// What `haild ambient reload` did (#405). `refused` carries a content-free rule name.
public enum AmbientReloadOutcome: Sendable, Equatable {
    case reloaded, idle, busy, stopping
    case refused(String)
}

/// The router's view of ambient listening (#405): ids, times and counts only.
public struct AmbientRouterStatus: Sendable, Equatable {
    /// The connection whose stream feeds the active child; nil when idle.
    public var connection: UUID?
    public var target: String?
    /// When the active stream started, and when its current child started (later after a reload).
    public var streamSince: Date?
    public var childSince: Date?
    /// The configured executable's modification time, to tell whether a newer install is not yet running.
    public var installedAt: Date?
    /// Children not yet reaped, including retired ones still finishing.
    public var liveChildren = 0

    public init(connection: UUID? = nil, target: String? = nil, streamSince: Date? = nil, childSince: Date? = nil,
                installedAt: Date? = nil, liveChildren: Int = 0) {
        (self.connection, self.target, self.streamSince) = (connection, target, streamSince)
        (self.childSince, self.installedAt, self.liveChildren) = (childSince, installedAt, liveChildren)
    }
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
    ///
    /// `selection` (#636) is the selection generation the stream opened on: the request is delivered only while the
    /// session is still on it, so nothing a stream heard reaches a target after the owner selected another
    /// destination, even after selecting this one again. A stream without one dispatches nothing: the current
    /// selection is never assumed.
    ///
    /// `routedFrom` (#636) is the stream's own target, set only when its consumer addressed one of the owner's voice
    /// routes instead. The route is bound for this dispatch on the stream's `selection`, so the session admits it
    /// only while that exact selection of the stream's target holds. A dispatch that starts under an inherited route
    /// is refused. Every other ambient request, and the local socket's `dispatch` kind, binds none and stays limited
    /// to the selected target.
    func dispatchAmbient(
        _ request: LocalDispatchRequest, reference: UUID? = nil, selection: UUID?, routedFrom: String? = nil
    ) async throws -> UUID? {
        // Never under a route some other delivery bound: a task it spawned inherits the task-local (#636, #688 review).
        guard HostSession.voiceRouted == nil, let selection else { throw LocalDispatchRefusal.notAuthorized }
        guard let peer = peers.first(where: { $0.value.session.connectionID == request.connection }) else {
            throw LocalDispatchRefusal.unknownConnection
        }
        var named = request
        named.connection = peer.key
        // The route is pinned to the selection generation the stream opened on, as the dispatch itself is.
        let routed = routedFrom.map { HostSession.VoiceRouted(from: $0, to: request.target, generation: selection) }
        // The streaming device's own input (#370): a delivered handoff makes it the target's last input device.
        return try await HostSession.$ambientInputDispatch.withValue(true) {
            try await HostSession.$voiceRouted.withValue(routed) {
                guard let reference else { return try await dispatch(named, generation: selection) }
                return try await HostSession.$ambientReplyReference.withValue(reference) {
                    try await dispatch(named, generation: selection)
                }
            }
        }
    }

    /// A voice route's current binding (#636): listed, alive and at the binding its policy entry allows; nil otherwise.
    /// A snapshot for addressing only: local dispatch checks the listing and binding again, and the policy decides.
    func voiceRouteBinding(_ target: String) async -> String? {
        guard let listed = try? await host.registry.listing().first(where: { $0.info.id == target }),
              listed.info.alive, let binding = listed.binding, let policy = await host.refreshedPolicy(),
              policy.targets[target]?.binding == binding else { return nil }
        return binding
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
    /// Whether the connection's device advertised `reply_mute` (#404).
    func acceptsReplyMute(connection: UUID) async -> Bool {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return false
        }
        return await peer.session.replyMuteFrame(muted: true) != nil
    }

    /// Sends `set_reply_mute` (#404) to the connection's device: `sent`, `unsupported` (it did not advertise
    /// `reply_mute`), `failed` (the send failed) or `no_connection`.
    func setReplyMute(_ muted: Bool, connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard let frame = await peer.session.replyMuteFrame(muted: muted) else { return "unsupported" }
        return await peer.send(frame) ? "sent" : "failed"
    }

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

// Behaviour lives in extensions; only stored state (configuration and `State`) is over the limit (#551).
// swiftlint:disable type_body_length
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
        /// Each ambient dispatch is recorded as `pushed(tool: "ambient-dispatch")`, or `ambient-dispatch-routed` for
        /// a voice route (#636), with the target and byte count, never text, as the `--reply-to` socket records
        /// `local-dispatch`; a failed record refuses the dispatch.
        public var audit: AuditLog?
        /// Acknowledgement clips (rightyo#105): each admitted request plays one on its phone first. Nil is off.
        public var acknowledgements: AmbientAckLibrary?
        /// Reply control (rightyo#124): each child gets `--control-fd`, and `replyPlayback` feeds it. Off by default.
        public var replyControl = false
        /// How long the owner's spoken media mode (#551) lasts before it turns itself off.
        public var mediaTimeout: TimeInterval = AmbientRightyoRouter.defaultMediaTimeout
        /// How long the owner's spoken duck mode (#735) lasts before it turns itself off: host.json
        /// `ambient.duckTimeout`, or `defaultDuckTimeout`.
        public var duckTimeout: TimeInterval = AmbientRightyoRouter.defaultDuckTimeout
        /// How long a child launched start-private (#735 S-2b) has to emit `started` before it is killed.
        public var startDeadline: TimeInterval = RightyoAmbientPipeline.defaultStartDeadline
        /// How long each child has to ack a `{"duck":true}` (#735 S-8). Not configurable: tests only shorten it.
        var ackDeadline: TimeInterval = RightyoAmbientPipeline.ackDeadline
        /// The bound on a privacy entry's announcement (#735 S-8 HS-C), nil for start + ack + margin (round 3: never a
        /// separate constant). Not configurable: tests only shorten it.
        var privacyConfirmTimeout: TimeInterval?
        var privacyBound: TimeInterval {
            privacyConfirmTimeout ?? startDeadline + ackDeadline + AmbientRightyoRouter.privacyConfirmMargin
        }
        /// The owner's allowlisted note destinations (#552); nil leaves spoken notes off.
        public var destinations: VoiceDestinations?
        var notes = VoiceNoteRunner()

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
    /// Confirmation clips this host sent (#418); heard back word for word, they are echo however short.
    let hostPhrases = HostPhrases()

    public func observeReply(_ frame: Frame) {
        spokenReplies.observe(frame)
        switch frame.payload {
        case .text(let text):
            guard text.isFinal, let reply = text.reply else { return }
            let asked = text.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            state.withLock { $0.replyAsked = asked ? reply.id : nil }
        case .audio(let audio):
            guard let reply = audio.reply else { return }
            state.withLock { if $0.replyAsked != reply.id { $0.replyAsked = nil } }
        default: return
        }
    }
    /// Runs at once, including those whose child is reaped but whose dispatch is still typing. A run stuck in a
    /// dispatch therefore blocks new starts only once this many are stuck.
    public static let maxRuns = 4
    /// A retired child forced out to make room for a new device's stream (#366) gets this long after EOF, then this
    /// long after SIGTERM, before SIGKILL: about a second, then it is reaped.
    public static let forcedStopGrace: TimeInterval = 0.5
    /// Segments of the newest start kept while it makes room: 6.4 s of 100 ms segments; the oldest is dropped.
    public static let maxQueuedSegments = 64

    fileprivate struct State {
        var listener: WeakListener?
        var active: Active?
        var runs: [UUID: Run] = [:]
        var shuttingDown = false
        /// A reload is building its child (#405); a second one is refused as busy.
        var reloading = false
        var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        /// Each live connection's most recent started stream (one entry per connection, dropped when it ends),
        /// so a normally ended stream's late failure is still reported until the connection starts another.
        var latest: [UUID: UUID] = [:]
        var retirements = 0
        /// Events waiting for the worker (#366). While a start is making room every later event queues behind it,
        /// so the gate's order is kept; with nothing queued, events are handled at once on the gate's actor. Kept
        /// small by `enqueue`: only the newest start and what still matters to a live child stay queued.
        var queue: [AmbientAudioEvent] = []
        var working = false
        /// The newest stream the gate started: the only one a queued start may make room or spawn for.
        var newestStart: UUID?
        var peakQueue = 0
        var worker: Task<Void, Never>?
        /// Each live connection's last input route kind (rightyo#164), for its next child's `RIGHTYO_INPUT_ROUTE`;
        /// one entry per connection the listener holds, dropped in `stop(connection:)`.
        var inputRoutes: [UUID: String] = [:]
        /// Connections whose owner turned media mode on (#551), each with its timeout; dropped (and the timeout
        /// cancelled) when it ends, times out or the connection stops. Every child registered meanwhile is told.
        var media: [UUID: AmbientMediaTimer] = [:]
        /// Connections whose owner turned duck mode on (#735), kept like `media`. A connection is never in both.
        var duck: [UUID: AmbientDuckTimer] = [:]
        /// Privacy entries and the last word per connection (#735 S-8 HS-C round 4, `AmbientPrivacyLedger`), and each
        /// connection's one chain for privacy clips and child refusals, queued under this lock as each is decided, so
        /// their order is the order decided.
        var privacy: [UUID: AmbientPrivacyLedger<RightyoAmbientPipeline>] = [:]
        var privacyClips: [UUID: SerialTaskChain] = [:]
        /// The reply whose final text, the latest this host delivered, ended with a question (rightyo#199); nil
        /// otherwise, and cleared by audio of any other reply (a text-less acknowledgement clip). The phone plays
        /// replies in order and reports one end when its queue drains, so that reply is the one just heard.
        var replyAsked: UUID?
    }
    fileprivate struct WeakListener { weak var value: WebSocketListener? }

    public let configuration: Configuration
    fileprivate let state = Mutex(State())
    fileprivate let log: @Sendable (WebSocketListenerEvent) -> Void
    /// Wakes the worker; signals coalesce, the events themselves are in `State.queue`.
    fileprivate let wake: AsyncStream<Void>.Continuation
    /// Media and duck mode state for devices (#612, #735), sent one at a time in the order the modes changed.
    fileprivate let mediaNotices = SerialTaskChain()
    /// The origin of the privacy ledgers' clock (#735 S-8 HS-C round 4).
    let privacyEpoch = ContinuousClock.now

    public init(configuration: Configuration, log: @escaping @Sendable (WebSocketListenerEvent) -> Void = { _ in }) {
        (self.configuration, self.log) = (configuration, log)
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        let worker = Task { [weak self] in
            for await _ in wakes { await self?.drainQueue() }
            await self?.drainQueue()
        }
        state.withLock { $0.worker = worker }
    }

    public func attach(_ listener: WebSocketListener) {
        state.withLock { $0.listener = WeakListener(value: listener) }
    }

    /// Called in order from the gate's actor; only spawns, enqueues or signals, never awaits. A start that finds
    /// every child slot taken goes to the worker, which forces the oldest retired child out first (#366); until it
    /// is done, every later event queues behind it.
    public func ambientAudio(_ event: AmbientAudioEvent) {
        let queued = state.withLock { state -> Bool in
            switch event {
            case .started(let stream, let connection, _): state.latest[connection] = stream
            // Taken over (#366): the old stream's late failure is not reported to its device as a stop.
            case .ended(let stream, .superseded): state.latest = state.latest.filter { $0.value != stream }
            default: break
            }
            if case .started(let stream, _, _) = event { state.newestStart = stream }
            // Shutting down: nothing more is queued (starts are refused inline as stopping).
            if state.shuttingDown { return false }
            // While a reload builds its child (#405), events queue too: the worker waits for the reload, so a start
            // cannot launch beside the reload's child and the old one, past `maxLiveChildren`.
            guard state.queue.isEmpty, !state.working, !state.reloading, !Self.mustMakeRoom(for: event, state) else {
                Self.enqueue(event, into: &state)
                return true
            }
            return false
        }
        if queued { wake.yield() } else { handle(event) }
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
        let target = state.withLock { state -> (RightyoAmbientPipeline, Bool)? in
            guard let stream = state.latest[connection], let active = state.active, active.stream == stream else {
                return nil
            }
            return (active.pipeline, state.replyAsked != nil)
        }
        guard let (pipeline, replyAsked) = target else { return }
        // Only an end says whether the reply asked the owner something; RightyO times answers from it.
        let asked = phase == .ended && replyAsked
        emit("ambient_reply",
             detail: "phase=\(phase.rawValue) asked=\(asked) reported=\(pipeline.reportReply(phase, asked: asked))")
    }

    public func stop(connection: UUID) {
        let streams = state.withLock { state -> [UUID] in
            (state.latest[connection], state.inputRoutes[connection]) = (nil, nil)
            state.media.removeValue(forKey: connection)?.timer.cancel()
            state.duck.removeValue(forKey: connection)?.timer?.cancel()
            if state.privacy[connection]?.entries.isEmpty != false { state.privacy[connection] = nil }
            // Clips already queued still play in order; a later one (none should come) starts a fresh chain.
            state.privacyClips[connection] = nil
            state.listener?.value?.replyHold.set(false, connection: connection)
            if let active = state.active, state.runs[active.run]?.connection == connection { state.active = nil }
            return state.runs.filter { $0.value.connection == connection }.map(\.key)
        }
        streams.forEach { retire($0) }
    }

    public func shutdown() async {
        // Queued events are still handled (starts are refused now), and a forced stop in progress finishes.
        let worker = state.withLock { state in
            state.shuttingDown = true
            return state.worker
        }
        wake.finish()
        await worker?.value
        let pipelines = state.withLock { state in
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
    /// The stream whose child is fed audio now, and the most events ever queued at once (tests).
    var activeStream: UUID? { state.withLock { $0.active?.stream } }
    var activePipeline: RightyoAmbientPipeline? { state.withLock { $0.active?.pipeline } }
    public func activeConnection() -> UUID? {
        state.withLock { state in
            let connection = state.active.flatMap { state.runs[$0.run]?.connection }
            return Self.ambientOwner(stream: state.active?.stream, connection: connection,
                                     newestStart: state.newestStart, queued: state.queue)
        }
    }

    var peakQueue: Int { state.withLock { $0.peakQueue } }
    public func mediaMode(connection: UUID) -> Bool { state.withLock { $0.media[connection] != nil } }
    /// Whether the owner's spoken duck mode (#735) is on for `connection` (tests).
    func duckMode(connection: UUID) -> Bool { state.withLock { $0.duck[connection] != nil } }
    /// The current privacy arming's token for `connection`, nil while privacy is off (#735 S-6: a device switch reads
    /// it, then changes privacy only while it is still the current one).
    func duckArming(connection: UUID) -> UUID? { state.withLock { $0.duck[connection]?.token } }
    /// The listener this router is attached to, if it is still there (#735 S-6: a device switch's stop and clip).
    var attachedListener: WebSocketListener? { state.withLock { $0.listener?.value } }

    /// Waits (at most 30 s) for queued events to be handled, then for every current run to return (tests).
    func settle() async {
        for _ in 0..<3_000 where state.withLock({ !$0.queue.isEmpty || $0.working }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for task in state.withLock({ $0.runs.values.compactMap(\.task) }) { await task.value }
    }
}
// swiftlint:enable type_body_length

extension AmbientRightyoRouter {
    /// Keyed by its own id, not its stream's: a reload (#405) gives one stream a second run.
    fileprivate struct Run {
        let stream: UUID
        let connection: UUID
        let pipeline: RightyoAmbientPipeline
        let since = Date()
        var reaped = false
        /// Swapped out by a reload (#405): its stream lives on in a newer run, so its end is logged, never reported.
        var replaced = false
        /// Its child has ended and its end is being logged; a reload no longer replaces it (#405).
        var ending = false
        /// Order of retirement (EOF sent), so the oldest retired child is the one forced out (#366).
        var retiredAt: Int?
        var forced = false
        /// Why the gate ended the stream (idle, final, malformed, …), reported in `ambient_ended` (#282).
        var gateEnd: AmbientStreamEndReason?
        var task: Task<Void, Never>?
    }
    /// The stream whose child is fed audio now: its run, when the stream itself started and the selection generation
    /// it opened on (#636), both kept across reloads.
    fileprivate struct Active {
        let stream: UUID
        let run: UUID
        let pipeline: RightyoAmbientPipeline
        let since: Date
        let selection: UUID?
    }
}

extension AmbientRightyoRouter {
    /// Closes the child's input and stops it; once it is reaped it no longer counts against `maxLiveChildren`.
    /// `grace` shortens the stop (#405); nil keeps the configured timing.
    fileprivate func retire(_ id: UUID, grace: TimeInterval? = nil) {
        let pipeline = state.withLock { state -> RightyoAmbientPipeline? in
            guard let run = state.runs[id] else { return nil }
            if run.retiredAt == nil {
                state.retirements += 1
                state.runs[id]?.retiredAt = state.retirements
            }
            return run.pipeline
        }
        guard let pipeline else { return }
        pipeline.finishInput()
        Task {
            if let grace { await pipeline.stop(grace: grace) } else { await pipeline.stop() }
            self.state.withLock { $0.runs[id]?.reaped = true }
        }
    }

    /// The gate's events, in order: spawn, feed, retire.
    fileprivate func handle(_ event: AmbientAudioEvent) {
        switch event {
        case .started(let stream, let connection, let selection):
            start(stream, connection: connection, selection: selection)
        case .segment(let stream, _, let bytes):
            let pipeline = state.withLock { $0.active?.stream == stream ? $0.active?.pipeline : nil }
            // Overload drops the oldest audio; it never blocks the gate. Refused input means the child is gone
            // (its run may still be finishing a dispatch), so the stream ends instead of absorbing audio.
            if let pipeline, !pipeline.send(audio: bytes) { inputClosed(stream, pipeline: pipeline) }
        case .ended(let stream, let reason):
            let run = state.withLock { state -> UUID? in
                for (id, run) in state.runs where run.stream == stream { state.runs[id]?.gateEnd = reason }
                guard let active = state.active, active.stream == stream else { return nil }
                state.active = nil
                return active.run
            }
            if let run { retire(run) }
        }
    }

    /// Handles queued events in order until none is left (#366), once any reload in progress is done (#405). A reload
    /// is bounded: a launch, then at most a short forced stop of a refused child.
    fileprivate func drainQueue() async {
        while state.withLock({ $0.reloading }) { try? await Task.sleep(for: .milliseconds(10)) }
        while let event = state.withLock({ state -> AmbientAudioEvent? in
            guard !state.queue.isEmpty else {
                state.working = false
                return nil
            }
            state.working = true
            return state.queue.removeFirst()
        }) {
            await work(event)
        }
    }

    /// One queued event. A start that is no longer the newest, or that the gate already ended other than on its
    /// final segment, is skipped: it neither forces a child out nor spawns. The newest makes room first, then
    /// every event is handled as it would be inline.
    private func work(_ event: AmbientAudioEvent) async {
        if case .started(let stream, _, _) = event {
            guard isLive(stream) else { return }
            await makeRoom(for: stream)
            guard isLive(stream) else { return }
        }
        handle(event)
    }

    /// The newest start, not shutting down, and not ended by the gate except on its final segment.
    private func isLive(_ stream: UUID) -> Bool {
        state.withLock { state in
            guard !state.shuttingDown, state.newestStart == stream else { return false }
            return !state.queue.contains {
                if case .ended(stream, let reason) = $0 { reason != .final } else { false }
            }
        }
    }

    /// Queues `event`, keeping the queue small whatever an admitted client sends (#366): a start drops every queued
    /// event of an older queued start (never spawned, now superseded); a segment is kept only for the newest
    /// start, at most `maxQueuedSegments` of them, oldest dropped; an end is kept only for a stream with a child or
    /// the newest start. What stays is the newest start and its audio plus the ends of streams with children.
    fileprivate static func enqueue(_ event: AmbientAudioEvent, into state: inout State) {
        switch event {
        case .started:
            let dead = Set(state.queue.compactMap { if case .started(let stream, _, _) = $0 { stream } else { nil } })
            state.queue.removeAll { dead.contains($0.stream) }
        case .segment(let stream, _, _):
            guard stream == state.newestStart else { return }
            let queued = state.queue.filter { if case .segment = $0 { true } else { false } }.count
            if queued >= maxQueuedSegments,
               let oldest = state.queue.firstIndex(where: { if case .segment = $0 { true } else { false } }) {
                state.queue.remove(at: oldest)
            }
        case .ended(let stream, _):
            guard stream == state.newestStart || state.runs.values.contains(where: { $0.stream == stream }) else {
                return
            }
        }
        state.queue.append(event)
        state.peakQueue = max(state.peakQueue, state.queue.count)
    }

    /// True for a start that would find every child slot taken.
    fileprivate static func mustMakeRoom(for event: AmbientAudioEvent, _ state: State) -> Bool {
        guard case .started = event, !state.shuttingDown else { return false }
        return full(state)
    }

    private static func forcingOrder(_ run: Run) -> (Int, Int) {
        (run.gateEnd == .superseded ? 0 : 1, run.retiredAt ?? 0)
    }

    fileprivate static func full(_ state: State) -> Bool {
        state.runs.values.filter { !$0.reaped }.count >= maxLiveChildren || state.runs.count >= maxRuns
    }

    /// Forces out the oldest retired child, one at a time, until a slot is free or none is left to force: EOF,
    /// SIGTERM after `forcedStopGrace`, SIGKILL after as long again, then up to 2 s for the group to settle, so up
    /// to about 3 s each. It is counted as reaped once that returns, even if only SIGKILL had been sent by then (the
    /// group finishes on its own). Its run is never cancelled; it gets up to 1 s more to return, and a dispatch it
    /// had not made is lost (the device moved, #366). Only the newest live start forces anything out.
    /// A superseded child goes first: forcing out one whose stream ended normally (final, idle) could cut off that
    /// device's last utterance.
    private func makeRoom(for start: UUID) async {
        while true {
            let victim = state.withLock { state -> (UUID, RightyoAmbientPipeline)? in
                guard !state.shuttingDown, state.newestStart == start, Self.full(state),
                      let (id, run) = state.runs
                        .filter({ $0.value.retiredAt != nil && !$0.value.reaped && !$0.value.forced })
                        .min(by: { Self.forcingOrder($0.value) < Self.forcingOrder($1.value) }) else { return nil }
                state.runs[id]?.forced = true
                return (id, run.pipeline)
            }
            guard let (id, pipeline) = victim else { return }
            emit("ambient_retired_forced", detail: nil)
            await pipeline.stop(grace: Self.forcedStopGrace)
            state.withLock { $0.runs[id]?.reaped = true }
            for _ in 0..<50 where state.withLock({ $0.runs[id] != nil }) {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// The active child refused audio: end its stream at the gate and tell the peer, once. Only while `pipeline` is
    /// still the active one: a segment that raced to a child a reload just replaced (#405) ends nothing.
    func inputClosed(_ stream: UUID, pipeline: RightyoAmbientPipeline) {
        let closed = state.withLock { state -> (run: UUID, connection: UUID)? in
            guard let active = state.active, active.stream == stream, active.pipeline === pipeline,
                  let connection = state.runs[active.run]?.connection else { return nil }
            state.active = nil
            return (active.run, connection)
        }
        guard let (run, connection) = closed else { return }
        let listener = state.withLock { $0.listener?.value }
        retire(run)
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

    fileprivate func start(_ stream: UUID, connection: UUID, selection: UUID?) {
        let (listener, refusal) = state.withLock { state -> (WebSocketListener?, String?) in
            if state.shuttingDown { return (nil, "stopping") }
            if Self.full(state) { return (nil, "busy") }
            return (state.listener?.value, state.listener?.value == nil ? "stopping" : nil)
        }
        guard let listener, refusal == nil else {
            return refuse(stream, connection: connection, reason: refusal ?? "stopping")
        }
        let pipeline: RightyoAmbientPipeline
        do { pipeline = try makePipeline(connection: connection, selection: selection, listener: listener) } catch {
            return refuse(stream, connection: connection, reason: Self.describe(error))
        }
        let admitted = state.withLock { state -> Bool in
            guard !state.shuttingDown else { return false }
            let id = register(pipeline, stream: stream, connection: connection, in: &state)
            state.active = Active(stream: stream, run: id, pipeline: pipeline, since: Date(),
                                  selection: selection)
            return true
        }
        guard admitted else {
            Task { await pipeline.stop() }
            return
        }
    }

    /// One child for `connection`'s stream, launched now; a refusal launches nothing. Shared by a start and a
    /// reload (#405), so a reloaded child is configured exactly as a fresh one, on the stream's `selection` (#636).
    fileprivate func makePipeline(
        connection: UUID, selection: UUID?, listener: WebSocketListener
    ) throws -> RightyoAmbientPipeline {
        var settings = RightyoAmbientPipeline.Configuration(
            executable: configuration.executable, config: configuration.config, target: configuration.target,
            binding: configuration.binding, connection: connection,
            allowSynthetic: configuration.allowSynthetic, timing: configuration.timing,
            isEcho: { [spokenReplies, hostPhrases] heard in hostPhrases.isEcho(heard) || spokenReplies.isEcho(heard) },
            onDismiss: dismissed(on: connection, listener: listener),
            onAcknowledge: acknowledged(on: connection, listener: listener)
        )
        (settings.replyControl, settings.onAcknowledgementSkipped) = (configuration.replyControl, skipped())
        (settings.onHeard, settings.onOverheard) = transcriptRelays(on: connection, listener: listener)
        settings.onVoiceMute = voiceMuted(on: connection, listener: listener)
        settings.onVoiceMedia = voiceMedia(on: connection, listener: listener)
        // The child's privacy state, held once it exists, so its refusal is said by the state rule (round 4).
        let mark = AmbientRunMark()
        (settings.onVoiceDuck, settings.onDuckUnsupported) = (voiceDuck(on: connection, listener: listener, mark: mark),
                                                              duckUnsupported(on: connection))
        // Privacy on (#735 S-2b): the child is launched already private, on a spawn, a respawn or a reload alike.
        settings.startPrivate = state.withLock { $0.duck[connection] != nil }
        (settings.startDeadline, settings.ackDeadline) = (configuration.startDeadline, configuration.ackDeadline)
        if let destinations = configuration.destinations {
            (settings.destinations, settings.onVoiceDestination) = (destinations, voiceNote(on: connection,
                                                                                            listener: listener))
        }
        (settings.onOwnerVoice, settings.environment) = (ownerVoice(on: connection, listener: listener),
                                                         childEnvironment(for: connection))
        // The owner's voice routes (#636), from the same authorizer the listing names them with.
        if let routes = listener.authorizer.voiceRoutes {
            settings.routing = RightyoVoiceRouting(routes: routes) { [weak listener] target in
                await listener?.voiceRouteBinding(target)
            }
            settings.onVoiceRouteRefused = voiceRouteRefused(on: connection, listener: listener)
        }
        let pipeline = try RightyoAmbientPipeline(configuration: settings,
                                                  dispatcher: AmbientListenerDispatcher(
                                                      listener: listener, audit: configuration.audit,
                                                      selection: selection, streamTarget: configuration.target
                                                  ))
        mark.set(pipeline.privacyControl)
        return pipeline
    }

    /// Registers a run for `pipeline` under the caller's lock and returns its id. The task is created under the lock,
    /// so the run's own removal cannot precede its registration. The run's own task emits `ambient_started` first, so
    /// it always precedes that run's `ambient_ended`, even when a child exits at once beside another live run (#273).
    /// A reload's run (#405) emits `ambient_reloaded` first for the same reason: a new child that fails at once must
    /// leave its failure, not the reload, as the last event.
    fileprivate func register(_ pipeline: RightyoAmbientPipeline, stream: UUID, connection: UUID, reload: Bool = false,
                              in state: inout State) -> UUID {
        let id = UUID()
        state.runs[id] = Run(stream: stream, connection: connection, pipeline: pipeline)
        // A new or reloaded child starts with media mode off (#551). Told under the same lock `setMedia` changes it
        // under, so it can never miss a change made while it was starting.
        if state.media[connection] != nil { pipeline.reportMedia(true) }
        // Duck mode (#735) likewise; the pipeline writes it once the child's `started` says it takes it. Always told,
        // so a child launched start-private (S-2b) whose privacy ended meanwhile is written off once it confirms.
        pipeline.reportDuck(state.duck[connection] != nil)
        // An entry still awaiting its announcement answers for this child too (#735 S-8 HS-C round 2), within the
        // child's own bound from now (round 4); while private after "unavailable", a recovery entry announces it.
        registerPrivacy(pipeline, connection: connection, in: &state)
        state.runs[id]?.task = Task { [weak self] in
            if reload { self?.emit("ambient_reloaded", detail: nil) }
            self?.emit("ambient_started", connection: connection, detail: nil)
            await self?.run(pipeline, id: id, stream: stream, connection: connection)
        }
        return id
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

    /// Shows the phone that heard an admitted request its own words (#318), awaited before the acknowledgement and the
    /// typing. Nothing is logged: the text is transcript content.
    private func heard(on connection: UUID, listener: WebSocketListener) -> @Sendable (String) async -> Void {
        let target = configuration.target
        return { [weak listener] text in
            await listener?.showAmbientHeard(connection: connection, target: target, text: text)
        }
    }

    /// The phone's own words, sent (#318) and not sent (#398), for the stream on `connection`.
    private func transcriptRelays(
        on connection: UUID, listener: WebSocketListener
    ) -> (@Sendable (String) async -> Void, @Sendable (String, Bool, String?) async -> Void) {
        (heard(on: connection, listener: listener), overheard(on: connection, listener: listener))
    }

    /// Shows the phone that heard a turn RightyO did not send (#398), within the scope that phone asked for, with a
    /// known guest's name (#434) when it can show one. Nothing is logged: text and name are transcript content.
    private func overheard(
        on connection: UUID, listener: WebSocketListener
    ) -> @Sendable (String, Bool, String?) async -> Void {
        let target = configuration.target
        return { [weak listener] text, owner, name in
            await listener?.showAmbientOverheard(
                connection: connection, target: target, text: text, owner: owner, name: name
            )
        }
    }

    /// A request RightyO marked not to acknowledge (rightyo#132) plays nothing; its skip is logged with labels and
    /// numbers only, never transcript text.
    private func skipped() -> @Sendable (AmbientAckSkip) -> Void {
        { [weak self] skip in self?.emit("ambient_acknowledged", detail: skip.detail) }
    }

    /// A `dismiss` with `playback` in scope stops reply playback on its connection (#309) before it is logged, so
    /// the diagnostic says what happened; any other dismissal is logged at once. Neither ends the stream. The owner's
    /// stop is then confirmed out loud on that connection (#418), after the stop, so the stop never cuts it.
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
                await self?.confirmStop(receipt, playback: playback, on: connection, listener: listener)
            }
        }
    }

    /// The owner's spoken "mute" or "unmute" (#404) on the connection that said it; it is never typed to the agent. A
    /// mute stops the reply now playing, plays "Muted." and only then sends `set_reply_mute`, so the device lets the
    /// confirmation finish before it goes quiet; an unmute sends it first, so "Unmuted." is heard. A device without
    /// `reply_mute` is only stopped, and confirmed as a stop. Logs tokens only.
    /// Ordering: the mute frame is sent only once `acknowledgeAmbient` has returned, which waits for the connection to
    /// have processed every clip frame, its final audio frame last; one connection sends in order, so the device has
    /// the clip before the mute and treats the mute as one to apply after it. Commands from one connection run one
    /// at a time in the order said, so a quick "mute" then "unmute" ends unmuted.
    private func voiceMuted(on connection: UUID, listener: WebSocketListener) -> @Sendable (Bool) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] muted in
            chain.enqueue { [weak self, weak listener] in
                await self?.carryOutVoiceMute(muted, on: connection, listener: listener)
            }
        }
    }

    /// One voice mute or unmute, as `voiceMuted` describes; returns once its frames are sent and it is logged.
    private func carryOutVoiceMute(_ muted: Bool, on connection: UUID, listener: WebSocketListener?) async {
        let supported = await listener?.acceptsReplyMute(connection: connection) ?? false
        var mute = supported ? "pending" : "unsupported"
        if !muted, supported { mute = await listener?.setReplyMute(false, connection: connection) ?? "" }
        let playback = muted ? await listener?.stopReplyPlayback(connection: connection) ?? "no_connection" : "none"
        let persona = supported ? (muted ? AmbientStopConfirmation.muted : AmbientStopConfirmation.unmuted)
            : (muted ? AmbientStopConfirmation.stopped : nil)
        var confirm = "none"
        if let persona { confirm = await confirmVoiceMute(persona, on: connection, listener: listener) }
        if muted, supported { mute = await listener?.setReplyMute(true, connection: connection) ?? "" }
        emit("ambient_voice_mute", detail: "muted=\(muted) mute=\(mute) playback=\(playback) confirm=\(confirm)")
    }

    /// One confirmation clip from `persona`'s reserved folder, sent like the stop confirmation; its outcome token.
    func confirmVoiceMute(
        _ persona: String, on connection: UUID, listener: WebSocketListener?
    ) async -> String {
        guard let library = configuration.acknowledgements,
              let pick = AmbientStopConfirmation.clip(persona, in: library) else { return "no_clips" }
        let outcome = await listener?.acknowledgeAmbient(connection: connection, target: configuration.target,
                                                         clip: pick.clip) ?? "no_connection"
        hostPhrases.observe(pick.clip, outcome: outcome)
        return "\(pick.persona)/\(pick.index):\(outcome)"
    }

    /// Plays the stop confirmation clip (#418) on the connection that said stop, through the same guarded path as an
    /// acknowledgement: only that connection, never the Mac, never the agent session. Once sent, its words are held
    /// as a host phrase, so hearing them back, however short, is echo rather than a request or an overheard turn; an
    /// undelivered clip is never held. Logs tokens only.
    private func confirmStop(
        _ receipt: RightyoDismissReceipt, playback: String, on connection: UUID, listener: WebSocketListener?
    ) async {
        guard let library = configuration.acknowledgements else { return }
        if let reason = AmbientStopConfirmation.skipReason(for: receipt, playback: playback) {
            emit("ambient_stop_confirmed", detail: "outcome=skipped reason=\(reason)")
            return
        }
        guard let wanted = AmbientStopConfirmation.persona(for: receipt, playback: playback),
              let pick = AmbientStopConfirmation.clip(wanted, in: library) else {
            emit("ambient_stop_confirmed", detail: "outcome=skipped reason=no_clips")
            return
        }
        let outcome = await listener?.acknowledgeAmbient(connection: connection, target: configuration.target,
                                                         clip: pick.clip) ?? "no_connection"
        hostPhrases.observe(pick.clip, outcome: outcome)
        emit("ambient_stop_confirmed", detail: "clip=\(pick.persona)/\(pick.index) outcome=\(outcome)")
    }

    private func run(_ pipeline: RightyoAmbientPipeline, id: UUID, stream: UUID, connection: UUID) async {
        var failure: String?
        let detail: String
        do {
            let summary = try await pipeline.run()
            let echo = await pipeline.echoDropped
            let gateEnd = state.withLock { $0.runs[id]?.gateEnd.map { "\($0)" } } ?? "none"
            detail = "delivered=\(summary.delivered) written=\(summary.child.writtenBytes)"
                + " dropped=\(summary.child.droppedBytes) echo=\(echo) ended=\(gateEnd) exit=\(summary.exit)"
        } catch {
            let described = Self.describe(error)
            (failure, detail) = (described, described)
            // A child that could not keep privacy (#735 S-2b, S-8: no ack) was killed and is not admitted; privacy
            // stays on.
            if let refusal = error as? RightyoPrivacyRefusal, refusal != .unsupportedChild {
                let reason = refusal == .unconfirmedStart ? "unconfirmed" : "unacknowledged"
                emit("ambient_privacy_start", connection: connection, detail: "outcome=refused reason=\(reason)")
            }
        }
        // A reload's replaced child (#405) is marked `replaced`, so `haild doctor` does not read its end as a failure.
        // Read and `ending` set in one lock, with no suspension before the emit: a reload cannot replace this run
        // once its end is decided, so the mark always matches.
        let replacedNow = state.withLock { state -> Bool in
            state.runs[id]?.ending = true
            return state.runs[id]?.replaced == true
        }
        emit("ambient_ended", detail: (replacedNow ? "replaced " : "") + detail)
        let (stillActive, replaced, listener, waiters) = state.withLock { state in
            let replaced = state.runs.removeValue(forKey: id)?.replaced ?? false
            // By identity, not stream: after a reload (#405) the stream is the same but the active run is not.
            let active = state.active?.run == id
            if active { state.active = nil }
            let waiters = state.runs.isEmpty ? Array(state.drainWaiters.values) : []
            if state.runs.isEmpty { state.drainWaiters = [:] }
            return (active, replaced, state.shuttingDown ? nil : state.listener?.value, waiters)
        }
        waiters.forEach { $0.resume() }
        // A clean run whose stream already ended is the normal path; anything else ends the stream and tells
        // the phone, even a refusal after the stream ended (for example confirmation required). A run a reload
        // replaced is only logged above: its stream lives on in the new child, so even a non-zero exit stays here.
        guard !replaced, failure != nil || stillActive, let listener else { return }
        await listener.ambientFailed(stream: stream, connection: connection,
                                     message: "ambient stopped: \(failure ?? "listener exited")")
    }

    private func refuse(_ stream: UUID, connection: UUID, reason: String) {
        emit("ambient_refused", detail: reason)
        // A start refused while private (#735 S-2b): nothing listens, privacy stays on, and the owner is told by the
        // state rule (round 4), as a child's refusal is.
        announceRefusal(nil, connection: connection)
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
        case let error as RightyoPrivacyRefusal: "privacy \(error)"
        case let error as RightyoInputError: "input \(error)"
        case let error as LocalDispatchRefusal: "dispatch \(error.rawValue)"
        case let error as LocalReplyRefusal: "dispatch \(error.rawValue)"
        default: "failed"
        }
    }

    func emit(_ event: String, connection: UUID? = nil, detail: String?) {
        log(WebSocketListenerEvent(event: event, sessionID: connection, detail: detail))
    }
}

extension AmbientRightyoRouter {
    private enum ReloadClaim {
        case refused(AmbientReloadOutcome)
        case claimed(old: Active, connection: UUID, listener: WebSocketListener)
    }

    /// `haild ambient reload` (#405): a fresh child for the active stream, with the current install and config, on the
    /// same connection, target and binding. The phone is not told: its stream id stays valid at the gate, and its audio
    /// goes to the new child from the swap on (a second or so of speech around it may be lost). The child is built
    /// outside the lock and swapped in only if the same stream and child are still active; a refused launch keeps the
    /// old child. The replaced child gets EOF and the short forced-stop graces (#366); its run is never cancelled, so a
    /// dispatch in flight finishes typing, and its end is logged only. It only re-arms listening already on.
    public func reload() async -> AmbientReloadOutcome {
        let claim = state.withLock { state -> ReloadClaim in
            if state.shuttingDown { return .refused(.stopping) }
            guard let active = state.active, let run = state.runs[active.run] else { return .refused(.idle) }
            // Its child has already ended; the stream is ending with it, and its end event must stay the last one.
            guard !run.ending else { return .refused(.busy) }
            guard let listener = state.listener?.value else { return .refused(.stopping) }
            // A start making room, another reload, or no free child slot: try again shortly.
            guard !state.reloading, state.queue.isEmpty, !state.working, !Self.full(state) else {
                return .refused(.busy)
            }
            state.reloading = true
            return .claimed(old: active, connection: run.connection, listener: listener)
        }
        guard case .claimed(let old, let connection, let listener) = claim else {
            if case .refused(let outcome) = claim { return outcome }
            return .busy
        }
        defer { state.withLock { $0.reloading = false } }
        let pipeline: RightyoAmbientPipeline
        do { pipeline = try makePipeline(connection: connection, selection: old.selection, listener: listener) } catch {
            let reason = Self.describe(error)
            emit("ambient_reload_refused", detail: reason)
            return .refused(reason)
        }
        let outcome = swap(old, for: pipeline, connection: connection)
        guard outcome == .reloaded else {
            // Awaited, so the reload answers only once this child is reaped. Shutdown's drain does not wait for it
            // (it was never a run); a daemon exit closes its input anyway.
            await pipeline.stop(grace: Self.forcedStopGrace)
            return outcome
        }
        retire(old.run, grace: Self.forcedStopGrace)
        return .reloaded
    }

    /// Swaps `pipeline` in under one lock, only if `old` is still the active child and a slot is still free.
    private func swap(_ old: Active, for pipeline: RightyoAmbientPipeline, connection: UUID) -> AmbientReloadOutcome {
        state.withLock { state -> AmbientReloadOutcome in
            if state.shuttingDown { return .stopping }
            guard let active = state.active else { return .idle }
            // The stream ended, moved or failed meanwhile; this child is not wanted.
            guard active.stream == old.stream, active.pipeline === old.pipeline, !Self.full(state),
                  state.runs[old.run]?.ending == false else { return .busy }
            state.runs[old.run]?.replaced = true
            // Retired in the same lock, so a take-over start in the meantime finds it as a victim to force out.
            state.retirements += 1
            state.runs[old.run]?.retiredAt = state.retirements
            let id = register(pipeline, stream: old.stream, connection: connection, reload: true, in: &state)
            state.active = Active(stream: old.stream, run: id, pipeline: pipeline, since: old.since,
                                  selection: old.selection)
            return .reloaded
        }
    }

    /// Ids, times and counts only (#405). `installedAt` is the configured executable's (symlink-resolved) mtime.
    public func status() -> AmbientRouterStatus {
        let installed = try? FileManager.default.attributesOfItem(
            atPath: configuration.executable.resolvingSymlinksInPath().path)[.modificationDate] as? Date
        return state.withLock { state in
            var status = AmbientRouterStatus(target: configuration.target, installedAt: installed,
                                             liveChildren: state.runs.values.filter { !$0.reaped }.count)
            if let active = state.active, let run = state.runs[active.run] {
                (status.connection, status.streamSince, status.childSince) = (run.connection, active.since, run.since)
            }
            return status
        }
    }
}

/// The pipeline's delivery step: the listener's own in-process dispatch for the streaming peer.
struct AmbientListenerDispatcher: RightyoAmbientDispatching {
    let listener: WebSocketListener
    let audit: AuditLog?
    /// The selection generation the stream opened on (#636); every request it dispatches is pinned to it.
    var selection: UUID?
    /// The stream's own target (#636). A request its consumer routed to another target is dispatched bound to that
    /// route from this target; nil binds none.
    var streamTarget: String?

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        try await dispatch(request, routed: false)
    }

    /// The reply reference (#230) is written first, so the fail-closed audit record carries the final prompt size.
    /// Only a `routed` request to a target other than the stream's is bound as a voice route, and is recorded as
    /// `ambient-dispatch-routed` (still content-free); any other request to another target binds nothing, so the
    /// session refuses it.
    func dispatch(_ request: LocalDispatchRequest, routed: Bool) async throws -> UUID? {
        let (prepared, reference) = await listener.referenceAmbient(request)
        let from = streamTarget.flatMap { routed && $0 != prepared.target ? $0 : nil }
        if let audit {
            do {
                _ = try await audit.record(.pushed(tool: from == nil ? "ambient-dispatch" : "ambient-dispatch-routed",
                                                   target: prepared.target, bytes: prepared.text.utf8.count))
            } catch { throw LocalReplyRefusal.auditFailure }
        }
        return try await listener.dispatchAmbient(prepared, reference: reference, selection: selection,
                                                  routedFrom: from)
    }
}
extension AmbientRightyoRouter {
    /// The active run's connection, unless ownership may already have moved (#230): a newer stream has started, or
    /// a start or end still waits for the worker (a take-over making room, a reload). Then nobody, so the reply is
    /// refused rather than sent to a device that has just lost ambient listening.
    static func ambientOwner(stream: UUID?, connection: UUID?, newestStart: UUID?,
                             queued: [AmbientAudioEvent]) -> UUID? {
        guard let stream, stream == newestStart else { return nil }
        let ownershipPending = queued.contains { event in
            if case .segment = event { return false }
            return true
        }
        return ownershipPending ? nil : connection
    }
}

/// A connection's media mode timeout (#551): the token an expiry must still match, and the task to cancel.
struct AmbientMediaTimer {
    let token: UUID
    let timer: Task<Void, Never>
}

/// Media mode (#551), kept apart from the router's body for the type-length limit.
extension AmbientRightyoRouter {
    /// Three hours: a film or a few episodes, and media mode never outlasts an evening unnoticed.
    public static let defaultMediaTimeout: TimeInterval = 3 * 3600

    /// The owner's spoken media mode (#551): set for every child of `connection` at once, then confirmed with a
    /// `confirm-media-on/` or `confirm-media-off/` clip when there is one, in the order said. A change no child
    /// took (an older RightyO or a full pipe) is not confirmed, so the owner never hears a mode that is not in force.
    /// Logs tokens only.
    /// While private (#735) a media-mode entry is refused, and the owner hears `confirm-privacy-status/` instead.
    func voiceMedia(on connection: UUID, listener: WebSocketListener) -> @Sendable (Bool) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] on in
            let reported = self?.setMedia(on, connection: connection, reason: "voice") ?? 0
            let refused = on && reported == 0 && self?.duckMode(connection: connection) == true
            chain.enqueue { [weak self, weak listener] in
                var confirm = "unreported"
                if refused {
                    confirm = await self?.confirmVoiceMute(AmbientStopConfirmation.privacyStatus, on: connection,
                                                           listener: listener) ?? "none"
                } else if reported > 0 {
                    let persona = on ? AmbientStopConfirmation.mediaOn : AmbientStopConfirmation.mediaOff
                    confirm = await self?.confirmVoiceMute(persona, on: connection, listener: listener) ?? "none"
                }
                self?.emit("ambient_media_confirmed", connection: connection, detail: "on=\(on) confirm=\(confirm)")
            }
        }
    }

    /// The owner's note to an allowlisted destination (#552): its handler saves it, and only once it has does the
    /// device that said it hear a `confirm-saved/` clip; a failure plays `confirm-not-saved/`. One at a time per run
    /// (as the mute's chain), in the order said. A note still running when haild exits leaves its input file, which
    /// the next start sweeps. Logs the destination key, outcome, byte count and clip token; never the words.
    fileprivate func voiceNote(
        on connection: UUID, listener: WebSocketListener
    ) -> @Sendable (String, VoiceDestinations.Destination, String) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] destination, target, text in
            chain.enqueue { [weak self, weak listener] in
                guard let self else { return }
                let outcome = await configuration.notes.run(target, text: text)
                let persona = outcome == "saved" ? AmbientStopConfirmation.saved : AmbientStopConfirmation.notSaved
                let confirm = await confirmVoiceMute(persona, on: connection, listener: listener)
                let detail = "destination=\(destination) outcome=\(outcome) bytes=\(text.utf8.count)"
                emit("ambient_voice_note", connection: connection, detail: "\(detail) confirm=\(confirm)")
            }
        }
    }

    /// An ambient request the owner addressed to a voice route that did not take it (#636, slice 5c): the device that
    /// said it is told, with one refusal line (`voice_route_refused`, sent only to a device that takes request
    /// refusals) and one `confirm-not-sent/` clip, in the order said. Logs the reason and both outcomes as tokens;
    /// never the route's name or the words.
    fileprivate func voiceRouteRefused(
        on connection: UUID, listener: WebSocketListener
    ) -> @Sendable (RightyoVoiceRouting.Refusal) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] refusal in
            chain.enqueue { [weak self, weak listener] in
                guard let self else { return }
                let shown = await listener?.showRouteRefusal(refusal.message, target: configuration.target,
                                                             connection: connection) ?? "no_connection"
                let confirm = await confirmVoiceMute(AmbientStopConfirmation.notSent, on: connection,
                                                     listener: listener)
                emit("ambient_voice_route_refused", connection: connection,
                     detail: "\(refusal.token) shown=\(shown) confirm=\(confirm)")
            }
        }
    }

    /// Turns media mode on or off for `connection` and tells its children; returns how many took it. On (re)arms the
    /// timeout and any change cancels the one before; `expected`, when given, makes this an expiry that applies only
    /// while that timeout is still the current one. The children are written under the lock (a write never blocks),
    /// so a child `register` adds at the same moment either is written here or sees the new state. Media mode a child
    /// took leaves duck mode (#735): the two are exclusive.
    @discardableResult
    func setMedia(_ on: Bool, connection: UUID, reason: String, expected: UUID? = nil) -> Int {
        let changed = state.withLock { state -> Int?? in
            if let expected, state.media[connection]?.token != expected { return nil }
            // Privacy wins (#735, Mick round 2): while private, a media-mode entry from any source is refused, and
            // nothing changes or is queued; media mode never ends privacy.
            if on, state.duck[connection] != nil { return .some(nil) }
            return changeMedia(on, connection: connection, reason: reason, in: &state)
        }
        guard let changed else { return 0 }
        guard let reported = changed else {
            emit("ambient_media", connection: connection, detail: "on=true reason=\(reason) reported=0 refused=private")
            return 0
        }
        emit("ambient_media", connection: connection, detail: "on=\(on) reason=\(reason) reported=\(reported)")
        return reported
    }

    /// Turns duck mode on or off for `connection` (#735), as `setMedia` does, and returns how many children took it.
    /// Only a child whose RightyO advertised duck mode takes it; when none does (an older RightyO) duck mode is not
    /// entered at all, nothing else changes, and the caller tells the owner. An entry no child took while duck mode is
    /// already on (a reloaded child not started yet) leaves it on, timeout unchanged. Duck mode taken leaves media mode.
    @discardableResult
    func setDuck(_ on: Bool, connection: UUID, reason: String, expected: UUID? = nil) -> Int {
        setDuck(on, connection: connection, reason: reason) { expected == nil || $0 == expected } ?? 0
    }

    /// `setDuck`, only while `connection`'s privacy arming (its token, nil while off) still passes `armed`, checked
    /// under the lock that changes it (#735 S-6). Nil when it does not: nothing changes, is logged, written or sent.
    func setDuck(_ on: Bool, connection: UUID, reason: String, whileArming armed: (UUID?) -> Bool) -> Int? {
        switchDuck(on, connection: connection, reason: reason, whileArming: armed, announced: false)?.reported
    }

    /// `setDuck`, which also opens a privacy entry (#735 S-8 HS-C round 2) for an on that a child took or that found
    /// privacy already on, under the same lock: the caller must announce it (`announceEntry`), which closes it. With
    /// `announced` false (round 3: `setDuck`, which announces nothing) no entry is opened, so none is left open.
    /// `clip` (round 4) builds the work that says it, queued on the connection's clip chain under this same lock, so
    /// the chain's order is the order decided (a voice off and a device on racing can never swap their clips).
    func switchDuck(_ on: Bool, connection: UUID, reason: String, whileArming armed: (UUID?) -> Bool,
                    announced: Bool = true,
                    clip: (AmbientPrivacyEntry) -> (@Sendable () async -> Void)? = { _ in nil })
    -> AmbientPrivacyEntry? {
        let decided = state.withLock { state -> (DuckChange, AmbientPrivacyEntry)? in
            guard armed(state.duck[connection]?.token) else { return nil }
            let wasOn = state.duck[connection] != nil
            let reported = changeDuck(on, connection: connection, reason: reason, in: &state)
            let entry = announced && on && (wasOn || reported != nil)
                ? openPrivacyEntry(connection, wasOn: wasOn, in: &state) : nil
            // An off withdraws every entry still open (round 3): each closes in silence, and never inherits a timeout.
            if !on, reported != nil { state.privacy[connection, default: .init()].withdrawAll() }
            var change = DuckChange(duck: reported ?? 0, media: nil, still: reported == nil && wasOn, wasOn: wasOn,
                                    entry: entry)
            if reported != nil, on, state.media[connection] != nil {
                change.media = changeMedia(false, connection: connection, reason: "voice", in: &state)
            }
            let switched = AmbientPrivacyEntry(reported: change.duck, entry: entry, wasOn: wasOn,
                                               on: state.duck[connection] != nil)
            if let work = clip(switched) { Self.clipChain(connection, in: &state).enqueue(work) }
            return (change, switched)
        }
        guard let (changed, switched) = decided else { return nil }
        let refused = !on || changed.duck > 0 ? "" : changed.still ? " still_on" : " refused=unsupported"
        emit("ambient_duck", connection: connection,
             detail: "on=\(on) reason=\(reason) reported=\(changed.duck)\(refused)")
        if let media = changed.media {
            emit("ambient_media", connection: connection, detail: "on=false reason=voice reported=\(media)")
        }
        return switched
    }

    /// Opens the next privacy entry on every child of `connection`, under the caller's lock.
    private func openPrivacyEntry(_ connection: UUID, wasOn: Bool, in state: inout State) -> Int {
        state.privacy[connection, default: .init()].open(on: Self.children(of: connection, in: state), wasOn: wasOn,
                                                         at: privacyNow)
    }

    /// Media mode's change under the caller's lock: the timeout, the children, then the device notice, queued under the
    /// same lock so a timeout's off and a spoken on reach the device in the order the mode changed. How many took it.
    private func changeMedia(_ on: Bool, connection: UUID, reason: String, in state: inout State) -> Int {
        let token = UUID(), timeout = configuration.mediaTimeout
        state.media.removeValue(forKey: connection)?.timer.cancel()
        if on {
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.setMedia(false, connection: connection, reason: "timeout", expected: token)
            }
            state.media[connection] = AmbientMediaTimer(token: token, timer: timer)
        }
        let reported = state.runs.values.filter { $0.connection == connection && $0.pipeline.reportMedia(on) }.count
        // The device sees on only once a child took it, so it never shows a mode not in force; off always (#612).
        if !on || reported > 0 {
            let expires = on ? Int64((Date().timeIntervalSince1970 + timeout) * 1_000) : nil
            let listener = state.listener?.value
            mediaNotices.enqueue { [weak self, weak listener] in
                let sent = await listener?.showMediaMode(on, reason: reason, expires: expires, connection: connection)
                self?.emit("ambient_media_device", connection: connection,
                           detail: "on=\(on) device=\(sent ?? "no_connection")")
            }
        }
        return reported
    }

    /// Duck mode's change under the caller's lock, as `changeMedia`; nil when it was to turn on and no child took it,
    /// in which case every child's wish is withdrawn and nothing else changes (the fail-safe for an older RightyO).
    private func changeDuck(_ on: Bool, connection: UUID, reason: String, in state: inout State) -> Int? {
        let runs = state.runs.values.filter { $0.connection == connection }
        let reported = runs.filter { $0.pipeline.reportDuck(on) }.count
        guard !on || reported > 0 else {
            runs.forEach { _ = $0.pipeline.reportDuck(state.duck[connection] != nil) }
            return nil
        }
        state.duck.removeValue(forKey: connection)?.timer?.cancel()
        // Privacy has no auto-end (Mick, round 2): no timer and no expiry; only the owner's exit ends it.
        if on { state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
        let listener = state.listener?.value
        if on {
            // From now on the agent's replies to this connection are refused (S-2c), then its pending ones dropped.
            listener?.replyHold.set(true, connection: connection)
            mediaNotices.enqueue { [weak self, weak listener] in
                let dropped = await listener?.dropPrivateReplies(connection: connection) ?? 0
                self?.emit("ambient_privacy_replies", connection: connection, detail: "dropped=\(dropped)")
            }
        } else {
            // Released on the same serial queue as the entry's drop, so the drop has finished first and a reply from
            // before the entry cannot slip through a fast entry then exit; skipped if privacy came back meanwhile.
            mediaNotices.enqueue { [weak self, weak listener] in
                guard self?.duckMode(connection: connection) == false else { return }
                listener?.replyHold.set(false, connection: connection)
                self?.emit("ambient_privacy_replies", connection: connection, detail: "released=true")
            }
        }
        mediaNotices.enqueue { [weak self, weak listener] in
            let sent = await listener?.showDuckMode(on, reason: reason, expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=\(on) device=\(sent ?? "no_connection")")
        }
        return reported
    }
}

extension AmbientRightyoRouter {
    /// Reserved for the session-mode auto-stop (#735): `ambient.duckTimeout` and `--ambient-duck-timeout` still set its
    /// length, but privacy never arms it (Mick, round 2).
    func duckTimeoutTask(connection: UUID, token: UUID) -> Task<Void, Never> {
        let timeout = configuration.duckTimeout
        return Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.setDuck(false, connection: connection, reason: "timeout", expected: token)
        }
    }

    /// The children of `connection` that still hear its stream (#735 S-8 HS-C round 2): neither retired by the stream's
    /// end nor swapped out by a reload, nor gone. A draining child hears nothing more, so it never answers for privacy.
    func listeningPipelines(connection: UUID) -> [RightyoAmbientPipeline] {
        state.withLock { Self.listening(connection, in: $0) }
    }

    fileprivate static func listening(_ connection: UUID, in state: State) -> [RightyoAmbientPipeline] {
        state.runs.values.filter { $0.connection == connection && $0.retiredAt == nil }.map(\.pipeline)
    }

    /// Every child of `connection` with its privacy state, retired ones included, for an entry to open on.
    fileprivate static func children(of connection: UUID, in state: State) -> [(RightyoAmbientPipeline,
                                                                                AmbientDuckControl)] {
        state.runs.values.filter { $0.connection == connection }.map { ($0.pipeline, $0.pipeline.privacyControl) }
    }

    /// Now on the privacy ledgers' clock (round 4), in seconds.
    var privacyNow: Double {
        let elapsed = privacyEpoch.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// Whether `connection`'s entry `entry` no longer waits on its children: an off withdrew it, a newer entry
    /// supersedes it, or it is closed (round 4).
    func privacyWithdrawn(_ entry: Int, connection: UUID) -> Bool {
        state.withLock { state in
            guard let ledger = state.privacy[connection], let open = ledger.entries[entry] else { return true }
            return open.withdrawn || ledger.last > entry
        }
    }

    /// `connection`'s one chain for privacy clips (#735 S-8 HS-C round 3): entries (voice and device), their stops,
    /// and child refusals, in one total order. Taken under the caller's lock (round 4): the chain's own lock only
    /// creates a task, and is never held while taking the router's, so the order of the two is fixed.
    fileprivate static func clipChain(_ connection: UUID, in state: inout State) -> SerialTaskChain {
        if let chain = state.privacyClips[connection] { return chain }
        let chain = SerialTaskChain()
        state.privacyClips[connection] = chain
        return chain
    }

    /// Queues the clip `work` builds, given whether privacy is on, on `connection`'s chain, under the lock that reads it.
    func enqueuePrivacyClip(_ connection: UUID, _ work: (Bool) -> @Sendable () async -> Void) {
        state.withLock { state in
            Self.clipChain(connection, in: &state).enqueue(work(state.duck[connection] != nil))
        }
    }

    /// Registers `pipeline` with `connection`'s privacy entries, under the caller's lock (`register`), opening a
    /// recovery entry, queued on the chain, when it may restore privacy after "unavailable" (round 4).
    fileprivate func registerPrivacy(_ pipeline: RightyoAmbientPipeline, connection: UUID, in state: inout State) {
        let on = state.duck[connection] != nil
        guard on || state.privacy[connection] != nil else { return }
        let all = Self.children(of: connection, in: state)
        let recovery = state.privacy[connection, default: .init()].register(pipeline, duck: pipeline.privacyControl,
                                                                            at: privacyNow, on: on, all: all)
        guard let recovery else { return }
        let entry = AmbientPrivacyEntry(reported: 0, entry: recovery, wasOn: true, on: true)
        Self.clipChain(connection, in: &state).enqueue(entryClip(entry, outcome: "on=true reason=recovery",
                                                                 connection: connection,
                                                                 listener: state.listener?.value))
    }

    /// Closes privacy entry `entry` and decides it in one step under the router's lock (round 3), or says until when
    /// to wait (`AmbientPrivacyLedger.close`): no refusal lands between the answers read and the close, and no child
    /// registers or is swapped out meanwhile. A recovery entry its cap opened (round 5) is queued on the chain in that
    /// same step, after this entry's clip.
    func closePrivacyEntry(_ entry: Int, connection: UUID) -> AmbientPrivacyClose<RightyoAmbientPipeline> {
        let (now, bound) = (privacyNow, configuration.privacyBound)
        return state.withLock { state in
            let listening = Set(Self.listening(connection, in: state).map(ObjectIdentifier.init))
            let close = state.privacy[connection]?.close(entry, now: now, bound: bound) {
                listening.contains(ObjectIdentifier($0))
            } ?? .decided(.init(clip: nil, tokens: " withdrawn"))
            if case .decided(let decision) = close, let recovery = decision.recovery {
                let next = AmbientPrivacyEntry(reported: 0, entry: recovery, wasOn: true, on: true)
                Self.clipChain(connection, in: &state).enqueue(entryClip(next, outcome: "on=true reason=recovery",
                                                                         connection: connection,
                                                                         listener: state.listener?.value))
            }
            return close
        }
    }

    /// A refused child's `unavailable` (#822 A), from its privacy state `duck` (held strongly, round 4), or a start
    /// refused while private (`duck` nil): decided by the state rule (`AmbientPrivacyLedger.refusal`) and, when said,
    /// queued on the connection's clip chain, both under the router's lock; otherwise logged as the reason it is not.
    func announceRefusal(_ duck: AmbientDuckControl?, connection: UUID) {
        let silent = state.withLock { state -> String? in
            let on = state.duck[connection] != nil
            guard on || duck != nil else { return nil }
            let holders = Self.listening(connection, in: state).map(\.privacyControl)
            var ledger = state.privacy[connection] ?? .init()
            let (said, token) = ledger.refusal(of: duck, on: on, holders: holders)
            if on || state.privacy[connection] != nil { state.privacy[connection] = ledger }
            guard said else { return token }
            let listener = state.listener?.value
            Self.clipChain(connection, in: &state).enqueue { [weak self, weak listener] in
                await self?.sayPrivacy(AmbientStopConfirmation.privacyUnavailable, outcome: "unavailable",
                                       connection: connection, listener: listener)
            }
            return nil
        }
        if let silent { emit("ambient_privacy", connection: connection, detail: silent) }
    }

    /// The work that announces entry `entry` (`announceEntry`) and logs `outcome` with its tokens.
    func entryClip(_ entry: AmbientPrivacyEntry, outcome: String, connection: UUID,
                   listener: WebSocketListener?) -> @Sendable () async -> Void {
        { [weak self, weak listener] in
            guard let self else { return }
            let (clip, tokens) = await announceEntry(entry, connection: connection, listener: listener)
            await sayPrivacy(clip, outcome: outcome + tokens, connection: connection, listener: listener)
        }
    }

    /// Plays `persona` (nil: none) and logs `ambient_duck_confirmed` with `outcome` and the clip's token.
    func sayPrivacy(_ persona: String?, outcome: String, connection: UUID, listener: WebSocketListener?) async {
        var confirm = "unreported"
        if let persona { confirm = await confirmVoiceMute(persona, on: connection, listener: listener) }
        emit("ambient_duck_confirmed", connection: connection, detail: "\(outcome) confirm=\(confirm)")
    }

    /// Announces privacy entry `entry` on `connection` (round 3): waits for every child that still hears the stream,
    /// each within its own bound, then closes the entry and reads each child's answer in that one step
    /// (`closePrivacyEntry`). A clip is queued after a reply playing is stopped on the same chain, so the stop never
    /// cuts it. Returns the clip and the log tokens after `on=true`. Runs on the connection's clip chain.
    func announceEntry(_ entry: AmbientPrivacyEntry, connection: UUID,
                       listener: WebSocketListener?) async -> (String?, String) {
        guard let number = entry.entry else { return (nil, " withdrawn") }
        let decision = await decideEntry(number, connection: connection)
        for pipeline in decision.refused { await pipeline.killRefused() }
        guard let clip = decision.clip else { return (nil, decision.tokens) }
        let playback = await listener?.stopReplyPlayback(connection: connection) ?? "no_connection"
        return (clip, decision.tokens + " playback=\(playback)")
    }

    private func decideEntry(_ entry: Int, connection: UUID) async -> AmbientPrivacyDecision<RightyoAmbientPipeline> {
        while true {
            switch closePrivacyEntry(entry, connection: connection) {
            case .decided(let decision): return decision
            case .wait(let until):
                await waitForPrivacy(entry, connection: connection,
                                     until: privacyEpoch.advanced(by: .milliseconds(Int64(until * 1_000) + 1)))
            }
        }
    }

    /// Until every listening child answered (or an off withdrew the entry), or `deadline`.
    private func waitForPrivacy(_ entry: Int, connection: UUID, until deadline: ContinuousClock.Instant) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.awaitSettled(entry, connection: connection) }
            group.addTask { try? await Task.sleep(until: deadline) }
            defer { group.cancelAll() }
            await group.next()
        }
    }

    /// Waits until every child that still hears `connection`'s stream has answered, again after each answer, so a
    /// child a reload started meanwhile is waited for too; or until an off withdrew `entry`; or cancellation.
    private func awaitSettled(_ entry: Int?, connection: UUID) async {
        while !Task.isCancelled, !(entry.map { privacyWithdrawn($0, connection: connection) } ?? false),
              let next = listeningPipelines(connection: connection).first(where: { $0.privacySettled == nil }) {
            _ = await next.privacyAnswer()
        }
    }

    /// Whether every child that hears `connection`'s stream keeps the privacy wished for, once each answered (tests).
    func privacyKept(connection: UUID) async -> Bool {
        await awaitSettled(nil, connection: connection)
        let pipelines = listeningPipelines(connection: connection)
        return !pipelines.isEmpty && pipelines.allSatisfy { $0.privacySettled == .kept }
    }
}

/// An entry's verdict and announcement (#735 S-8 HS-C), for `AmbientPrivacyLedger.close`.
extension AmbientRightyoRouter {
    /// The entry's clip and log tokens, given its answer, whether it took over a refusal (claimed or carried), and
    /// whether privacy was already on: `confirm-privacy-on/` when kept (`superseded_by_keep` for a refusal it took
    /// over: a listening child still keeps privacy, so nothing changed); nothing when withdrawn (`superseded_by_off`
    /// for a refusal: "Recording again." is the last word); else `confirm-privacy-unavailable/`.
    static func announcement(_ answer: AmbientPrivacyAnswer, claimed: Bool, wasOn: Bool) -> (String?, String) {
        switch answer {
        case .kept:
            return (AmbientStopConfirmation.privacyOn,
                    (wasOn ? " still_on" : "") + (claimed ? " superseded_by_keep" : ""))
        case .withdrawn:
            return (nil, claimed ? " withdrawn claimed superseded_by_off" : " withdrawn")
        default:
            return (AmbientStopConfirmation.privacyUnavailable, " \(answer.token)")
        }
    }

    /// The entry's answer from its children's at the close (round 4, the state rule): withdrawn by an off; `timeout`
    /// when a bound refused one; then a refusal of a listening child; then the listening children, those that ended
    /// dropping out: all kept is `kept` (a refusal of a child that no longer listens changes nothing then); none left
    /// is a refusal it took over (its own reason, or `refused` when carried) or `ended`; else the first not kept.
    static func privacyVerdict(_ answers: [AmbientPrivacyChildAnswer], withdrawn: Bool,
                               carried: Bool = false) -> AmbientPrivacyAnswer {
        if withdrawn { return .withdrawn }
        if answers.contains(where: \.refusedAtBound) { return .timeout }
        let refusal = answers.first { child in
            guard case .refused = child.answer else { return false }
            return child.listening
        }
        if let refusal { return refusal.answer }
        let present = answers.filter { $0.listening && $0.answer != .ended }.map(\.answer)
        if let other = present.first(where: { $0 != .kept }) { return other }
        if !present.isEmpty { return .kept }
        if let claimed = answers.first(where: { $0.claimed }) { return claimed.answer }
        return carried ? .refused(nil) : .ended
    }
}

/// What `setDuck` changed: how many children took duck mode, how many took media mode's end when it left it, and
/// whether an entry no child took found duck mode already on.
private struct DuckChange {
    var duck: Int, media: Int?, still: Bool
    var wasOn = false, entry: Int?
}

/// The privacy state of the child a router closure belongs to, set once its pipeline exists (#822 A). Held strongly
/// (round 4): a refusal said after the pipeline is freed (a deadline task outlives it) still reads whether it was said,
/// and the state holds no pipeline, so nothing is kept alive.
final class AmbientRunMark: Sendable {
    private let held = Mutex<AmbientDuckControl?>(nil)

    func set(_ duck: AmbientDuckControl) { held.withLock { $0 = duck } }
    var duck: AmbientDuckControl? { held.withLock { $0 } }
}

/// Runs the work given to it one piece at a time, in the order given (#404): each piece starts only once the one
/// before has returned. `enqueue` returns at once.
final class SerialTaskChain: Sendable {
    private let last = Mutex<Task<Void, Never>?>(nil)

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        last.withLock { last in
            last = Task { [last] in
                await last?.value
                await work()
            }
        }
    }
}

extension AmbientRightyoRouter {
    /// Route lines are written here, in order, never on the gate's actor (rightyo#164).
    private static let routeLog = DispatchQueue(label: "hail.ambient.input-route")
    /// The route kinds RightyO accepts in `RIGHTYO_INPUT_ROUTE` (rightyo#172); anything else is passed as `other`.
    static let rightyoInputRoutes: Set<String> = [
        "none", "built_in_mic", "built_in_speaker", "built_in_receiver", "headphones", "headset_mic", "line_in",
        "line_out", "bluetooth_a2dp", "bluetooth_hfp", "bluetooth_le", "airplay", "hdmi", "car_audio", "usb_audio",
        "other"
    ]

    /// A device's ambient input route kind (rightyo#164), logged as a token with its connection (the id
    /// `ambient_started` carries too) so a speaker-ID mismatch can be attributed to an input chain and a stream, and
    /// kept for that connection's next child until it disconnects. A route that arrives after its child started is
    /// passed on the next start or reload. Keeping it is a dictionary write; the log line is only enqueued, so the
    /// gate's audio path never waits for the log or the status file.
    public func ambientInputRoute(_ route: String, connection: UUID) {
        state.withLock { $0.inputRoutes[connection] = route }
        Self.routeLog.async { [weak self] in
            self?.emit("ambient_input", connection: connection, detail: "route=\(route)")
        }
    }

    /// The child's opt-ins (rightyo#172): owner-voice events always, and the connection's input route kind when the
    /// device has named one.
    func childEnvironment(for connection: UUID) -> [String: String] {
        var environment = ["RIGHTYO_OWNER_VOICE_EVENTS": "1"]
        if let route = state.withLock({ $0.inputRoutes[connection] }) {
            environment["RIGHTYO_INPUT_ROUTE"] = Self.rightyoInputRoutes.contains(route) ? route : "other"
        }
        return environment
    }

    /// RightyO's owner-voice status for `connection`'s stream (rightyo#164), shown only on that device and only if it
    /// advertised `owner_voice_status`; logged as tokens only.
    /// Sends run one at a time in the order RightyO said them, so a device never sees `recognized` before
    /// `unrecognized`.
    fileprivate func ownerVoice(on connection: UUID, listener: WebSocketListener) -> @Sendable (String) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] state in
            chain.enqueue { [weak self, weak listener] in
                let sent = await listener?.showOwnerVoice(state, connection: connection) ?? "no_connection"
                self?.emit("ambient_owner_voice", connection: connection, detail: "state=\(state) device=\(sent)")
            }
        }
    }
}

extension WebSocketListener {
    /// Sends `owner_voice` (rightyo#164) to the connection whose stream it is: `sent`, `unsupported` (it did not
    /// advertise `owner_voice_status`), `failed` or `no_connection`.
    func showOwnerVoice(_ state: String, connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard let frame = await peer.session.ownerVoiceFrame(state) else { return "unsupported" }
        return await peer.post(frame) ? "sent" : "failed"
    }
}

extension HostSession {
    /// The owner-voice status (rightyo#164) for a ready device that advertised `owner_voice_status`; nil otherwise,
    /// since an older device refuses an unknown command.
    func ownerVoiceFrame(_ state: String) -> Frame? {
        guard case .ready(let version) = self.state, peerCapabilities.contains(OwnerVoice.capability),
              OwnerVoice.state(state) != nil else { return nil }
        return response(.ownerVoice(state: state), version: version)
    }
}

#endif
