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
    mediaTimeout: TimeInterval = AmbientRightyoRouter.defaultMediaTimeout,
    duckTimeout: TimeInterval = AmbientRightyoRouter.defaultDuckTimeout,
    destinations: VoiceDestinations? = nil, shortcuts: ShortcutRunner = ShortcutRunner(),
    routes: VoiceRoutes? = nil, startDeadline: TimeInterval = RightyoAmbientPipeline.defaultStartDeadline,
    ackDeadline: TimeInterval = RightyoAmbientPipeline.ackDeadline,
    confirmTimeout: TimeInterval? = nil,
    meeting: MeetingTestSettings = .init(),
    acknowledgementHold: (@Sendable () async -> Void)? = nil,
    onEvent: (@Sendable (WebSocketListenerEvent) -> Void)? = nil
) async throws -> AmbientWiringRig {
    let rig = try await RecipientTestRig.make()
    let connected = ConnectedPeerIDs()
    var configuration = AmbientRightyoRouter.Configuration(
        executable: executable ?? fake.executable, config: fake.config, target: RecipientTestRig.target,
        binding: "reply-binding", allowSynthetic: true, timing: timing, shutdownGrace: shutdownGrace, audit: audit,
        acknowledgements: acknowledgements, replyControl: replyControl
    )
    (configuration.mediaTimeout, configuration.destinations) = (mediaTimeout, destinations)
    (configuration.duckTimeout, configuration.startDeadline) = (duckTimeout, startDeadline)
    (configuration.ackDeadline, configuration.privacyConfirmTimeout) = (ackDeadline, confirmTimeout)
    (configuration.meetingTimeout, configuration.onMeetingChange) = (meeting.timeout, meeting.onChange)
    if let now = meeting.now { configuration.now = now }
    configuration.acknowledgementHold = acknowledgementHold
    configuration.notes.shortcuts = shortcuts
    let router = AmbientRightyoRouter(configuration: configuration, log: { events?.record($0); onEvent?($0) })
    let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: router, sweepInterval: nil)
    let listener = try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: rig.host,
        authorizer: PersonalTerminalAuthorizer(ambientAudio: gate).naming(routes), hostName: "mac-test",
        singleTerminalReplyFallback: true, ambient: router, log: { connected.record($0) }
    )
    return AmbientWiringRig(rig: rig, listener: listener, router: router, gate: gate, connected: connected,
                            port: try await boundedAmbientListenerStart(listener))
}

/// The next frame on `socket`, or a recorded issue naming `step` once `within` passes (#378). Every receive is now
/// bounded the same way (#704); this keeps the ambient suites' named steps.
func receiveFrame(
    on socket: URLSessionWebSocketTask, step: String, within: Duration = .seconds(15)
) async throws -> Frame {
    try await recipientSocketReceive(on: socket, step: step, within: within)
}

/// `recipientSocketBarrier` with a bound: a ping, then its pong within `within`, else an issue naming `step`. A stray
/// reply fails the test there, as it does unbounded.
func barrier(on socket: URLSessionWebSocketTask, step: String, within: Duration = .seconds(15)) async throws {
    let nonce = UUID().uuidString
    try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
    let received = try await receiveFrame(on: socket, step: step, within: within).payload
    try #require(received == .control(.pong(nonce: nonce)), "Unexpected payload at \(step): \(received)")
}

/// The pair's waits with a bound (#636): `URLSessionWebSocketTask.receive()` ignores task cancellation, so a suite's
/// time limit cannot end a wait for a frame that never comes. Each wait records an issue naming its step instead.
extension FallbackSocketPair {
    /// `connect`, with each hello reply and setup barrier bounded.
    static func boundedConnect(
        port: UInt16, selecting targets: [String?], capabilities: [String] = ["probe"]
    ) async throws -> Self {
        var pair = Self(sessions: [], sockets: [])
        do {
            for target in targets {
                let (session, socket) = try recipientSocket(port: port)
                pair = Self(sessions: pair.sessions + [session], sockets: pair.sockets + [socket])
                try await recipientSocketSend(helloFrame(capabilities: capabilities), on: socket)
                _ = try await receiveFrame(on: socket, step: "connection hello")
                if let target {
                    let select = sessionFrame(payload: .control(.select(targetID: target)))
                    try await recipientSocketSend(select, on: socket)
                }
                try await HailDaemonKitTests.barrier(on: socket, step: "connection setup")
            }
        } catch {
            pair.close()
            throw error
        }
        return pair
    }

    /// `barrier`: every socket idle within the bound; a stray reply is a failure, never a timing inference.
    func boundedBarrier(step: String) async throws {
        for socket in sockets { try await HailDaemonKitTests.barrier(on: socket, step: step) }
    }

    /// `select`, with its barrier bounded.
    func boundedSelect(_ target: String, on index: Int) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: sockets[index])
        try await HailDaemonKitTests.barrier(on: sockets[index], step: "select \(target)")
    }
}

/// Waits, at most `within`, for every router run to return (#378); otherwise records an issue naming `step`, so a
/// stuck run fails the test instead of hanging it.
func settle(_ router: AmbientRightyoRouter, step: String, within: Duration = .seconds(30)) async {
    let deadline = ContinuousClock.now + within
    while router.liveRuns != 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    if router.liveRuns != 0 { Issue.record("router still had \(router.liveRuns) runs after \(within) at: \(step)") }
}

/// Runs `work`, waiting for it at most `within` (#735 S-8 HS-C round 2): past it, records an issue naming `step` and
/// returns, leaving the work to end on its own, so a hang fails the test fast instead of blocking the whole run.
/// For waits that cannot be cancelled, such as `AmbientRightyoRouter.settle()` awaiting its runs' tasks.
func bounded(_ step: String, within: Duration = .seconds(30), _ work: @escaping @Sendable () async -> Void) async {
    let done = BoundedWaitFlag()
    let task = Task {
        await work()
        done.set()
    }
    let deadline = ContinuousClock.now + within
    while !done.isSet, !Task.isCancelled, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    guard !done.isSet else { return }
    task.cancel()
    Issue.record("\(step) did not finish within \(within) or was cancelled")
}

/// `router.settle()`, bounded as `bounded` is.
func boundedSettle(_ router: AmbientRightyoRouter, step: String = "router settle",
                   within: Duration = .seconds(30)) async {
    await bounded(step, within: within) { await router.settle() }
}

/// Whether a `bounded` wait's work ended.
final class BoundedWaitFlag: Sendable {
    private let flag = Mutex(false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
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
    let deadline = ContinuousClock.now + .seconds(15)
    while !Task.isCancelled, ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// The next frame, within the bound `receiveFrame` keeps, must be an `ambient`-prefixed, connection-keeping error;
/// returns its message.
func ambientError(
    on socket: URLSessionWebSocketTask, step: String, code expected: ErrorCode = .notAllowed
) async throws -> String {
    let frame = try await receiveFrame(on: socket, step: step)
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
