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
}
#endif
