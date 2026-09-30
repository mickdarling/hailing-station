import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Invented input and PCM only. No terminal, process, device or provider endpoint is accessed.
actor RecipientContextAdapter: ProviderContextDelivering {
    nonisolated let kind = "recipient"
    private var targets = [
        AdapterTarget(name: "reply", binding: "reply-binding"),
        AdapterTarget(name: "other", binding: "other-binding")
    ]
    private(set) var contexts: [ProviderTurnContext] = []
    private(set) var legacy: [String] = []
    private var held = false
    private var failing = false
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func listTargets() async throws -> [AdapterTarget] { targets }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws { legacy.append(text) }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard targets.contains(where: { $0.name == target && $0.binding == binding }) else {
            throw AdapterError.rebound(target)
        }
        contexts.append(context)
        if held {
            entered = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { release = $0 }
        }
        if failing { throw ProviderCoordinatorSyntheticError.arbitraryFailure }
    }
    func setTargets(_ targets: [AdapterTarget]) { self.targets = targets }
    func failHandoff() { failing = true }
    func holdHandoff() { held = true; entered = false }
    func waitForHandoff() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseHandoff() {
        held = false
        release?.resume()
        release = nil
    }
}

final class RecipientTestClock: Sendable {
    private let value = Mutex<Int64>(1_700_000_000_000)
    func now() -> Int64 { value.withLock { $0 } }
    func advance(_ milliseconds: Int64) { value.withLock { $0 += milliseconds } }
}

struct RecipientTestRig {
    let host: HailHost
    let adapter: RecipientContextAdapter
    let clock = RecipientTestClock()
    static let target = "recipient:reply"

    static func make() async throws -> Self {
        let adapter = RecipientContextAdapter()
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(deliveriesPerMinute: 1_000)
        try policy.allow(target, binding: "reply-binding", tier: .open)
        try policy.allow("recipient:other", binding: "other-binding", tier: .open)
        return Self(host: try HailHost(registry: registry, store: InMemoryPolicyStore(policy)), adapter: adapter)
    }

    func session() async -> HostSession {
        let session = HostSession(
            host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test", now: clock.now
        )
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        return session
    }

    func submit(on session: HostSession) async throws -> ProviderTurnContext {
        let before = await adapter.contexts.count
        let frame = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        let result = await session.receive(frame)
        try #require(result.frames.isEmpty)
        let contexts = await adapter.contexts
        try #require(contexts.count == before + 1)
        return try #require(contexts.last)
    }
}

func recipientDescriptor(_ context: ProviderTurnContext, audio: Bool = false) -> ReplyDescriptor {
    ReplyDescriptor(
        id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
        audioStreamID: audio ? UUID() : nil, requestID: context.id
    )
}

func recipientText(_ descriptor: ReplyDescriptor) -> Frame {
    Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
          payload: .text(TextPayload(text: "synthetic response", reply: descriptor)))
}

func recipientAudio(_ descriptor: ReplyDescriptor, sequence: Int, final: Bool = false) -> Frame {
    Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID, payload: .audio(AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: descriptor.audioStreamID, isFinal: final, bytes: Data([0, 0]), reply: descriptor
    )))
}

func recipientSocket(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let session = URLSession(configuration: .ephemeral)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

func recipientSocketSend(_ frame: Frame, on socket: URLSessionWebSocketTask) async throws {
    try await socket.send(.data(FrameCoding.encode(frame)))
}

func recipientSocketReceive(on socket: URLSessionWebSocketTask) async throws -> Frame {
    switch try await socket.receive() {
    case .data(let data): try FrameCoding.decode(data)
    case .string(let string): try FrameCoding.decode(Data(string.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}

/// The pong follows prior host publications on this peer's serial send queue. A stray reply is a failure,
/// not a timeout-based inference that nothing arrived.
func recipientSocketBarrier(on socket: URLSessionWebSocketTask) async throws {
    let nonce = UUID().uuidString
    try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
    try #require(await recipientSocketReceive(on: socket).payload == .control(.pong(nonce: nonce)))
}
