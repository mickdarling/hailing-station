import Foundation
import HailProtocol
import Observation
import Testing
@testable import HailCore

/// Observation notifications suspend the test; no timed polling or blocked cooperative workers.
@MainActor
func arrivalObserved(_ predicate: @escaping @MainActor @Sendable () -> Bool) async {
    if predicate() { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        observeArrival(predicate, continuation: continuation)
    }
}

@MainActor
private func observeArrival(_ predicate: @escaping @MainActor @Sendable () -> Bool,
                            continuation: CheckedContinuation<Void, Never>) {
    if predicate() { continuation.resume(); return }
    withObservationTracking { _ = predicate() } onChange: {
        Task { @MainActor in observeArrival(predicate, continuation: continuation) }
    }
}

@MainActor
struct CardsArrivalRig {
    let store: HostConnectionStore
    let socket: ArrivalSocket
    let connector: ScriptedConnector
    let endpoint: HostEndpoint
    let generation: UUID
    static let target = TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)

    static let capabilities = ["ping", "receive_replies", SessionUpdateCard.capability,
                               SessionUpdateCard.audioCapability, DuckMode.privacySwitchCapability]

    static func make(targets: [TargetInfo]? = [target], capabilities: [String] = capabilities,
                     sleep: @escaping HostConnection.Sleep = { _ in throw CancellationError() }) async throws
        -> CardsArrivalRig {
        let endpoint = try makeArrivalEndpoint()
        let socket = ArrivalSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() },
                                        sleep: sleep)
        await store.upsert(endpoint)
        try await socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
                                               capabilities: capabilities, deviceName: "Synthetic")))
        if let targets { try await socket.push(.targets(targets)) }
        await store.connect(endpoint.id)
        await socket.flush()
        store.ambientStreaming = true
        return try CardsArrivalRig(store: store, socket: socket, connector: connector, endpoint: endpoint,
            generation: #require(store.snapshots[endpoint.id]?.connectionGeneration))
    }

    func descriptor() -> ReplyDescriptor {
        let id = UUID()
        return ReplyDescriptor(id: id, hostID: "host", targetID: Self.target.id, audioStreamID: UUID(),
                               priority: .background, sessionUpdateID: id)
    }

    func card(_ reply: ReplyDescriptor) -> HostReplyEvent {
        HostReplyEvent(endpointID: endpoint.id, frame: Frame(timestamp: 1, target: reply.targetID,
            source: reply.hostID, payload: .control(.sessionUpdate(update: reply.id, session: "Build",
                priority: "action", text: "Synthetic decision.", card: "Choose a synthetic option."))))
    }

    func notice(_ control: ControlPayload) {
        HostNoticeOrigin.$generation.withValue(generation) {
            _ = store.receiveAmbientNotice(HostReplyEvent(endpointID: endpoint.id,
                frame: Frame(timestamp: 1, source: "host", payload: .control(control))))
        }
    }

    func receive(_ descriptor: ReplyDescriptor) {
        HostNoticeOrigin.$generation.withValue(generation) { _ = store.receiveSessionUpdate(card(descriptor)) }
    }
}

private func makeArrivalEndpoint() throws -> HostEndpoint { try endpoint() }

/// The next receive call proves that the real connection loop finished its awaited store callback.
/// Counters and continuations also preserve notifications that happen before the test starts waiting.
actor ArrivalSocket: WebSocketTransport {
    private let base = ScriptedSocket()
    private var pushed = 0
    private var delivered = 0
    private var processed = 0
    private var barriers: [(Int, CheckedContinuation<Void, Never>)] = []

    func receive() async throws -> Data {
        processed = delivered
        let ready = barriers.filter { $0.0 <= processed }
        barriers.removeAll { $0.0 <= processed }
        ready.forEach { $0.1.resume() }
        let data = try await base.receive()
        delivered += 1
        return data
    }

    func flush() async {
        let count = pushed
        if processed >= count { return }
        await withCheckedContinuation { barriers.append((count, $0)) }
    }

    func push(_ control: ControlPayload) async throws {
        try await push(FrameCoding.encode(Frame(timestamp: 1, source: "haild", payload: .control(control))))
    }

    func push(_ data: Data) async throws {
        pushed += 1
        try await base.push(data)
    }

    func send(_ data: Data) async throws { await base.send(data) }
    func close() async { await base.close() }
    func fail() async { await base.fail() }
    func holdSends() async { await base.holdSends() }
    func releaseSends() async { await base.releaseSends() }
    func sentFrames() async throws -> [Frame] { try await base.sentFrames() }
}
