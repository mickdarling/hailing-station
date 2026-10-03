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

    /// Bumped on every target selection, per host, so an ambient stream ends on any target change (#203).
    private var selectionSerials: [HostEndpoint.Identifier: UInt64] = [:]

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
        selectionSerials[id, default: 0] &+= 1
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.selectTarget(targetID)
    }
    public func sendFinalText(_ text: String, host id: HostEndpoint.Identifier, targetID: String) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendFinalText(text, to: targetID)
    }
    public func sendEscape(host id: HostEndpoint.Identifier, targetID: String) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendEscape(to: targetID)
    }
    /// The ambient binding for a destination, or nil unless the host is ready and advertises `stream_audio`.
    public func ambientBinding(host id: HostEndpoint.Identifier, targetID: String) -> AmbientAudioBinding? {
        guard let snapshot = snapshots[id], snapshot.state == .ready,
              snapshot.capabilities.contains(HostConnection.streamAudioCapability) else { return nil }
        return AmbientAudioBinding(
            hostID: id, targetID: targetID, connectionGeneration: snapshot.connectionGeneration,
            selection: selectionSerials[id, default: 0]
        )
    }

    /// Sends one ambient segment to the host the binding names (#203). A reconnect or any target selection on
    /// that host since the binding was taken makes every further segment throw, so the streamer releases the mic.
    public func sendAudio(_ audio: AudioPayload, to binding: AmbientAudioBinding) async throws {
        guard ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding,
              let connection = connections[binding.hostID] else { throw HostConnectionFailure.notReady }
        try await connection.sendAudio(audio)
    }
    public func remove(_ id: HostEndpoint.Identifier) async {
        tokens[id] = nil
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

    private func receive(_ snapshot: HostConnectionSnapshot, token: UUID) {
        guard tokens[snapshot.id] == token else { return }
        snapshots[snapshot.id] = snapshot
    }

    private func receive(_ event: HostReplyEvent, token: UUID) {
        guard tokens[event.endpointID] == token else { return }
        replyFrames.append(event)
        if replyFrames.count > Self.replyFrameLimit {
            replyFrames.removeFirst(replyFrames.count - Self.replyFrameLimit)
        }
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

/// The "Ambient listening" toggle (#203). Off on every launch and never restarts by itself: leaving the
/// foreground, a binding change (target, reconnect), a send failure or the microphone ending turns it off, and
/// the user must turn it on again. Audio is never logged; `stopReason` carries only the cause.
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
    public private(set) var isListening = false
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

    public init(
        requestPermission: @escaping @MainActor () async -> Bool,
        makeStreamer: @escaping MakeStreamer,
        releaseSession: @escaping @MainActor () async -> Void,
        send: @escaping Send
    ) {
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
        self.binding = binding
        // The permission alert makes the scene inactive, so only leaving for the background cancels here.
        awaitingPermission = true
        let granted = await requestPermission()
        awaitingPermission = false
        guard session == current else { return }
        guard granted else {
            return await end(current, reason: "Microphone access is off. Allow it in Settings to listen.")
        }
        if scene == .active { await start(current) } else { pendingStart = true }
    }

    public func turnOff() async { await end(session, reason: nil) }

    /// Called on every scene or binding change. Streaming runs only in the foreground for the binding it began
    /// with; anything else ends it.
    public func update(binding current: AmbientAudioBinding?, scene: AmbientScene) async {
        let previous = self.scene
        self.scene = scene
        guard isOn else { return }
        if current != binding {
            return await end(session, reason: "Stopped: the destination or connection changed.")
        }
        switch scene {
        case .active where pendingStart:
            pendingStart = false
            await start(session)
        case .active:
            break
        case .inactive where awaitingPermission || (pendingStart && previous == .inactive):
            break
        case .inactive, .background:
            await end(session, reason: "Stopped: Hailing Station left the foreground.")
        }
    }

    private func start(_ current: UUID) async {
        guard let binding else { return }
        let send = send
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
                await releaseSession()
                return await end(current, reason: "Stopped: Hailing Station left the foreground.")
            }
            try streamer.start()
            self.streamer = streamer
            isListening = true
            watch(streamer, session: current)
        } catch {
            await releaseSession()
            await end(current, reason: "Could not start listening: \(Self.describe(error))")
        }
    }

    private func watch(_ streamer: AmbientAudioStreamer, session current: UUID) {
        let streaming = withObservationTracking { streamer.isStreaming } onChange: { [weak self] in
            Task { @MainActor in self?.watch(streamer, session: current) }
        }
        guard !streaming, session == current else { return }
        Task { await end(current, reason: sendFailure ?? "Stopped: the microphone ended.") }
    }

    private func recordSendFailure(_ error: any Error, session current: UUID) {
        guard session == current, sendFailure == nil else { return }
        sendFailure = "Stopped: \(Self.describe(error))"
    }

    private func end(_ current: UUID, reason: String?) async {
        guard session == current, isOn else { return }
        session = UUID()
        isOn = false
        isListening = false
        pendingStart = false
        awaitingPermission = false
        stopReason = reason
        binding = nil
        guard let streamer else { return }
        self.streamer = nil
        await streamer.stop()
        await releaseSession()
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case HostConnectionFailure.notReady: "the connection changed."
        case HostConnectionFailure.unsupportedCapability: "this Mac does not accept ambient audio."
        case HostConnectionFailure.remote(let message): "the Mac ended listening (\(message))."
        case HostConnectionFailure.malformed(let message): "\(message)."
        default: error.localizedDescription
        }
    }
}
