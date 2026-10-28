// swiftlint:disable file_length
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
    /// Advertised only when the host's ambient-listening flags are set (#203).
    public static let streamAudioCapability = "stream_audio"
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
    private let injectedSleep: Sleep
    let jitter: Jitter
    let observer: Observer
    let replyObserver: ReplyObserver
    let reportsAmbientRefusals: Bool
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
    var reconnectPacing: (@Sendable () async -> AmbientReconnectPacing?)?
    var ambientPacing: AmbientReconnectPacing?
    var pendingPings: [String: ContinuousClock.Instant] = [:]
    var desiredTargetID: String?
    /// The ambient stream last sent (#203), the socket generation it is bound to, and a gate refusal for it.
    var ambientStream: (id: UUID, connection: UUID)?
    var ambientLastSequence = -1
    var ambientRefusal: (stream: UUID, failure: HostConnectionFailure)?
    /// Generation on which the host acked `desiredTargetID`; a reconnect's restored select is not acked.
    var confirmedSelectionGeneration: UUID?
    /// Only the latest selectTarget serial settles a selection; until then (or after it fails) audio is refused.
    var selectionSerial: UInt64 = 0
    var selectionSettled = true
    public init(
        endpoint: HostEndpoint,
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        schedule: ReconnectSchedule = ReconnectSchedule(),
        deviceName: String = "hail terminal",
        pongTimeout: Duration = .seconds(5),
        negotiationTimeout: Duration = .seconds(10),
        deadlineSleep: @escaping Sleep = HostConnection.taskSleep,
        negotiationScheduler: DeadlineScheduler? = nil,
        monotonicNow: @escaping MonotonicNow = { ContinuousClock().now },
        wallNow: @escaping WallNow = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        reportsAmbientRefusals: Bool = false,
        transportLossObserver: TransportLossObserver? = nil,
        sleep: @escaping Sleep = HostConnection.taskSleep,
        jitter: @escaping Jitter = { Double.random(in: 0...1) },
        observer: @escaping Observer = { _ in },
        replyObserver: @escaping ReplyObserver = { _ in }
    ) {
        self.snapshot = HostConnectionSnapshot(endpoint: endpoint)
        self.connector = HostLossReportingConnector.wrapping(connector, observer: transportLossObserver)
        self.reportsAmbientRefusals = reportsAmbientRefusals
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
        self.injectedSleep = sleep
        self.jitter = jitter
        self.observer = observer
        self.replyObserver = replyObserver
    }

    public func currentSnapshot() -> HostConnectionSnapshot { snapshot }

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
        case .disconnected, .failed:
            ambientPacing = nil
            await replaceLoop()
        }
    }

    public func disconnect() async {
        _ = await beginDisconnect()
    }

    func requireReady(capability: String) throws {
        guard snapshot.state == .ready, socket != nil else { throw HostConnectionFailure.notReady }
        guard snapshot.capabilities.contains(capability) else {
            throw HostConnectionFailure.unsupportedCapability(capability)
        }
    }

    func retire() async -> Task<Void, Never> {
        let localBarrier = await beginDisconnect()
        let base = (connector as? HostLossReportingConnector)?.base ?? connector
        guard let predecessor = (base as? SerializedWebSocketConnector)?.predecessor else {
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
}

extension HostConnection {
    /// Healthy sockets get a ping; ambient recovery replaces its wait with a fresh fast retry.
    public func foregrounded() async {
        guard wantsConnection else { return }
        await resetAmbientPacing()
        switch snapshot.state {
        case .ready:
            do {
                try await sendPing(generation: generation, requiresDeadline: true)
            } catch {
                await resetAmbientPacing()
                await reconnectAfterNudge()
            }
        case .connecting, .negotiating:
            if negotiationHasExpired() {
                await reconnectAfterNudge()
            }
        case .disconnected, .reconnecting, .failed:
            await reconnectAfterNudge()
        }
    }
}

extension HostConnection {
    func setReconnectPacing(_ pacing: @escaping @Sendable () async -> AmbientReconnectPacing?) {
        reconnectPacing = pacing
    }

    func networkPathChanged() async {
        guard wantsConnection else { return }
        await resetAmbientPacing()
        if case .reconnecting = snapshot.state { await reconnectAfterNudge() }
    }

    private func resetAmbientPacing() async {
        ambientPacing = await reconnectPacing?()
        ambientPacing?.reset()
    }

    private func reconnectAfterNudge() async {
        guard wantsConnection, ambientPacing?.isCancelled != true else { return }
        await replaceLoop(reconnectAttempt: ambientPacing == nil ? nil : 1)
    }

    /// Called only by the existing generation-checked reconnect loop, including selection-transport flaps.
    func sleep(_ fallback: Duration) async throws {
        try Task.checkCancellation()
        let token = generation
        let pacing = await reconnectPacing?()
        guard isCurrent(token), wantsConnection, !Task.isCancelled else { throw CancellationError() }
        ambientPacing = pacing
        let waiter = UUID()
        if let pacing, !pacing.register(loopTask, id: waiter) {
            await publish(.disconnected, token: token)
            throw CancellationError()
        }
        defer { pacing?.release(waiter) }
        var duration = fallback
        if let pacing, case .reconnecting(let attempt, _) = snapshot.state {
            let delay = pacing.delay(jitterUnit: jitter())
            duration = .milliseconds(Int64((delay * 1_000).rounded()))
            await publish(.reconnecting(attempt: attempt, nextDelay: delay), token: token)
        }
        try await checkRetry(token: token, pacing: pacing)
        do { try await ambientSleep(for: duration, injected: injectedSleep) } catch {
            if pacing?.isCancelled == true { await publish(.disconnected, token: token) }
            throw error
        }
        try await checkRetry(token: token, pacing: pacing)
    }

    private func checkRetry(token: UInt64, pacing: AmbientReconnectPacing?) async throws {
        if pacing?.isCancelled == true { await publish(.disconnected, token: token) }
        guard isCurrent(token), wantsConnection, !Task.isCancelled, pacing?.isCancelled != true else {
            throw CancellationError()
        }
    }
}

extension HostConnection {
    public func selectTarget(_ targetID: String) async throws {
        try requireReady(capability: "select_target")
        let token = generation
        // Until the host confirms the new target, no ambient segment may be tagged for either one.
        selectionSerial &+= 1
        let serial = selectionSerial
        selectionSettled = false
        confirmedSelectionGeneration = nil
        try await send(.select(targetID: targetID), generation: token)
        try await confirmRoundTrip(generation: token)
        // A later selection owns the outcome; this superseded confirmation must not settle it.
        guard selectionSerial == serial else { return }
        desiredTargetID = targetID
        confirmedSelectionGeneration = snapshot.connectionGeneration
        selectionSettled = true
    }

    /// The default sleeps. A closure literal in this actor's default arguments compiled to a task whose
    /// allocations were freed out of order when a pong deadline woke (`swift_task_dealloc` abort, #206).
    /// Avoid defaults that run code on this actor; see #991 for async sleep values called from Tasks on macOS 15.
    public nonisolated static func taskSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
