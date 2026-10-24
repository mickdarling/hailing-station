#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode (rightyo#227) review rounds 2-4: a teardown is recorded by `stop(connection:)` itself, never
/// inferred, refuses a late child's mode entries, survives a take-over, and is pruned once nothing can speak for it.
/// Children are registered by hand under the router's lock, with the worker held busy. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceMeetingTeardownTests {
    /// Review rounds 2 and 4: `stop(connection:)` while the worker is still making a start's child records the
    /// teardown itself, with no run to mark yet. The child registers, its mode entries are refused, and the mark goes
    /// once the worker is idle and the child is reaped.
    @Test func aChildRegisteredAfterTeardownIsClosed() async throws {
        let late = try await LateChild()
        defer { late.fake.cleanUp() }
        let (connection, router, stream) = (late.connection, late.env.router, UUID())
        late.starting(stream)
        router.stop(connection: connection)
        #expect(router.state.withLock { $0.closed.contains(connection) })
        _ = router.state.withLock { router.register(late.pipeline, stream: stream, connection: connection, in: &$0) }
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 0)
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 0)
        #expect(!router.meetingMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(late.refusals == 2)
        await late.releaseWorker()
        #expect(router.state.withLock { $0.closed.contains(connection) }, "kept while its child runs")
        await late.finish()
    }

    /// Review round 4: the same in-flight start taken over by another device, then torn down, before it registers.
    /// The take-over leaves no trace a teardown could be told from; `stop(connection:)` records it, so the child's
    /// late meeting or media entry is still refused.
    @Test func aTakeOverThenTeardownBeforeRegisterIsClosed() async throws {
        let late = try await LateChild()
        defer { late.fake.cleanUp() }
        let (connection, router, stream, other) = (late.connection, late.env.router, UUID(), UUID())
        late.starting(stream)
        router.ambientAudio(.ended(stream: stream, reason: .superseded))
        router.ambientAudio(.started(stream: other, connection: UUID()))
        #expect(router.state.withLock { $0.latest[connection] == nil && $0.newestStart == other })
        router.stop(connection: connection)
        _ = router.state.withLock { router.register(late.pipeline, stream: stream, connection: connection, in: &$0) }
        #expect(router.state.withLock { $0.closed.contains(connection) })
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 0)
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 0)
        #expect(!router.meetingMode(connection: connection) && late.refusals == 2)
        await late.releaseWorker()
        router.ambientAudio(.ended(stream: other, reason: .final))
        await late.finish()
    }

    /// Review round 4: the mark is bounded. A teardown with no child and nothing in flight is dropped at once; one
    /// made while the worker was busy is dropped when the worker goes idle.
    @Test func aTeardownWithNothingLeftIsPruned() async throws {
        let late = try await LateChild()
        defer { late.fake.cleanUp() }
        let (router, idle, busy) = (late.env.router, UUID(), UUID())
        router.stop(connection: idle)
        #expect(router.state.withLock { $0.closed.isEmpty })
        late.holdWorker()
        router.stop(connection: busy)
        #expect(router.state.withLock { $0.closed == [busy] })
        await late.releaseWorker()
        #expect(router.state.withLock { $0.closed.isEmpty })
        await late.pipeline.stop()
        await late.finish()
    }

    /// Review round 3: a take-over landing while a start is still making its child also clears `latest`, but the
    /// connection is still there: it is never marked closed, and its meeting entry is not refused. Both halves of the
    /// gate's take-over: its old stream's `superseded` end alone, and that end with the new start.
    @Test(arguments: [false, true]) func aTakeOverBeforeRegisterNeverCloses(_ newStart: Bool) async throws {
        let late = try await LateChild()
        defer { late.fake.cleanUp() }
        let (connection, router, stream, other) = (late.connection, late.env.router, UUID(), UUID())
        late.starting(stream)
        router.ambientAudio(.ended(stream: stream, reason: .superseded))
        if newStart { router.ambientAudio(.started(stream: other, connection: UUID())) }
        #expect(router.state.withLock { $0.latest[connection] == nil })
        _ = router.state.withLock { router.register(late.pipeline, stream: stream, connection: connection, in: &$0) }
        #expect(router.state.withLock { !$0.closed.contains(connection) })
        router.setMeeting(on: true, connection: connection, reason: "voice")
        #expect(router.meetingMode(connection: connection) && late.refusals == 0)
        router.setMeeting(on: false, connection: connection, reason: "voice")
        await late.releaseWorker()
        if newStart { router.ambientAudio(.ended(stream: other, reason: .final)) }
        await late.finish()
    }
}

/// A child built outside the gate for `connection`, registered by the test itself under the router's lock (review
/// rounds 2 and 3), on a rig whose events it keeps.
private struct LateChild {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pipeline: RightyoAmbientPipeline
    let connection = UUID()
    private let events = DuckEvents()
    var refusals: Int { events.list.withLock { $0.filter { $0.detail?.hasSuffix("refused=closed") == true }.count } }

    init() async throws {
        fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, check our discussion."))
        try fake.install(fixture: "tool-events.jsonl")
        let events = events
        env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), replyControl: true,
                                   onEvent: { event in events.list.withLock { $0.append(event) } })
        pipeline = try RightyoAmbientPipeline(
            configuration: .init(executable: fake.executable, config: fake.config, target: "tmux:demo",
                                 binding: "pinned", connection: connection, allowSynthetic: true,
                                 timing: .init(eofGrace: 20, termGrace: 20)),
            dispatcher: RecordingAmbientDispatcher())
    }

    /// The router's state as the gate's start of `stream` leaves it, while the worker is still making the child.
    func starting(_ stream: UUID) {
        env.router.state.withLock { ($0.latest[connection], $0.newestStart) = (stream, stream) }
        holdWorker()
    }

    /// The worker busy making a child: later events queue behind it, held as a reload in progress holds them.
    func holdWorker() { env.router.state.withLock { ($0.working, $0.reloading) = (true, true) } }

    /// The worker done: it drains what queued (an end of no stream wakes it), then goes idle and prunes.
    func releaseWorker() async {
        env.router.state.withLock { $0.reloading = false }
        env.router.ambientAudio(.ended(stream: UUID(), reason: .final))
        #expect(await eventually { env.router.state.withLock { !$0.working && $0.queue.isEmpty } }, "worker idle")
    }

    func finish() async {
        pipeline.finishInput()
        await boundedSettle(env.router, step: "late registered child")
        #expect(env.router.state.withLock { $0.closed.isEmpty })
        await bounded("late registered listener") { [listener = env.listener] in
            await listener.stop(reason: "synthetic test complete")
        }
    }
}
#endif
