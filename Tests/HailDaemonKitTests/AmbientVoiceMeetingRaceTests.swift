#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode (rightyo#227) review rounds 1 and 2: a clip privacy supersedes, clips apart from hooks, a renewal,
/// and commands after teardown. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceMeetingRaceTests {
    /// Review round 1: an on clip still queued when privacy begins is superseded, never heard after "Privacy on".
    /// The latch holds the connection's clip chain, so the clip is decided only once privacy has begun; privacy's
    /// own clip, queued behind it on the same chain, is then the only one heard.
    @Test func privacyRightAfterAnEntrySupersedesItsClip() async throws {
        let rig = try await MeetingRig(clips: MeetingRig.privacyClips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router, listener = rig.env.listener
        #expect(await eventually { router.activePipeline?.childStarted == true }, "privacy child started marker")
        let latch = MeetingLatch()
        router.enqueuePrivacyClip(connection) { _ in { await latch.wait() } }
        #expect(router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        router.enqueuePrivacyClip(connection) { _ in {
            _ = await router.confirmVoiceMute(AmbientStopConfirmation.privacyOn, on: connection, listener: listener)
        } }
        latch.open()
        #expect(try await rig.confirmation() == MeetingRig.privacyOn.text)
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_confirmed") == ["on=true profile=meeting confirm=confirmmeetingon/0:sent",
                                                             "on=true profile=rubberDuck confirm=superseded"])
        try await barrier(on: rig.socket, step: "no meeting clip after privacy")
        // The MM-C hook still hears every change, in order.
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=true profile=rubberDuck reason=voice",
                                "on=false profile=rubberDuck reason=privacy"])
        await rig.finish()
    }

    /// Review round 2: a clip held on connection A's chain holds neither A's hook nor another connection's. B's
    /// hook runs while A's clip still waits; A's clip then plays once released.
    @Test func aSlowClipNeverHoldsAnotherConnectionsHook() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router, other = UUID()
        let latch = MeetingLatch()
        router.enqueuePrivacyClip(connection) { _ in { await latch.wait() } }
        #expect(router.setMeeting(on: true, profile: .rubberDuck, connection: connection, reason: "voice") == 1)
        #expect(router.setMeeting(on: true, connection: other, reason: "voice") == 0)
        #expect(await eventually { rig.changes.count == 3 }, "other connection hook marker")
        #expect(!latch.isOpen && rig.details("ambient_meeting_confirmed", on: connection).count == 1)
        #expect(rig.changeConnections == [connection, connection, other])
        #expect(rig.changes == ["on=true profile=meeting reason=voice", "on=true profile=rubberDuck reason=voice",
                                "on=true profile=meeting reason=voice"])
        latch.open()
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        #expect(router.setMeeting(on: false, connection: other, reason: "voice") == 0)
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_meeting_confirmed", on: connection).last
                == "on=true profile=rubberDuck confirm=confirmmeetingon/0:sent")
        await rig.finish()
    }

    /// Review round 1, as media mode: a same-profile entry rearms the timeout (the old expiry is stale) and replays
    /// the on clip as status, keeping the original start, with no second hook: nothing really changed.
    @Test func sameProfileReentryRearmsAndReplaysWithoutAHook() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let connection = try #require(rig.connection()), router = rig.env.router
        let first = try #require(router.state.withLock { $0.meeting[connection] })
        let (old, started) = (first.token, first.started)
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 1)
        #expect(try await rig.confirmation() == MeetingRig.on.text)
        let renewed = try #require(router.state.withLock { $0.meeting[connection] })
        #expect(renewed.token != old && renewed.started == started && renewed.profile == .meeting)
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: old) == 0)
        #expect(router.meetingMode(connection: connection))
        await rig.drainMeetingChanges()
        #expect(rig.changes == ["on=true profile=meeting reason=voice"])
        #expect(rig.details("ambient_meeting").last == "on=true profile=meeting reason=voice reported=1 renewed=true")
        let heard = "on=true profile=meeting confirm=confirmmeetingon/0:sent"
        #expect(rig.details("ambient_meeting_confirmed") == [heard, heard])
        #expect(await eventually { (try? rig.fake.recorded("control.txt")) == MeetingRig.lines(true, true) },
                "renewed meeting child marker")
        await rig.finish()
    }

    /// Review rounds 1 and 2: a meeting or media command a retiring child says after its connection was torn down
    /// is refused. No timer, no child write, no hook, no device notice and no clip; the closed mark goes with that
    /// child.
    @Test(arguments: [("meeting mode", "ambient_meeting", "on=true profile=meeting reason=voice reported=0"),
                      ("media mode", "ambient_media", "on=true reason=voice reported=0")])
    func aModeCommandAfterTeardownDoesNothing(_ phrase: String, _ event: String, _ refusal: String) async throws {
        let rig = try await MeetingRig(phrases: ["meeting mode off", phrase])
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil }, "late command connection marker")
        let connection = try #require(rig.connection()), router = rig.env.router
        rig.pair.close()
        #expect(await eventually { router.state.withLock { $0.closed.contains(connection) } }, "teardown marker")
        try rig.releaseOff()
        #expect(await eventually { rig.details(event) == [refusal + " refused=closed"] }, "late command refusal marker")
        #expect(!router.meetingMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(router.state.withLock { $0.meeting.isEmpty && $0.media.isEmpty })
        await boundedSettle(router, step: "late command child")
        #expect(rig.changes.isEmpty && rig.details("ambient_meeting_confirmed").isEmpty)
        #expect(rig.details("ambient_media_device").isEmpty)
        #expect(!((try? rig.fake.recorded("control.txt")) ?? "").contains("media"))
        #expect(router.state.withLock { $0.closed.isEmpty })
        await bounded("late command listener") { await rig.env.listener.stop(reason: "synthetic test complete") }
    }

    /// Review round 2: a child registered after `stop(connection:)` found nothing to mark (its start was still
    /// making it) is marked closed under the registering lock, so its mode entries are refused; the mark goes with it.
    @Test func aChildRegisteredAfterTeardownIsClosed() async throws {
        let late = try await LateChild()
        defer { late.fake.cleanUp() }
        let (connection, router, stream) = (late.connection, late.env.router, UUID())
        late.starting(stream)
        router.stop(connection: connection)
        #expect(router.state.withLock { !$0.closed.contains(connection) })
        _ = router.state.withLock { router.register(late.pipeline, stream: stream, connection: connection, in: &$0) }
        #expect(router.state.withLock { $0.closed.contains(connection) })
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 0)
        #expect(router.setMedia(true, connection: connection, reason: "voice") == 0)
        #expect(!router.meetingMode(connection: connection) && !router.mediaMode(connection: connection))
        #expect(late.refusals == 2)
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

    /// The router's state as the gate's start of `stream` leaves it, while `start` is still making the child.
    func starting(_ stream: UUID) {
        env.router.state.withLock { ($0.latest[connection], $0.newestStart) = (stream, stream) }
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
