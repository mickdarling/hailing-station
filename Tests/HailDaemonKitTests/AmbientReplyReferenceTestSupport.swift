import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic rig for #230: a legacy `tmux`-kind fake adapter (no contextual delivery, no binding lease), the
/// adapter the live ambient path types into. No terminal, device, RightyO process or provider is involved.
struct LegacyReferenceRig {
    static let target = "tmux:reply"
    static let other = "tmux:other"
    let host: HailHost
    let adapter: FakeAdapter
    let clock = RecipientTestClock()

    static func make(deliverError: (any Error)? = nil) async throws -> Self {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "reply", binding: "binding"), AdapterTarget(name: "other", binding: "other-binding")
        ], deliverError: deliverError)
        let registry = Registry()
        try await registry.register(adapter)
        // One authored guard keeps unrelated default-guard wall budgets out of these suites.
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow(target, binding: "binding", tier: .open)
        try policy.allow(other, binding: "other-binding", tier: .open)
        return Self(host: try HailHost(registry: registry, store: InMemoryPolicyStore(policy)), adapter: adapter)
    }

    /// A negotiated direct session selecting the target, on the rig's injected request clock.
    func session() async -> HostSession {
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test",
                                  now: clock.now, requestClock: clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        return session
    }

    /// A prompt as the ambient consumer builds it: a body, then the target's request-less reply block.
    static let prompt = "synthetic input" + RightyoInputEvent.replyBlock(target: target)

    static func request(connection: UUID, text: String = prompt) -> LocalDispatchRequest {
        LocalDispatchRequest(connection: connection, target: target, binding: "binding", text: text)
    }

    /// The session's own dispatch with `reference` bound, as `WebSocketListener.dispatchAmbient` binds it.
    static func dispatch(_ session: HostSession, reference: UUID) async throws -> UUID? {
        try await HostSession.$ambientReplyReference.withValue(reference) {
            try await session.dispatch(request(connection: UUID()))
        }
    }

    func listener(fallback: Bool = true) throws -> (WebSocketListener, ConnectedPeerIDs) {
        let connected = ConnectedPeerIDs()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", singleTerminalReplyFallback: fallback, log: { connected.record($0) }
        )
        return (listener, connected)
    }
}

/// A reply descriptor naming `request` (nil is the request-less `haild reply --say` shape).
func referenceDescriptor(
    _ request: UUID?, target: String = LegacyReferenceRig.target, audio: Bool = false
) -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: target, audioStreamID: audio ? UUID() : nil,
                    requestID: request)
}

extension WebSocketListener {
    /// The `HostSession` connection id behind the listener peer `id` (what the ambient gate names).
    func sessionConnection(of id: UUID) async throws -> UUID {
        let peer = try #require(peers[id])
        return await peer.session.connectionID
    }
}

/// The UUID a delivered prompt's reply block names after `--request `, or nil when it names none.
func blockReference(in prompt: String) -> UUID? {
    guard let range = prompt.range(of: " --request ", options: .backwards) else { return nil }
    return UUID(uuidString: String(prompt[range.upperBound...].prefix(36)))
}

#if os(macOS)
/// The daemon's own ambient delivery step (reference first, then the audit record, then the dispatch).
func ambientDispatch(
    _ listener: WebSocketListener, _ request: LocalDispatchRequest, audit: AuditLog? = nil
) async throws -> UUID? {
    try await AmbientListenerDispatcher(listener: listener, audit: audit).dispatch(request)
}
#endif
