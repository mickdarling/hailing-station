#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension AmbientRouterStreamTargetTests {
    @Test(arguments: [nil, ""] as [String?])
    func anUnboundStartQueuesAndSupersedesOlderFailure(binding: String?) async throws {
        // EOF without session events is a real child failure, held until the newer start is queued.
        let fake = try FakeRightyo("""
        /bin/cat > /dev/null
        while [ ! -e fail-old ]; do /bin/sleep 0.02; done
        """)
        defer { fake.cleanUp() }
        let held = PolicyWriteGate(), events = AmbientEventNames(), made = Mutex(0), failures = Mutex<[String]>([])
        defer { held.fire() }
        let env = try await heldBindingRig(fake, held: held, events: events, onEvent: { event in
            if event.event == "ambient_ended", let detail = event.detail { failures.withLock { $0.append(detail) } }
        }, childMade: { _ in made.withLock { $0 += 1 } })
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let router = env.router, connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let older = retireStreams(router, connection: connection), pending = UUID()
        // Full slots send this real start to the worker, which waits at the forced-retirement log hook.
        router.ambientAudio(.started(stream: pending, connection: connection, target: RecipientTestRig.target))
        try await held.waitUntilSuspended()
        let end = AmbientAudioEvent.ended(stream: pending, reason: .superseded)
        router.ambientAudio(end)
        let refused = UUID(), start = AmbientAudioEvent.started(stream: refused, connection: connection,
                                                                target: "recipient:other", binding: binding)
        router.ambientAudio(start)
        #expect(router.state.withLock { $0.working && $0.queue == [end, start] })
        #expect(router.state.withLock { $0.latest[connection] == refused && $0.newestStart == refused })
        #expect(older.allSatisfy { !router.isLatest(stream: $0, connection: connection) })
        #expect(!events.all.contains("ambient_refused"))
        try Data().write(to: fake.directory.appendingPathComponent("fail-old"))
        try #require(await eventually { router.liveRuns == 0 })
        #expect(failures.withLock { $0 } == Array(repeating: "input invalidLifecycle", count: older.count))
        try await pair.boundedBarrier(step: "real old EOF failures suppressed while refusal waits")
        try await held.finish(Task {})
        #expect(await eventually { events.all.contains("ambient_refused") })
        try #require(await eventually { router.state.withLock { !$0.working } })
        #expect(made.withLock { $0 } == older.count && router.activeStream == nil)
        let error = try await receiveFrame(on: pair.sockets[0], step: "queued binding refusal")
        #expect(error.payload == .control(.error(code: .notAllowed,
                                                 message: "ambient unavailable: target_binding_unavailable")))
        try await pair.boundedBarrier(step: "no older failure after the newest refusal")
        await env.listener.stop()
    }

    private func retireStreams(_ router: AmbientRightyoRouter, connection: UUID) -> [UUID] {
        let streams = (0..<AmbientRightyoRouter.maxLiveChildren).map { _ in UUID() }
        for stream in streams {
            router.ambientAudio(.started(stream: stream, connection: connection, target: RecipientTestRig.target))
            router.ambientAudio(.ended(stream: stream, reason: .final))
        }
        return streams
    }

    private func heldBindingRig(_ fake: FakeRightyo, held: PolicyWriteGate, events: AmbientEventNames,
                                onEvent: @escaping @Sendable (WebSocketListenerEvent) -> Void,
                                childMade: @escaping @Sendable (UUID) -> Void) async throws -> AmbientWiringRig {
        // The worker inherits this dedicated executor; holding its synchronous log hook leaves the cooperative
        // pool free, with real make-room work in flight and no fabricated working/reloading/queue state.
        try await withTaskExecutorPreference(held.executor) {
            try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 0.1), events: events,
                                 onEvent: { event in
                if event.event == "ambient_retired_forced" { held.suspend() }
                onEvent(event)
            }, childMade: childMade)
        }
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
            router.ambientAudio(.started(stream: stream, connection: UUID(), target: RecipientTestRig.target))
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
