import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

/// Synthetic completions and advancing time; no connection starts, captured audio or physical playback proof.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AbandonedReplyEchoIntervening904Tests {
    @Test(arguments: ["correlated", "last_input", "single_selector"])
    func secondPeerAcknowledgementCannotEraseAbandonedAudioWords(route: String) async throws {
        let env = try await ReplyEchoRig904.make(route: route)
        let frames = env.frames
        try await env.confirm(frames[0])
        let publication = Task { try await env.listener.publish(frames[1]) }
        var submissions = env.sender.submissions.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        env.wiring.advance(10)
        publication.cancel()
        await #expect(throws: LocalReplyRefusal.publicationFailed) { try await publication.value }
        #expect(env.wiring.observed.withLock { $0 } == [frames[0].id])
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(await env.peer.isLive)
        env.wiring.advance(6)
        try await acknowledgeOnSecondPeer(env)
        let beforeSuccess = env.wiring.observed.withLock { $0 }
        #expect(beforeSuccess.count == 3)
        #expect(beforeSuccess.first == frames[0].id)
        #expect(!beforeSuccess.contains(frames[1].id))
        #expect(Set(beforeSuccess).count == 3)
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(await env.peer.isLive)
        try env.sender.complete() // Includes duplicate callbacks: only the first success may observe.
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(env.wiring.observed.withLock { $0 } == beforeSuccess + [frames[1].id])
        #expect(await env.peer.isLive)
        #expect(env.wiring.activeConnection() == env.wiring.owner)
        env.wiring.advance(4)
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        env.wiring.advance(3)
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }

    /// Ticket/cache boundary: hold physical close after watchdog retirement, as the peer's Task hop can do.
    @Test func firstSuccessAfterWatchdogStillProtectsSpokenWords() async throws {
        let env = try await ReplyEchoRig904.make(route: "single_selector")
        let frames = env.frames
        try await env.confirm(frames[0])
        let transport = ReplyTransportLifecycle()
        let closed = AsyncStream<String>.makeStream()
        let ticket = PreparedWebSocketReply(
            permit: try #require(transport.issuePermit()), submit: env.sender.submit,
            onLateSuccess: { env.wiring.observeReply(frames[1]) },
            cancel: { closed.continuation.yield($0) }, stallGrace: .milliseconds(1)
        )
        #expect(ticket.enqueue())
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(await waiter.value == .abandoned)
        var closures = closed.stream.makeAsyncIterator()
        #expect(await closures.next() == "host reply send stalled")
        #expect(transport.isRetired)
        #expect(env.wiring.observed.withLock { $0 } == [frames[0].id])
        env.wiring.advance(16)
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        try env.sender.complete()
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(env.wiring.observed.withLock { $0 } == frames.map(\.id))
        #expect(await ticket.result() == .abandoned)
        closed.continuation.finish()
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }
}

private func acknowledgeOnSecondPeer(_ env: ReplyEchoRig904) async throws {
    let session = await env.rig.session()
    let sender = ReplyEchoSender904()
    let id = UUID()
    let peer = WebSocketPeer(
        id: id, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), session: session,
        queue: DispatchQueue(label: "synthetic.echo904.second"), helloTimeout: .seconds(5),
        log: { _ in }, onEnd: { _ in }, submitReply: sender.submit
    )
    await env.listener.installInterveningEchoPeer904(peer, id: id)
    let connection = await session.connectionID
    let publication = Task {
        await env.listener.acknowledgeAmbient(
            connection: connection, target: RecipientTestRig.target,
            clip: AmbientAckClip(pcm: Data(count: 48_000), sampleRate: 24_000,
                                 text: "An unrelated delivered reply")
        )
    }
    var submissions = sender.submissions.stream.makeAsyncIterator()
    for _ in 0..<2 {
        _ = try #require(await submissions.next())
        try sender.complete()
    }
    #expect(await publication.value == "sent")
    #expect(await peer.isLive)
    sender.submissions.continuation.finish()
}

private extension WebSocketListener {
    func installInterveningEchoPeer904(_ peer: WebSocketPeer, id: UUID) {
        readyResult = .success(0)
        peers[id] = peer
    }
}
