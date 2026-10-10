#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// A loopback listener with ambient listening wired to a fake `rightyo` (#203). No idle sweeper: only the frame,
/// failure, disconnect or stop under test can end a stream.
struct AmbientWiringRig {
    let rig: RecipientTestRig
    let listener: WebSocketListener
    let router: AmbientRightyoRouter
    let gate: AmbientAudioGate
    let connected: ConnectedPeerIDs
    let port: UInt16
}

func ambientRig(
    _ fake: FakeRightyo, timing: RightyoChildProcess.Timing, executable: URL? = nil,
    shutdownGrace: TimeInterval = AmbientRightyoRouter.defaultShutdownGrace, audit: AuditLog? = nil,
    events: AmbientEventNames? = nil, acknowledgements: AmbientAckLibrary? = nil, replyControl: Bool = false,
    onEvent: (@Sendable (WebSocketListenerEvent) -> Void)? = nil
) async throws -> AmbientWiringRig {
    let rig = try await RecipientTestRig.make()
    let connected = ConnectedPeerIDs()
    let configuration = AmbientRightyoRouter.Configuration(
        executable: executable ?? fake.executable, config: fake.config, target: RecipientTestRig.target,
        binding: "reply-binding", allowSynthetic: true, timing: timing, shutdownGrace: shutdownGrace, audit: audit,
        acknowledgements: acknowledgements, replyControl: replyControl
    )
    let router = AmbientRightyoRouter(configuration: configuration, log: { events?.record($0); onEvent?($0) })
    let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: router, sweepInterval: nil)
    let listener = try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: rig.host,
        authorizer: PersonalTerminalAuthorizer(ambientAudio: gate), hostName: "mac-test",
        singleTerminalReplyFallback: true, ambient: router, log: { connected.record($0) }
    )
    return AmbientWiringRig(rig: rig, listener: listener, router: router, gate: gate, connected: connected,
                            port: try await listener.start())
}

/// The next frame on `socket`, or a recorded issue naming `step` once `within` passes (#378): the socket is then
/// cancelled so the receive throws instead of waiting forever.
func receiveFrame(
    on socket: URLSessionWebSocketTask, step: String, within: Duration = .seconds(15)
) async throws -> Frame {
    let timer = Task {
        try await Task.sleep(for: within)
        socket.cancel(with: .goingAway, reason: nil)
    }
    defer { timer.cancel() }
    do {
        return try await recipientSocketReceive(on: socket)
    } catch {
        Issue.record("no frame within \(within) at: \(step)")
        throw error
    }
}

/// `recipientSocketBarrier` with a bound: a ping, then its pong within `within`, else an issue naming `step`.
func barrier(on socket: URLSessionWebSocketTask, step: String, within: Duration = .seconds(15)) async throws {
    let nonce = UUID().uuidString
    try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
    #expect(try await receiveFrame(on: socket, step: step, within: within).payload == .control(.pong(nonce: nonce)))
}

/// Waits, at most `within`, for every router run to return (#378); otherwise records an issue naming `step`, so a
/// stuck run fails the test instead of hanging it.
func settle(_ router: AmbientRightyoRouter, step: String, within: Duration = .seconds(30)) async {
    let deadline = ContinuousClock.now + within
    while router.liveRuns != 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    if router.liveRuns != 0 { Issue.record("router still had \(router.liveRuns) runs after \(within) at: \(step)") }
}

/// Every listener event name, in emission order.
final class AmbientEventNames: Sendable {
    private let names = Mutex<[String]>([])
    var all: [String] { names.withLock { $0 } }
    func record(_ event: WebSocketListenerEvent) { names.withLock { $0.append(event.event) } }
}

func audio(_ stream: UUID, _ sequence: Int, final: Bool = false) -> Frame {
    sessionFrame(target: RecipientTestRig.target,
                 payload: .audio(ambientSegment(stream: stream, sequence: sequence, isFinal: final)))
}

func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// The next frame must be an `ambient`-prefixed, connection-keeping error; returns its message.
func ambientError(on socket: URLSessionWebSocketTask, code expected: ErrorCode = .notAllowed) async throws -> String {
    let frame = try await recipientSocketReceive(on: socket)
    guard case .control(.error(let code, let message)) = frame.payload else {
        Issue.record("expected an error frame, got \(frame.payload)")
        return ""
    }
    #expect(code == expected)
    #expect(message.hasPrefix("ambient"))
    return message
}

/// Echoes the canonical fixture under the session it was given once stdin closes.
let ambientEchoAtEOF = """
    /usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt
    /usr/bin/sed "s/tool-demo/$7/g" events.jsonl
    """
#endif
