#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension AmbientRouterStreamTargetTests {
    @Test(arguments: [nil, ""] as [String?])
    func anUnboundStartQueuesAndSupersedesOlderFailure(binding: String?) async throws {
        // Drain stdin, then emit only the canonical fixture's session started/stopped events under this session.
        // A silent child would fail finish() at EOF before the newer start could supersede it.
        let fake = try FakeRightyo("""
            /bin/cat > /dev/null
            /usr/bin/sed -n '1p;$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let events = AmbientEventNames(), made = Mutex(0)
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 0.1), events: events,
                                       childMade: { _ in made.withLock { $0 += 1 } })
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let router = env.router, connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let older = UUID(), refused = UUID()
        router.ambientAudio(.started(stream: older, connection: connection, target: RecipientTestRig.target,
                                     binding: "reply-binding"))
        router.ambientAudio(.ended(stream: older, reason: .final))
        await boundedSettle(router)
        try #require(router.liveRuns == 0)
        #expect(events.all.filter { $0 == "ambient_ended" }.count == 1)
        try await pair.boundedBarrier(step: "older child ended cleanly")
        // Work already in flight: the refusal queues behind it, as every other start refusal does.
        router.state.withLock { ($0.working, $0.reloading) = (true, true) }
        let start = AmbientAudioEvent.started(stream: refused, connection: connection,
                                              target: "recipient:other", binding: binding)
        router.ambientAudio(start)
        #expect(router.state.withLock { $0.queue } == [start])
        #expect(router.state.withLock { $0.latest[connection] == refused && $0.newestStart == refused })
        #expect(!router.isLatest(stream: older, connection: connection))
        #expect(!events.all.contains("ambient_refused"))
        // An older stream's late failure must not become an ambient error for this connection's newest start.
        await env.listener.ambientFailed(stream: older, connection: connection, message: "synthetic old failure")
        try await pair.boundedBarrier(step: "old failure suppressed while refusal waits")
        router.state.withLock { $0.reloading = false }
        #expect(await eventually { events.all.contains("ambient_refused") })
        try #require(await eventually { router.state.withLock { !$0.working } })
        #expect(made.withLock { $0 } == 1 && events.all.filter { $0 == "ambient_started" }.count == 1)
        let error = try await receiveFrame(on: pair.sockets[0], step: "queued binding refusal")
        #expect(error.payload == .control(.error(code: .notAllowed,
                                                 message: "ambient unavailable: target_binding_unavailable")))
        try await pair.boundedBarrier(step: "no older failure after the newest refusal")
        #expect(events.all.filter { $0 == "ambient_refused" }.count == 1)
        await env.listener.stop()
    }

    @Test func aConfiguredStreamQueuedAfterAnUnboundStartLaunchesInOrder() async throws {
        let fake = try FakeRightyo("""
            /bin/cat > audio.bin
            /usr/bin/sed -n '1p;$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let events = AmbientEventNames(), made = Mutex(0)
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 0.1), events: events,
                                       childMade: { _ in made.withLock { $0 += 1 } })
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let router = env.router, connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let refused = UUID(), configured = UUID(), bytes = Data(repeating: 1, count: 3_200)
        router.state.withLock { ($0.working, $0.reloading) = (true, true) }
        router.ambientAudio(.started(stream: refused, connection: connection, target: "recipient:other"))
        router.ambientAudio(.started(stream: configured, connection: connection, target: RecipientTestRig.target,
                                     binding: "reply-binding"))
        router.ambientAudio(.segment(stream: configured, sequence: 0, bytes: bytes))
        router.ambientAudio(.ended(stream: configured, reason: .final))
        #expect(!events.all.contains("ambient_refused") && made.withLock { $0 } == 0)
        #expect(router.state.withLock { $0.latest[connection] == configured && $0.newestStart == configured })
        router.state.withLock { $0.reloading = false }
        await boundedSettle(router)
        #expect(made.withLock { $0 } == 1)
        #expect(events.all.filter { ["ambient_refused", "ambient_started", "ambient_ended"].contains($0) }
                == ["ambient_started", "ambient_ended"])
        #expect(fakeFileSize(fake, "audio.bin") == bytes.count)
        #expect(router.state.withLock { $0.queue.isEmpty && !$0.working })
        try await pair.boundedBarrier(step: "no stray refusal after the configured child ended")
        await env.listener.stop()
    }

    @Test(arguments: [false, true])
    func anUnboundStartNeverMakesRoomEvenWhenQueued(queued: Bool) async throws {
        let fake = try FakeRightyo("/bin/sleep 20")
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 0.1), events: events)
        let router = env.router
        for _ in 0..<AmbientRightyoRouter.maxLiveChildren {
            let stream = UUID()
            router.ambientAudio(.started(stream: stream, connection: UUID(), target: RecipientTestRig.target,
                                     binding: "reply-binding"))
            router.ambientAudio(.ended(stream: stream, reason: .final))
        }
        #expect(router.state.withLock { $0.runs.values.filter { !$0.reaped }.count }
                == AmbientRightyoRouter.maxLiveChildren)
        if queued { router.state.withLock { ($0.working, $0.reloading) = (true, true) } }
        router.ambientAudio(.started(stream: UUID(), connection: UUID(), target: "recipient:other"))
        router.state.withLock { $0.reloading = false }
        #expect(await eventually { events.all.contains("ambient_refused") })
        #expect(!events.all.contains("ambient_retired_forced"))
        #expect(router.state.withLock { $0.runs.values.allSatisfy { !$0.forced && !$0.reaped } })
        await env.listener.stop()
    }

    @Test func deadUnboundStartsArePrunedLikeOtherStarts() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1), events: events)
        let router = env.router, stream = UUID()
        router.state.withLock { ($0.working, $0.reloading) = (true, true) }
        router.ambientAudio(.started(stream: stream, connection: UUID(), target: "recipient:other"))
        router.ambientAudio(.ended(stream: stream, reason: .superseded))
        router.state.withLock { $0.reloading = false }
        #expect(await eventually { router.state.withLock { !$0.working && $0.queue.isEmpty } })
        #expect(!events.all.contains("ambient_refused") && !events.all.contains("ambient_started"))
        await env.listener.stop()
    }
}
#endif
