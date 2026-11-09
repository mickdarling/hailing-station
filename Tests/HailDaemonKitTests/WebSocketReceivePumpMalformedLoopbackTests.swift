import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func malformedBehindParkedTextCompletesThenCloses() async throws {
        let rig = try await MalformedLoopbackRig.make()
        defer { rig.barrier.gate.fire(); rig.pair.close() }
        let socket = rig.pair.sockets[0]
        let session = await rig.peer.session
        let generation = await session.selectionGeneration
        let first = sessionFrame(target: "tmux:codex", payload: .text(TextPayload(text: "synthetic input")))
        try await recipientSocketSend(first, on: socket)
        try await rig.barrier.gate.waitUntilSuspended()
        let worker = try #require(rig.peer.applicationWorker)
        #expect(await rig.runner.delivered.isEmpty)
        #expect(rig.admissions.frames == [first])
        try await rig.queueMalformedAndLaterFrames(on: socket)
        // macOS 15 URLSession needs a pending receive for pong callbacks; retain the first response.
        let (reader, pongAt) = try await pumpSocketPing(socket)
        defer { reader.cancel() }
        #expect(!rig.peer.replyTransport.isRetired)
        #expect(await rig.runner.delivered.isEmpty)
        #expect(rig.admissions.frames == [first])
        #expect(await session.selectionGeneration == generation)
        let releaseAt = ContinuousClock.now
        #expect(pongAt < releaseAt)
        try await rig.barrier.gate.finish(worker)
        try await rig.expectResponseThenMalformedClose(on: socket, firstResponse: reader)
        #expect(await rig.runner.delivered == ["synthetic input", "Enter"])
        #expect(await rig.runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
        #expect(await rig.runner.calls.filter { $0.contains("send-keys") }.count == 1)
        #expect(rig.admissions.frames == [first])
        #expect(await session.selectedTarget == "tmux:codex")
        #expect(await session.selectionGeneration == generation)
        #expect(await session.state == .closed)
        #expect(rig.peer.replyTransport.isRetired)
        #expect(await rig.peer.ended)
        await rig.listener.stop(reason: "test complete")
    }
}

private struct MalformedLoopbackRig {
    let listener: WebSocketListener
    let peer: WebSocketPeer
    let pair: FallbackSocketPair
    let runner: FakeCommandRunner
    let barrier: TmuxCommandBarrier
    let admissions: MalformedSessionAdmissions
    let ended: SelectionPreflightSignal<String>
    let response: Frame

    static func make() async throws -> Self {
        let pane = ScriptedPane(), barrier = TmuxCommandBarrier("paste-buffer")
        let admissions = MalformedSessionAdmissions()
        let peerReady = SelectionPreflightSignal<WebSocketPeer>()
        let responded = Mutex(false)
        let response = sessionFrame(target: "tmux:codex", payload: .text(TextPayload(text: "synthetic response")))
        let runner = FakeCommandRunner(beforeResponse: { arguments in
            await barrier.pause(arguments)
            // A synthetic provider response after Enter uses the production peer's wire sender.
            if pane.enters == 1, arguments.contains("capture-pane"), responded.withLock({ sent in
                guard !sent else { return false }
                sent = true
                return true
            }) {
                let peer = try? await peerReady.wait("first submission response peer")
                #expect(await peer?.send(response) == true)
            }
        }, { pane.respond($0) })
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing(),
                                  submitClock: ManualSubmitClock().clock)
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:codex", binding: "$2@1758230001/%2:502", tier: .open)
        try policy.allow("tmux:claude-hail", binding: "$1@1758230000/%1:501", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let ended = SelectionPreflightSignal<String>()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: admissions) { event in
            if event.event == "session_disconnected" { ended.finish(.success(event.detail ?? "")) }
        }
        let pair = try await FallbackSocketPair.connect(port: listener.start(), selecting: ["tmux:codex"])
        let peers = await listener.peers
        let peer = try #require(peers.values.first)
        peerReady.finish(.success(peer))
        admissions.reset()
        return Self(listener: listener, peer: peer, pair: pair, runner: runner, barrier: barrier,
                    admissions: admissions, ended: ended, response: response)
    }

    func queueMalformedAndLaterFrames(on socket: URLSessionWebSocketTask) async throws {
        let malformed = Data("{".utf8)
        #expect(malformed.count < PayloadLimits.defaultMaxFrameBytes)
        try await selectionPreflightStep("queued malformed send") { try await socket.send(.data(malformed)) }
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: "tmux:claude-hail"))),
                                      on: socket)
        try await recipientSocketSend(sessionFrame(target: "tmux:claude-hail",
                                                   payload: .text(TextPayload(text: "later input"))), on: socket)
    }

    func expectResponseThenMalformedClose(
        on socket: URLSessionWebSocketTask, firstResponse: PumpSocketReader
    ) async throws {
        #expect(try await firstResponse.frame(step: "first submission response") == response)
        let malformed = try await recipientSocketReceive(on: socket, step: "queued malformed response")
        #expect(malformed.payload == .control(.error(code: .malformed, message: "malformed or oversized frame")))
        try await selectionPreflightStep("queued malformed close receive") {
            do {
                _ = try await socket.receive()
                Issue.record("expected close immediately after malformed response")
            } catch {
                #expect(socket.closeCode == .protocolError)
                #expect(socket.closeCode.rawValue == 1002)
            }
        }
        #expect(try await ended.wait("queued malformed disconnect") == "protocol closed")
    }
}

private final class MalformedSessionAdmissions: HostSessionAuthorizing {
    private let recorded = Mutex<[Frame]>([])
    private let base = PersonalTerminalAuthorizer()
    var capabilities: [String] { base.capabilities }
    var frames: [Frame] { recorded.withLock { $0 } }
    func reset() { recorded.withLock { $0 = [] } }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        recorded.withLock { $0.append(frame) }
        return await base.authorize(frame)
    }
}
