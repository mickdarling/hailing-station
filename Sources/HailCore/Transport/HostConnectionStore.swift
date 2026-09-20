public import Foundation
import HailProtocol
public import Observation
/// Main-actor model for the UI. Every endpoint owns a separate actor and a separate stale-callback token.
@MainActor
@Observable
public final class HostConnectionStore {
    public private(set) var snapshots: [HostEndpoint.Identifier: HostConnectionSnapshot] = [:]
    public private(set) var order: [HostEndpoint.Identifier] = []

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
        }
        connections[endpoint.id] = connection
    }
    public func connect(_ id: HostEndpoint.Identifier) async { await connections[id]?.connect() }
    public func disconnect(_ id: HostEndpoint.Identifier) async { await connections[id]?.disconnect() }
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
}

extension HostConnection {
    func negotiate(
        on opened: any WebSocketTransport, token: UInt64
    ) async throws -> (version: Int, capabilities: [String]) {
        try await send(
            .hello(HelloInfo(
                versions: VersionNegotiation.supported,
                capabilities: ["connectivity_lab"],
                deviceName: deviceName
            )),
            generation: token
        )
        let data = try await opened.receive()
        guard isCurrent(token) else { throw CancellationError() }
        let frame: Frame
        do { frame = try FrameCoding.decode(data) } catch {
            throw HostConnectionFailure.malformed("host hello is malformed")
        }
        guard case .control(.hello(let info)) = frame.payload,
              let version = VersionNegotiation.choose(offered: info.versions),
              frame.version == version else {
            throw HostConnectionFailure.incompatibleVersion
        }
        return (version, info.capabilities)
    }

    func process(_ data: Data, generation token: UInt64) async throws {
        let frame: Frame
        do { frame = try FrameCoding.decode(data) } catch {
            throw HostConnectionFailure.malformed("host frame is malformed")
        }
        guard frame.version == snapshot.negotiatedVersion else {
            throw HostConnectionFailure.incompatibleVersion
        }
        guard case .control(let control) = frame.payload else {
            throw HostConnectionFailure.malformed("unexpected non-control frame")
        }
        switch control {
        case .pong(let nonce):
            guard let began = pendingPings.removeValue(forKey: nonce) else { return }
            let elapsed = began.duration(to: monotonicNow()).components
            snapshot.lastPingMilliseconds = (Double(elapsed.seconds) * 1_000)
                + (Double(elapsed.attoseconds) / 1_000_000_000_000_000)
            await observer(snapshot)
        case .targets(let targets):
            snapshot.targets = targets
            snapshot.receivedTargetList = true
            await observer(snapshot)
        case .error(let code, let message):
            throw HostConnectionFailure.remote("\(code.rawValue): \(message)")
        default:
            throw HostConnectionFailure.malformed("unexpected control frame")
        }
    }

    func sendPing(generation token: UInt64, requiresDeadline: Bool = false) async throws {
        let nonce = UUID().uuidString.lowercased()
        pendingPings[nonce] = monotonicNow()
        do { try await send(.ping(nonce: nonce), generation: token) } catch {
            pendingPings.removeValue(forKey: nonce)
            throw error
        }
        if requiresDeadline { schedulePongDeadline(nonce: nonce, generation: token) }
    }

    func schedulePongDeadline(nonce: String, generation token: UInt64) {
        Task { [weak self, pongTimeout, deadlineSleep] in
            do { try await deadlineSleep(pongTimeout) } catch { return }
            await self?.pongTimedOut(nonce: nonce, generation: token)
        }
    }

    func pongTimedOut(nonce: String, generation token: UInt64) async {
        guard isCurrent(token), wantsConnection,
              pendingPings.removeValue(forKey: nonce) != nil else { return }
        await replaceLoop()
    }

    func send(_ control: ControlPayload, generation token: UInt64) async throws {
        guard isCurrent(token), let socket else { throw CancellationError() }
        let frame = Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
            timestamp: wallNow(),
            source: "terminal",
            payload: .control(control)
        )
        try await socket.send(FrameCoding.encode(frame))
    }

    func isCurrent(_ token: UInt64) -> Bool { token == generation }
    func publish(_ state: HostConnectionState, token: UInt64? = nil) async {
        guard token == nil || token == generation else { return }
        snapshot.state = state
        await observer(snapshot)
    }
}
