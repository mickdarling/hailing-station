import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

/// Synthetic reply publication with ambient still active; no microphone, provider, recording or device proof.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AbandonedReplyEcho904Tests {
    @Test(arguments: ["correlated", "last_input", "single_selector"])
    func abandonedTextAndAudioAreEchoBeforeAndAfterLateSuccess(route: String) async throws {
        let env = try await ReplyEchoRig904.make(route: route)
        let frames = env.frames
        for frame in frames {
            try await env.abandon(frame)
            #expect(env.wiring.observed.withLock { $0.contains(frame.id) })
            #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words) == (frame.id == frames[1].id))
            #expect(await env.peer.isLive)
            #expect(env.wiring.activeConnection() == env.wiring.owner)
            try env.sender.complete()
        }
        #expect(env.wiring.observed.withLock { $0 } == frames.map(\.id))
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(await env.peer.isLive)
        // A pin survives last-input expiry. An ambiguous first frame must not acquire that extra authority.
        #expect(await env.listener.lastInputRoute(frames[0])?.pinned != true)
        env.rig.clock.advance(601_000)
        #expect(await env.listener.lastInputRoute(frames[0])?.pinned != true)
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }

    @Test(arguments: ["correlated", "last_input", "single_selector"], [false, true])
    func framesRefusedBeforeEnqueueAreNeverObserved(route: String, audio: Bool) async throws {
        let env = try await ReplyEchoRig904.make(route: route)
        let frame = env.frames[audio ? 1 : 0]
        await env.listener.replyHold.set(true, connection: env.session.connectionID)
        await #expect(throws: LocalReplyRefusal.privacyHeld) { try await env.listener.publish(frame) }
        #expect(env.sender.callback.withLock { $0 == nil })
        #expect(env.wiring.observed.withLock { $0.isEmpty })
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(await env.peer.isLive)
        #expect(env.wiring.activeConnection() == env.wiring.owner)
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }

    @Test(arguments: ["correlated", "last_input", "single_selector"])
    func confirmedFramesAreObservedAndOnlyRoutedDeliveryPins(route: String) async throws {
        let env = try await ReplyEchoRig904.make(route: route)
        var submissions = env.sender.submissions.stream.makeAsyncIterator()
        for frame in env.frames {
            let publication = Task { try await env.listener.publish(frame) }
            _ = try #require(await submissions.next())
            try env.sender.complete()
            #expect(try await publication.value == 1)
        }
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(env.wiring.observed.withLock { $0.count } == 2)
        #expect((await env.listener.lastInputRoute(env.frames[0])?.pinned == true) == (route != "correlated"))
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }

    @Test(arguments: ["correlated", "last_input", "single_selector"], [false, true])
    func transportErrorFramesAreNeverObserved(route: String, audio: Bool) async throws {
        let env = try await ReplyEchoRig904.make(route: route)
        let publication = Task { try await env.listener.publish(env.frames[audio ? 1 : 0]) }
        var submissions = env.sender.submissions.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        try env.sender.complete(.posix(.EPIPE))
        await #expect(throws: LocalReplyRefusal.publicationFailed) { try await publication.value }
        #expect(env.wiring.observed.withLock { $0.isEmpty })
        #expect(!env.wiring.spoken.isEcho(ReplyEchoRig904.words))
        #expect(!(await env.peer.isLive))
        #expect(await env.listener.lastInputRoute(env.frames[0])?.pinned != true)
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }

    @Test(arguments: [false, true])
    func abandonedAcknowledgementAlsoPreservesEchoBookkeeping(audio: Bool) async throws {
        let env = try await ReplyEchoRig904.make(route: "single_selector")
        let clip = AmbientAckClip(pcm: Data(count: 48_000), sampleRate: 24_000, text: ReplyEchoRig904.words)
        let publication = Task {
            await env.listener.acknowledgeAmbient(connection: env.wiring.owner,
                                                  target: RecipientTestRig.target, clip: clip)
        }
        var submissions = env.sender.submissions.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        if audio {
            try env.sender.complete()
            _ = try #require(await submissions.next())
        }
        publication.cancel()
        #expect(await publication.value == "refused")
        #expect(env.wiring.observed.withLock { $0.count } == (audio ? 2 : 1))
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words) == audio)
        try env.sender.complete()
        #expect(env.wiring.spoken.isEcho(ReplyEchoRig904.words) == audio)
        #expect(await env.peer.isLive)
        #expect(env.wiring.activeConnection() == env.wiring.owner)
        await env.listener.stop(reason: "synthetic cleanup")
        env.sender.submissions.continuation.finish()
    }
}
