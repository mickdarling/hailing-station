#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy's reply hold against races (#735 S-2c, round 2): typed input's correlated reply, a request-bound reply
/// racing the entry, a fast entry and exit, and the session's own stop. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyReplyRaceTests {
    private typealias Reply = AmbientPrivacyReplyTests

    /// Key 1 M6b: a typed-input request made during privacy has its correlated reply refused in `deliverHostReply`.
    @Test func aCorrelatedReplyToTypedInputDuringPrivacyNeverPlays() async throws {
        let rig = try await DuckRig(script: Reply.quiet)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        #expect(await eventually { rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1 })
        #expect(await eventually { rig.details("ambient_privacy_replies").count == 1 })
        let request = try await Reply.typedRequest(on: rig)
        #expect(await Reply.refusal(Reply.answer(request), on: rig) == .privacyHeld)
        try await barrier(on: rig.socket, step: "nothing forwarded")
        await rig.finish()
    }

    /// Key 2 M14: a request-bound reply raced against entry, before the async drop of pending replies has run (the
    /// hold alone is set), is refused by the hold inside `deliverHostReply`.
    @Test func aRequestBoundReplyRacingTheEntryIsRefusedByTheHold() async throws {
        let rig = try await DuckRig(script: Reply.quiet)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        let request = try await Reply.typedRequest(on: rig)
        await rig.env.listener.replyHold.set(true, connection: connection)
        #expect(await Reply.refusal(Reply.answer(request), on: rig) == .privacyHeld)
        try await barrier(on: rig.socket, step: "nothing forwarded")
        await rig.env.listener.replyHold.set(false, connection: connection)
        #expect(await Reply.refusal(Reply.answer(request, "later"), on: rig) != nil)
        await rig.finish()
    }

    /// Key 2: the exit releases the hold only after the entry's drop has run, so a reply to a request made before a
    /// fast entry and exit never slips through.
    @Test func aFastEntryAndExitNeverLetsAnOldReplyThrough() async throws {
        let rig = try await DuckRig(script: Reply.quiet)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection()), router = rig.env.router
        let request = try await Reply.typedRequest(on: rig)
        #expect(await eventually { router.setDuck(true, connection: connection, reason: "voice") == 1 })
        #expect(router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(await Reply.refusal(Reply.answer(request), on: rig) != nil)
        #expect(await Reply.flowsAgain(on: rig, connection: connection))
        #expect(await Reply.refusal(Reply.answer(request, "again"), on: rig) != nil)
        try await barrier(on: rig.socket, step: "the old reply never played")
        // The drop ran before the release, on the same serial queue.
        let order = rig.details("ambient_privacy_replies")
        #expect(order.count == 2 && order.first?.hasPrefix("dropped=") == true && order.last == "released=true")
        #expect(order.first != "dropped=0")
        await rig.finish()
    }

    /// Key 2 M19: a reply refused while private is stopped in its session, so its later frames stay refused.
    @Test func aHeldReplyIsStoppedInItsSession() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let held = Reply.reply(Reply.descriptor(audio: true))
        let id = try #require(HostSession.replyID(held))
        #expect(await !session.hasStopped(held))
        await session.stopHeldReply(id)
        #expect(await session.hasStopped(held))
        await session.stopHeldReply(id)
        #expect(await session.hasStopped(Reply.reply(Reply.descriptor())) == false)
    }

    /// A fake whose owner's request is accepted before privacy entry (its transcript admitted) and decided after it:
    /// it emits `started` (v2) and the transcripts, waits until the host writes `{"duck":true}`, then emits the
    /// attention decision and the request.
    static let decidedAfterEntry = """
    \(AmbientPrivacyEntryTests.startPrivatePrelude)
    /bin/cat <&3 >> control.txt &
    /usr/bin/sed -n -e '1,4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
      -e 's/"phase": "started"/"duck": {"version": 2'"$PRIV"'}, "phase": "started"/'
    while ! /usr/bin/grep -q duck control.txt 2>/dev/null; do /bin/sleep 0.05; done
    /usr/bin/sed -n -e '5,6p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"
    /usr/bin/touch decided
    /bin/cat > /dev/null
    /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
    """

    /// Jarvis: a request accepted before entry and decided after it is never dispatched to the agent, and a reply to
    /// that connection is held.
    @Test func aRequestAcceptedBeforeEntryAndDecidedAfterIsDropped() async throws {
        let rig = try await DuckRig(script: Self.decidedAfterEntry)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection()), before = await rig.env.rig.adapter.contexts.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(await eventually { rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1 })
        let decided = rig.fake.directory.appendingPathComponent("decided").path
        #expect(await eventually { FileManager.default.fileExists(atPath: decided) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await rig.env.rig.adapter.contexts.count == before)
        #expect(rig.details("ambient_acknowledged").isEmpty)
        let reply = Reply.reply(Reply.descriptor(), text: "synthetic answer")
        #expect(await Reply.refusal(reply, on: rig) == .privacyHeld)
        try await barrier(on: rig.socket, step: "nothing forwarded")
        await rig.finish()
        #expect(await rig.env.rig.adapter.contexts.count == before)
    }
}
#endif
