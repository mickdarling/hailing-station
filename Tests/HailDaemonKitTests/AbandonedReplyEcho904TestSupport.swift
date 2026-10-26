import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

final class ReplyEchoClock904: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ seconds: Int) { instant.withLock { $0 = $0.advanced(by: .seconds(seconds)) } }
}

/// Keeps synthetic ambient listening active and exercises the real own-voice filter, without a child or device.
final class ReplyEchoWiring904: AmbientListenerWiring {
    let owner: UUID
    let spoken: RecentSpokenReplies
    let observed = Mutex<[UUID]>([])
    let active = Mutex(true)
    let clock = ReplyEchoClock904()

    init(owner: UUID) {
        self.owner = owner
        let clock = self.clock
        spoken = RecentSpokenReplies(now: { clock.now })
    }
    func advance(_ seconds: Int) { clock.advance(seconds) }
    func attach(_ listener: WebSocketListener) {}
    func stop(connection: UUID) { if connection == owner { active.withLock { $0 = false } } }
    func shutdown() async { active.withLock { $0 = false } }
    func isLatest(stream: UUID, connection: UUID) -> Bool { activeConnection() == connection }
    func activeConnection() -> UUID? { active.withLock { $0 ? owner : nil } }
    func observeReply(_ frame: Frame) {
        observed.withLock { $0.append(frame.id) }
        spoken.observe(frame)
    }
}

/// Causal enqueue admission and held Network completions; never starts a network connection.
final class ReplyEchoSender904: Sendable {
    let submissions = AsyncStream<Void>.makeStream()
    let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
    func submit(_ completion: @escaping @Sendable (NWError?) -> Void) {
        callback.withLock { $0 = completion }
        submissions.continuation.yield(())
    }
    func complete(_ error: NWError? = nil) throws {
        let completion = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        completion(error)
        completion(nil) // Duplicate success must not observe twice or replace an earlier failure.
        completion(.posix(.ECONNRESET)) // Duplicate callbacks cannot replace late success.
    }
}

struct ReplyEchoRig904 {
    static let words = "The synthetic reply is ready for the next testing step"
    let rig: RecipientTestRig
    let session: HostSession
    let listener: WebSocketListener
    let wiring: ReplyEchoWiring904
    let peer: WebSocketPeer
    let sender: ReplyEchoSender904
    let ended: AsyncStream<Void>
    let reply: ReplyDescriptor

    static func make(route: String) async throws -> Self {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let wiring = ReplyEchoWiring904(owner: await session.connectionID)
        let sender = ReplyEchoSender904()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host, hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: wiring
        )
        await session.attachLastInput(listener.lastInput)
        var reply = uncorrelatedDescriptor(audio: true)
        if route != "single_selector" {
            let context = try await rig.submit(on: session)
            if route == "correlated" { reply = recipientDescriptor(context, audio: true) }
        }
        let id = UUID()
        let ended = AsyncStream<Void>.makeStream()
        let peer = WebSocketPeer(
            id: id, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), session: session,
            queue: DispatchQueue(label: "synthetic.echo904"), helloTimeout: .seconds(5), log: { _ in },
            onEnd: { _ in ended.continuation.yield(()); ended.continuation.finish() }, submitReply: sender.submit
        )
        await listener.installEchoPeer904(peer, id: id)
        return Self(rig: rig, session: session, listener: listener, wiring: wiring,
                    peer: peer, sender: sender, ended: ended.stream, reply: reply)
    }

    var frames: [Frame] {
        [Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
               payload: .text(TextPayload(text: Self.words, reply: reply))),
         Frame(timestamp: 1, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: reply.audioStreamID,
            isFinal: true, bytes: Data(count: 48_000), reply: reply
         )))]
    }

    func confirm(_ frame: Frame) async throws {
        let publication = Task { try await listener.publish(frame) }
        var submissions = sender.submissions.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        try sender.complete()
        #expect(try await publication.value == 1)
    }

    func abandon(_ frame: Frame) async throws {
        let publication = Task { try await listener.publish(frame) }
        var submissions = sender.submissions.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        publication.cancel() // Actual synchronous enqueue, rather than task construction, admits cancellation.
        await #expect(throws: LocalReplyRefusal.publicationFailed) { try await publication.value }
    }
}

private extension WebSocketListener {
    func installEchoPeer904(_ peer: WebSocketPeer, id: UUID) {
        readyResult = .success(0)
        peers[id] = peer
    }
}
