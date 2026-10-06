// swiftlint:disable file_length
public import Foundation
public import HailProtocol
public import Observation
/// Main-actor model for the UI. Every endpoint owns a separate actor and a separate stale-callback token.
@MainActor
@Observable
public final class HostConnectionStore {
    public static let replyFrameLimit = 256
    public private(set) var snapshots: [HostEndpoint.Identifier: HostConnectionSnapshot] = [:]
    public private(set) var order: [HostEndpoint.Identifier] = []
    /// A bounded ingress history for the playback coordinator. Audio is not associated by arrival order;
    /// consumers group these frames by the reply and stream identities carried in every frame.
    public private(set) var replyFrames: [HostReplyEvent] = []
    /// Called for every reply frame as it arrives, so replies reach the player while the app is in the background,
    /// when SwiftUI view updates such as `onChange` may not run (#282).
    @ObservationIgnored public var onReplyFrame: (@MainActor (HostReplyEvent) -> Void)?
    /// True while ambient listening is streaming; leaving the foreground then keeps the destination authorized (#282).
    public var ambientStreaming = false

    /// Bumped on every target selection, per host, so an ambient stream ends on any target change (#203).
    private var selectionSerials: [HostEndpoint.Identifier: UInt64] = [:]
    /// The target each host last confirmed through `selectTarget`, the one its connection addresses audio to.
    /// Ambient bindings exist only for it (#218).
    private var selectedTargets: [HostEndpoint.Identifier: String] = [:]

    @ObservationIgnored private var connections: [HostEndpoint.Identifier: HostConnection] = [:]
    @ObservationIgnored private var tokens: [HostEndpoint.Identifier: UUID] = [:]
    @ObservationIgnored private var retiredBarriers: [HostEndpoint.Identifier: Task<Void, Never>] = [:]
    @ObservationIgnored private let connector: any WebSocketConnecting
    @ObservationIgnored private let schedule: ReconnectSchedule
    @ObservationIgnored private let pongTimeout: Duration
    @ObservationIgnored private let negotiationTimeout: Duration
    @ObservationIgnored private let deadlineSleep: HostConnection.Sleep
    @ObservationIgnored private let negotiationScheduler: HostConnection.DeadlineScheduler?
    @ObservationIgnored private let monotonicNow: HostConnection.MonotonicNow
    @ObservationIgnored private let wallNow: HostConnection.WallNow
    @ObservationIgnored private let sleep: HostConnection.Sleep
    @ObservationIgnored private let jitter: HostConnection.Jitter
    @ObservationIgnored private var diagnosticsFlush: Task<Void, Never>?
    /// The device diagnostics log (#234). Connection changes are recorded into it, and its batches go to the first
    /// ready host that advertises `device_diagnostics`; none goes anywhere else. Nil records and sends nothing.
    @ObservationIgnored public var diagnostics: DeviceDiagnostics? {
        didSet {
            diagnostics?.onPending = { [weak self] in self?.scheduleDiagnosticsFlush() }
            scheduleDiagnosticsFlush()
        }
    }

    public var hosts: [HostConnectionSnapshot] { order.compactMap { snapshots[$0] } }
    public init(
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        schedule: ReconnectSchedule = ReconnectSchedule(),
        pongTimeout: Duration = .seconds(5),
        negotiationTimeout: Duration = .seconds(10),
        deadlineSleep: @escaping HostConnection.Sleep = { try await Task.sleep(for: $0) },
        negotiationScheduler: HostConnection.DeadlineScheduler? = nil,
        monotonicNow: @escaping HostConnection.MonotonicNow = { ContinuousClock().now },
        wallNow: @escaping HostConnection.WallNow = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        sleep: @escaping HostConnection.Sleep = { try await Task.sleep(for: $0) },
        jitter: @escaping HostConnection.Jitter = { Double.random(in: 0...1) }
    ) {
        self.connector = connector
        self.schedule = schedule
        self.pongTimeout = pongTimeout
        self.negotiationTimeout = negotiationTimeout
        self.deadlineSleep = deadlineSleep
        self.negotiationScheduler = negotiationScheduler
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleep = sleep
        self.jitter = jitter
    }
    public func upsert(_ endpoint: HostEndpoint) async {
        if snapshots[endpoint.id]?.endpoint == endpoint { return }
        let existing = connections.removeValue(forKey: endpoint.id)
        forgetSelection(endpoint.id)
        let retainedBarrier = retiredBarriers.removeValue(forKey: endpoint.id)
        tokens[endpoint.id] = nil
        let inheritedBarrier = existing.map(drainingTransportBarrier(for:)) ?? retainedBarrier
        let connectionConnector = inheritedBarrier.map { barrier -> any WebSocketConnecting in
            SerializedWebSocketConnector(predecessor: barrier, base: connector)
        } ?? connector
        let token = UUID()
        tokens[endpoint.id] = token
        snapshots[endpoint.id] = HostConnectionSnapshot(endpoint: endpoint)
        if !order.contains(endpoint.id) { order.append(endpoint.id) }
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connectionConnector,
            schedule: schedule,
            pongTimeout: pongTimeout,
            negotiationTimeout: negotiationTimeout,
            deadlineSleep: deadlineSleep,
            negotiationScheduler: negotiationScheduler,
            monotonicNow: monotonicNow,
            wallNow: wallNow,
            sleep: sleep,
            jitter: jitter
        ) { [weak self] snapshot in
            await self?.receive(snapshot, token: token)
        } replyObserver: { [weak self] event in
            await self?.receive(event, token: token)
        }
        connections[endpoint.id] = connection
    }
    public func connect(_ id: HostEndpoint.Identifier) async { await connections[id]?.connect() }
    public func disconnect(_ id: HostEndpoint.Identifier) async { await connections[id]?.disconnect() }
    public func selectTarget(host id: HostEndpoint.Identifier, targetID: String) async throws {
        forgetSelection(id)
        let serial = selectionSerials[id]
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.selectTarget(targetID)
        // A later selection, endpoint change or removal owns the outcome.
        if selectionSerials[id] == serial, connections[id] === connection { selectedTargets[id] = targetID }
    }
    public func sendFinalText(_ text: String, host id: HostEndpoint.Identifier, targetID: String) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendFinalText(text, to: targetID)
    }
    public func sendEscape(host id: HostEndpoint.Identifier, targetID: String) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendEscape(to: targetID)
    }
    /// The ambient binding for a destination, or nil unless the host is ready, advertises `stream_audio`, and
    /// `targetID` is the target its connection has confirmed: the connection addresses every segment to that
    /// selection, so a binding for any other target would misstate where audio goes (#218).
    public func ambientBinding(host id: HostEndpoint.Identifier, targetID: String) -> AmbientAudioBinding? {
        guard selectedTargets[id] == targetID, let snapshot = snapshots[id], snapshot.state == .ready,
              snapshot.capabilities.contains(HostConnection.streamAudioCapability) else { return nil }
        return AmbientAudioBinding(
            hostID: id, targetID: targetID, connectionGeneration: snapshot.connectionGeneration,
            selection: selectionSerials[id, default: 0]
        )
    }

    /// Sends one ambient segment to the host and target the binding names (#203). The binding is authoritative:
    /// it must still be the current one for the connection's confirmed target, so a reconnect, an endpoint change
    /// or any target selection since it was taken makes every further segment throw and the streamer releases
    /// the mic.
    public func sendAudio(_ audio: AudioPayload, to binding: AmbientAudioBinding) async throws {
        guard ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding,
              let connection = connections[binding.hostID] else { throw HostConnectionFailure.notReady }
        try await connection.sendAudio(audio)
    }
    public func remove(_ id: HostEndpoint.Identifier) async {
        tokens[id] = nil
        forgetSelection(id)
        let connection = connections.removeValue(forKey: id)
        let barrier = connection.map(drainingTransportBarrier(for:)) ?? retiredBarriers[id]
        if let barrier { retiredBarriers[id] = barrier }
        snapshots[id] = nil
        order.removeAll { $0 == id }
    }
    /// Active hosts are pinged; hosts already trying to recover skip their backoff and reconnect now.
    public func sceneBecameActive() async {
        for id in order {
            await connections[id]?.foregrounded()
        }
    }

    /// Every selection change, endpoint change or removal invalidates outstanding bindings for the host.
    private func forgetSelection(_ id: HostEndpoint.Identifier) {
        selectionSerials[id, default: 0] &+= 1
        selectedTargets[id] = nil
    }

    private func receive(_ snapshot: HostConnectionSnapshot, token: UUID) {
        guard tokens[snapshot.id] == token else { return }
        let previous = snapshots[snapshot.id]?.state
        snapshots[snapshot.id] = snapshot
        recordDiagnostics(from: previous, to: snapshot.state)
    }

    private func receive(_ event: HostReplyEvent, token: UUID) {
        guard tokens[event.endpointID] == token else { return }
        replyFrames.append(event)
        onReplyFrame?(event)
        if replyFrames.count > Self.replyFrameLimit {
            replyFrames.removeFirst(replyFrames.count - Self.replyFrameLimit)
        }
    }
}

/// Device diagnostics (#234): recording connection changes and sending batches.
extension HostConnectionStore {
    /// Each change of connection state, with the reconnect attempt; reaching ready also records `app_info`, so
    /// every host session starts with the build, and sends what was buffered while offline.
    func recordDiagnostics(from previous: HostConnectionState?, to state: HostConnectionState) {
        guard let diagnostics, previous.map(Self.stateToken) != Self.stateToken(state) else { return }
        var fields: [DiagnosticField: DiagnosticValue] = [.state: .token(Self.stateToken(state))]
        if case .reconnecting(let attempt, _) = state { fields[.attempt] = .integer(Int64(attempt)) }
        diagnostics.record(.connectionState, fields)
        if state == .ready {
            diagnostics.record(.appInfo, DeviceDiagnostics.appInfo())
            scheduleDiagnosticsFlush(after: .zero)
        }
    }

    /// True when some ready host advertises `device_diagnostics`, so the toggle can say whether anyone collects.
    public var diagnosticsCollectingHost: HostConnectionSnapshot? {
        hosts.first { $0.state == .ready && $0.capabilities.contains(DiagnosticLimits.capability) }
    }

    static func stateToken(_ state: HostConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .negotiating: "negotiating"
        case .ready: "ready"
        case .reconnecting: "reconnecting"
        case .failed: "failed"
        }
    }

    /// One pending send at a time. Each sends the batch the log's budget allows to the first collecting host,
    /// then reschedules while anything remains; a failed send puts the batch back for the next connection.
    func scheduleDiagnosticsFlush(after delay: Duration = .seconds(2)) {
        guard diagnosticsFlush == nil, diagnostics?.hasPending == true, diagnosticsCollectingHost != nil else { return }
        let sleep = sleep
        diagnosticsFlush = Task { [weak self] in
            try? await sleep(delay)
            await self?.flushDiagnostics()
        }
    }

    private func flushDiagnostics() async {
        diagnosticsFlush = nil
        guard let diagnostics, let host = diagnosticsCollectingHost, let connection = connections[host.id] else {
            return
        }
        guard let batch = diagnostics.nextBatch() else {
            if diagnostics.hasPending { scheduleDiagnosticsFlush(after: .seconds(5)) }
            return
        }
        // The toggle's promise: once logging is off, nothing taken before is sent or requeued.
        guard diagnostics.isCurrent(batch) else { return }
        do {
            try await connection.sendDiagnostics(batch.events)
        } catch {
            diagnostics.requeue(batch)
            return
        }
        scheduleDiagnosticsFlush()
    }
}

/// One destination's ambient-listening identity: host, target, socket generation and selection serial. Any change
/// is a different binding, and the store refuses segments for a stale one.
public struct AmbientAudioBinding: Hashable, Sendable {
    public let hostID: HostEndpoint.Identifier
    public let targetID: String
    public let connectionGeneration: UUID
    let selection: UInt64
}

/// Scene state as the ambient toggle needs it; the app maps SwiftUI's `ScenePhase` onto it.
public enum AmbientScene: Sendable { case active, inactive, background }

/// The "Ambient listening" toggle (#203). Off on every launch and never restarts by itself: a binding change
/// (target, reconnect), a send failure or the microphone ending turns it off, and the user must turn it on again.
/// Once streaming, it keeps running when the app leaves the foreground (#282); it only starts in the foreground.
/// Audio is never logged; `stopReason` carries only the cause.
@MainActor
@Observable
public final class AmbientListeningController {
    public typealias Send = @Sendable (AudioPayload, AmbientAudioBinding) async throws -> Void
    /// Activates the audio session and builds a streamer around `send`; the controller starts it.
    public typealias MakeStreamer = @MainActor (@escaping AmbientAudioStreamer.Send) async throws
        -> AmbientAudioStreamer

    /// The toggle: true from the user's request until any stop.
    public private(set) var isOn = false
    /// True only while microphone audio is actually streaming.
    public private(set) var isListening = false {
        didSet { if isListening != oldValue { onListeningChange?(isListening) } }
    }
    /// Told whenever `isListening` changes, without a view update, so state that must hold in the background
    /// (the kept destination authorization, #282) follows it there too.
    @ObservationIgnored public var onListeningChange: (@MainActor (Bool) -> Void)?
    public private(set) var stopReason: String?
    public private(set) var binding: AmbientAudioBinding?

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let requestPermission: @MainActor () async -> Bool
    @ObservationIgnored private let makeStreamer: MakeStreamer
    @ObservationIgnored private let releaseSession: @MainActor () async -> Void
    @ObservationIgnored private var streamer: AmbientAudioStreamer?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var scene = AmbientScene.active
    @ObservationIgnored private var awaitingPermission = false
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var sendFailure: String?
    /// The send failure's cause as a token (`host_refused` with the host's code, or `send_failed`) for diagnostics.
    @ObservationIgnored private var sendFailureCause: (cause: String, code: String?)?
    /// The device diagnostics log (#234): ambient start, stop with its cause, and host refusals. Never audio.
    @ObservationIgnored public var diagnostics: DeviceDiagnostics?
    /// The session that most recently began activating the audio session. Only it may release the audio session,
    /// so a slow teardown of an earlier session cannot deactivate the one a fast off→on started (#218).
    @ObservationIgnored private var activation: UUID?
    /// The release in flight, if any; a new activation waits for it so the two never interleave.
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Watches for capture ended by the system, so the toggle drops before queued audio finishes draining.
    @ObservationIgnored private var systemEndObserver: (any NSObjectProtocol)?

    /// `notificationCenter` is where capture posts `AVAudioEngineCapture.endedBySystem`.
    public init(
        notificationCenter: NotificationCenter = .default,
        requestPermission: @escaping @MainActor () async -> Bool,
        makeStreamer: @escaping MakeStreamer,
        releaseSession: @escaping @MainActor () async -> Void,
        send: @escaping Send
    ) {
        self.notificationCenter = notificationCenter
        self.requestPermission = requestPermission
        self.makeStreamer = makeStreamer
        self.releaseSession = releaseSession
        self.send = send
    }

    public func turnOn(for binding: AmbientAudioBinding) async {
        guard !isOn, scene == .active else { return }
        let current = UUID()
        session = current
        isOn = true
        stopReason = nil
        sendFailure = nil
        sendFailureCause = nil
        self.binding = binding
        // The permission alert makes the scene inactive, so only leaving for the background cancels here.
        awaitingPermission = true
        let granted = await requestPermission()
        awaitingPermission = false
        guard session == current else { return }
        guard granted else {
            return await end(current, reason: "Microphone access is off. Allow it in Settings to listen.",
                             cause: "permission_denied")
        }
        if scene == .active { await start(current) } else { pendingStart = true }
    }

    public func turnOff() async { await end(session, reason: nil, cause: "user") }

    /// Called on every scene or binding change. Streaming starts only in the foreground, for the binding it began
    /// with. A running stream survives the background (#282); one not yet started ends there, and any binding
    /// change ends it.
    public func update(binding current: AmbientAudioBinding?, scene: AmbientScene) async {
        let previous = self.scene
        self.scene = scene
        guard isOn else { return }
        if current != binding {
            return await end(session, reason: "Stopped: the destination or connection changed.",
                             cause: "binding_changed")
        }
        switch scene {
        case .active where pendingStart:
            pendingStart = false
            await start(session)
        case .active:
            break
        case .inactive where awaitingPermission || (pendingStart && previous == .inactive):
            break
        case .inactive where isListening, .background where isListening:
            break
        case .inactive, .background:
            await end(session, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
        }
    }

    private func start(_ current: UUID) async {
        guard let binding else { return }
        let send = send
        await pendingRelease?.value
        guard session == current, scene == .active else {
            return await end(current, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
        }
        activation = current
        do {
            let streamer = try await makeStreamer { [weak self] payload in
                do {
                    try await send(payload, binding)
                } catch {
                    await self?.recordSendFailure(error, session: current)
                    throw error
                }
            }
            guard session == current, scene == .active else {
                await release(current)
                return await end(current, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
            }
            try streamer.start()
            self.streamer = streamer
            isListening = true
            diagnostics?.record(.ambientStart)
            observeSystemEnd(session: current)
            watch(streamer, session: current)
        } catch {
            await release(current)
            await end(current, reason: "Could not start listening: \(Self.describe(error))", cause: "start_failed")
        }
    }

    private func watch(_ streamer: AmbientAudioStreamer, session current: UUID) {
        let streaming = withObservationTracking { streamer.isStreaming } onChange: { [weak self] in
            Task { @MainActor in self?.watch(streamer, session: current) }
        }
        guard !streaming, session == current else { return }
        Task {
            await end(current, reason: sendFailure ?? "Stopped: the microphone was interrupted or ended.",
                      cause: sendFailureCause?.cause ?? "capture_ended", code: sendFailureCause?.code)
        }
    }

    private func recordSendFailure(_ error: any Error, session current: UUID) {
        guard session == current, sendFailure == nil else { return }
        sendFailure = "Stopped: \(Self.describe(error))"
        sendFailureCause = Self.diagnosticCause(error)
        if let code = sendFailureCause?.code { diagnostics?.record(.hostRefusal, [.code: .token(code)]) }
    }

    private func end(_ current: UUID, reason: String?, cause: String, code: String? = nil) async {
        guard session == current, isOn else { return }
        var fields: [DiagnosticField: DiagnosticValue] = [.reason: .token(cause)]
        if let code { fields[.code] = .token(code) }
        diagnostics?.record(.ambientStop, fields)
        session = UUID()
        isOn = false
        isListening = false
        pendingStart = false
        awaitingPermission = false
        stopReason = reason
        binding = nil
        if let systemEndObserver {
            notificationCenter.removeObserver(systemEndObserver)
            self.systemEndObserver = nil
        }
        guard let streamer else { return }
        self.streamer = nil
        await streamer.stop()
        await release(current)
    }
}

extension AmbientListeningController {
    /// Releases the audio session for `owner` unless a newer session has begun activating it since.
    private func release(_ owner: UUID) async {
        guard activation == owner else { return }
        activation = nil
        let releaseSession = releaseSession
        let task = Task { @MainActor in await releaseSession() }
        pendingRelease = task
        await task.value
    }

    static let interruptedReason = "Stopped: a call, Siri or an audio route change interrupted the microphone."

    /// A call, Siri or a route change ended capture: turn off now rather than after the backlog drains (#218).
    private func observeSystemEnd(session current: UUID) {
        systemEndObserver = notificationCenter.addObserver(
            forName: AVAudioEngineCapture.endedBySystem, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.end(current, reason: Self.interruptedReason, cause: "system_interruption")
            }
        }
    }

    /// A host refusal carries its `ErrorCode` before the colon (`HostConnectionFailure.remote("code: message")`).
    static func diagnosticCause(_ error: any Error) -> (cause: String, code: String?) {
        guard case HostConnectionFailure.remote(let message) = error else { return ("send_failed", nil) }
        let code = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let known = DiagnosticField.code.tokens.contains { DiagnosticLimits.sameBytes($0, code) }
        return ("host_refused", known ? code : "other")
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case HostConnectionFailure.notReady: "the connection changed."
        case HostConnectionFailure.unsupportedCapability: "this host does not accept ambient audio."
        case HostConnectionFailure.remote(let message): "the host ended listening (\(message))."
        case HostConnectionFailure.malformed(let message): "\(message)."
        default: error.localizedDescription
        }
    }
}
