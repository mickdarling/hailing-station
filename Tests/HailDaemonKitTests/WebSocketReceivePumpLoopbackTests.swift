import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test(arguments: [false, true])
    func closeObservationRemainsActiveDuringDelivery(admitted: Bool) async throws {
        let rig = try await PumpLoopbackRig.make(command: admitted ? "send-keys" : "paste-buffer")
        defer { rig.barrier.gate.fire(); rig.pair.close() }
        let socket = rig.pair.sockets[0]
        try await recipientSocketSend(sessionFrame(
            target: "tmux:codex", payload: .text(TextPayload(text: "synthetic input"))
        ), on: socket)
        try await rig.barrier.gate.waitUntilSuspended()
        let worker = try #require(rig.peer.applicationWorker)
        #expect(await rig.runner.delivered == (admitted ? ["synthetic input"] : []))
        try await recipientSocketSend(sessionFrame(
            target: "tmux:codex", payload: .text(TextPayload(text: "later input"))
        ), on: socket)
        socket.cancel(with: .normalClosure, reason: nil)
        let reason = try await rig.ended.wait("close observed during delivery")
        #expect(reason == "peer closed")
        #expect(rig.peer.replyTransport.isRetired)
        #expect(await rig.peer.ended)
        #expect(await rig.runner.delivered == (admitted ? ["synthetic input"] : []))
        try await rig.barrier.gate.finish(worker)
        #expect(await rig.runner.delivered == (admitted ? ["synthetic input", "Enter"] : []))
        #expect(await rig.runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
        #expect(await rig.runner.calls.filter { $0.contains("send-keys") }.count == (admitted ? 1 : 0))
        await rig.listener.stop(reason: "test complete")
    }

    @Test func listenerShutdownRetiresBeforeReleasingDelivery() async throws {
        let rig = try await PumpLoopbackRig.make(command: "paste-buffer")
        defer { rig.barrier.gate.fire(); rig.pair.close() }
        try await recipientSocketSend(sessionFrame(
            target: "tmux:codex", payload: .text(TextPayload(text: "synthetic input"))
        ), on: rig.pair.sockets[0])
        try await rig.barrier.gate.waitUntilSuspended()
        let worker = try #require(rig.peer.applicationWorker)
        try await recipientSocketSend(sessionFrame(
            target: "tmux:codex", payload: .text(TextPayload(text: "later input"))
        ), on: rig.pair.sockets[0])
        try await selectionPreflightStep("listener shutdown") { await rig.listener.stop(reason: "test shutdown") }
        #expect(rig.peer.replyTransport.isRetired)
        #expect(await rig.peer.ended)
        #expect(await rig.runner.delivered.isEmpty)
        try await rig.barrier.gate.finish(worker)
        #expect(await rig.runner.delivered.isEmpty)
        #expect(await rig.runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
    }

    @Test func textAndSelectionWaitForPriorResponseProcessing() async throws {
        let rig = try await FinalDeliveryRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
                                             authorizer: PersonalTerminalAuthorizer())
        let pair = try await FallbackSocketPair.connect(port: listener.start(), selecting: [FinalDeliveryRig.target])
        defer { pair.close() }
        let socket = pair.sockets[0]
        await rig.adapter.handoff.arm()
        try await recipientSocketSend(sessionFrame(
            target: FinalDeliveryRig.target, payload: .text(TextPayload(text: "synthetic input"))
        ), on: socket)
        try await selectionPreflightStep("ordered first handoff") { await rig.adapter.handoff.wait() }
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: "final:other"))), on: socket)
        try await recipientSocketSend(sessionFrame(
            target: "final:other", payload: .text(TextPayload(text: "later input"))
        ), on: socket)
        // The transport pong can arrive while the application worker is parked.
        try await pumpSocketPing(socket)
        await rig.adapter.handoff.resume()
        try await recipientSocketBarrier(on: socket, step: "ordered text and selection")
        #expect(await rig.adapter.deliveries == ["synthetic input", "later input"])
        #expect(await rig.adapter.contexts.map(\.binding.sessionID) == [
            "synthetic-binding", "synthetic-other-binding"
        ])
        await listener.stop(reason: "test complete")
        await rig.listener.stop(reason: "test complete")
    }

    @Test func helloDeadlineRetiresTheReceivingPeer() async throws {
        let (host, _) = try await sessionHost()
        let ended = SelectionPreflightSignal<String>()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, helloTimeout: .seconds(1)
        ) { event in
            if event.event == "session_disconnected" { ended.finish(.success(event.detail ?? "")) }
        }
        let (session, socket) = try recipientSocket(port: await listener.start())
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        try await pumpSocketPing(socket)
        let peers = await listener.peers
        let peer = try #require(peers.values.first)
        #expect(try await ended.wait("hello deadline") == "hello timeout")
        #expect(peer.replyTransport.isRetired)
        #expect(await peer.ended)
        await listener.stop(reason: "test complete")
    }

    @Test func protocolClosureRetiresTheReceivingPeer() async throws {
        let (host, _) = try await sessionHost()
        let ended = SelectionPreflightSignal<String>()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host) { event in
            if event.event == "session_disconnected" { ended.finish(.success(event.detail ?? "")) }
        }
        let (session, socket) = try recipientSocket(port: await listener.start())
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        try await pumpSocketPing(socket)
        let peers = await listener.peers
        let peer = try #require(peers.values.first)
        try await recipientSocketSend(helloFrame(versions: [99]), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        #expect(try await ended.wait("protocol close") == "protocol closed")
        #expect(peer.replyTransport.isRetired)
        #expect(await peer.ended)
        await listener.stop(reason: "test complete")
    }
}

private func pumpSocketPing(_ socket: URLSessionWebSocketTask) async throws {
    try await selectionPreflightStep("transport pong") {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

private struct PumpLoopbackRig {
    let listener: WebSocketListener
    let peer: WebSocketPeer
    let pair: FallbackSocketPair
    let runner: FakeCommandRunner
    let barrier: TmuxCommandBarrier
    let ended: SelectionPreflightSignal<String>

    static func make(command: String) async throws -> Self {
        let pane = ScriptedPane()
        let barrier = TmuxCommandBarrier(command)
        let runner = FakeCommandRunner(beforeResponse: { await barrier.pause($0) }, { pane.respond($0) })
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing(),
                                  submitClock: ManualSubmitClock().clock)
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:codex", binding: "$2@1758230001/%2:502", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let ended = SelectionPreflightSignal<String>()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer()) { event in
            if event.event == "session_disconnected" { ended.finish(.success(event.detail ?? "")) }
        }
        let pair = try await FallbackSocketPair.connect(port: listener.start(), selecting: ["tmux:codex"])
        let peers = await listener.peers
        let peer = try #require(peers.values.first)
        return Self(listener: listener, peer: peer, pair: pair, runner: runner, barrier: barrier, ended: ended)
    }
}
