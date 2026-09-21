public import Foundation
import Dispatch
import HailProtocol

public enum HostConnectionFailure: Error, Equatable, Sendable {
    case malformed(String)
    case incompatibleVersion
    case remote(String)
    case notReady
    case unsupportedCapability(String)
}

/// Owns exactly one endpoint's socket lifecycle. Generation checks make callbacks from replaced sockets inert.
public actor HostConnection {
    public static let subprotocolName = "hail.v1"
    public typealias Observer = @Sendable (HostConnectionSnapshot) async -> Void
    public typealias ReplyObserver = @Sendable (HostReplyEvent) async -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Jitter = @Sendable () -> Double
    public typealias DeadlineScheduler = @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
    public typealias MonotonicNow = @Sendable () -> ContinuousClock.Instant
    public typealias WallNow = @Sendable () -> Int64

    let connector: any WebSocketConnecting
    let schedule: ReconnectSchedule
    let deviceName: String
    let sleep: Sleep
    let jitter: Jitter
    let observer: Observer
    let replyObserver: ReplyObserver
    let pongTimeout: Duration
    let negotiationTimeout: Duration
    let deadlineSleep: Sleep
    let negotiationScheduler: DeadlineScheduler
    let monotonicNow: MonotonicNow
    let wallNow: WallNow

    var snapshot: HostConnectionSnapshot
    var socket: (any WebSocketTransport)?
    var loopTask: Task<Void, Never>?
    var transportBarrier: Task<Void, Never>?
    var openingGeneration: UInt64?
    var negotiationStartedAt: ContinuousClock.Instant?
    var negotiationReconnectAttempt: Int?
    var negotiationDeadlineID: UInt64 = 0
    var generation: UInt64 = 0
    var wantsConnection = false
    var pendingPings: [String: ContinuousClock.Instant] = [:]
    public init(
        endpoint: HostEndpoint,
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        schedule: ReconnectSchedule = ReconnectSchedule(),
        deviceName: String = "hail terminal",
        pongTimeout: Duration = .seconds(5),
        negotiationTimeout: Duration = .seconds(10),
        deadlineSleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        negotiationScheduler: DeadlineScheduler? = nil,
        monotonicNow: @escaping MonotonicNow = { ContinuousClock().now },
        wallNow: @escaping WallNow = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        jitter: @escaping Jitter = { Double.random(in: 0...1) },
        observer: @escaping Observer = { _ in },
        replyObserver: @escaping ReplyObserver = { _ in }
    ) {
        self.snapshot = HostConnectionSnapshot(endpoint: endpoint)
        self.connector = connector
        self.schedule = schedule
        self.deviceName = deviceName
        self.pongTimeout = pongTimeout
        self.negotiationTimeout = negotiationTimeout
        self.deadlineSleep = deadlineSleep
        self.negotiationScheduler = negotiationScheduler ?? { duration, action in
            let parts = duration.components
            let seconds = max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: action)
        }
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleep = sleep
        self.jitter = jitter
        self.observer = observer
        self.replyObserver = replyObserver
    }

    public func currentSnapshot() -> HostConnectionSnapshot { snapshot }

    public func selectTarget(_ targetID: String) async throws {
        try requireReady(capability: "select_target")
        try await send(.select(targetID: targetID), generation: generation)
    }

    public func sendFinalText(_ text: String, to targetID: String) async throws {
        try requireReady(capability: "send_text")
        let frame = Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
            timestamp: wallNow(), target: targetID, source: deviceName,
            payload: .text(TextPayload(text: text, isFinal: true))
        )
        guard let socket else { throw HostConnectionFailure.notReady }
        try await socket.send(FrameCoding.encode(frame))
    }

    public func sendEscape(to targetID: String) async throws {
        try requireReady(capability: "escape")
        try await send(.escape(targetID: targetID), generation: generation)
    }

    public func connect() async {
        wantsConnection = true
        switch snapshot.state {
        case .connecting, .negotiating, .ready, .reconnecting: return
        case .disconnected, .failed: await replaceLoop()
        }
    }

    public func disconnect() async {
        _ = await beginDisconnect()
    }

    private func requireReady(capability: String) throws {
        guard snapshot.state == .ready, socket != nil else { throw HostConnectionFailure.notReady }
        guard snapshot.capabilities.contains(capability) else {
            throw HostConnectionFailure.unsupportedCapability(capability)
        }
    }

    func retire() async -> Task<Void, Never> {
        let localBarrier = await beginDisconnect()
        guard let predecessor = (connector as? SerializedWebSocketConnector)?.predecessor else {
            return localBarrier
        }
        return Task {
            await predecessor.value
            await localBarrier.value
        }
    }

    private func beginDisconnect() async -> Task<Void, Never> {
        wantsConnection = false
        generation &+= 1
        let token = generation
        loopTask?.cancel()
        cancelNegotiationDeadline()
        let handoff = beginTransportHandoff()
        clearSocketDiagnostics()
        await publish(.disconnected, token: token)
        return handoff
    }

    /// Called when the app becomes active. Healthy sockets get a ping; reconnect waits are skipped immediately.
    public func foregrounded() async {
        guard wantsConnection else { return }
        switch snapshot.state {
        case .ready:
            do {
                try await sendPing(generation: generation, requiresDeadline: true)
            } catch {
                await replaceLoop()
            }
        case .connecting, .negotiating:
            if negotiationHasExpired() { await replaceLoop() }
        case .disconnected, .reconnecting, .failed:
            await replaceLoop()
        }
    }
}
