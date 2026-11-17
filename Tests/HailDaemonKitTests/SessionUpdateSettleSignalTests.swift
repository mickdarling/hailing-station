import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateSettleSignalTests {
    @Test func pendingInputBlocksBeforeRequestRegistration() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        rig.session.sessionUpdateActivity.beginInput()
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        rig.session.sessionUpdateActivity.endInput()
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func playbackBatchTracksStartAndEndInDeviceOrder() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        let start = try DiagnosticEvent(.replyPlaybackStart, timestamp: 0)
        let end = try DiagnosticEvent(.replyPlaybackEnd, timestamp: 1)
        rig.session.sessionUpdateActivity.beginPlaybackEvents([start])
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(20))
        rig.session.sessionUpdateActivity.playbackEvents([end, start])
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.session.sessionUpdateActivity.playbackEvents([start, end])
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func oneConnectionTimerDrainsBatchAndLogsExactCount() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        _ = await rig.submit()
        _ = await rig.submit()
        _ = await rig.submit()
        await rig.advanceAndFire()
        #expect(rig.deliveries == 3)
        #expect(rig.drains.map(\.detail) == ["trigger=settle count=3"])
        await rig.listener.stop()
    }

    @Test(arguments: ["media", "meeting"])
    func realRouterModeTransitionsRestartTheInterval(_ mode: String) async throws {
        let router = AmbientRightyoRouter(configuration: .init(executable: URL(fileURLWithPath: "/bin/false"),
            config: URL(fileURLWithPath: "/dev/null"), target: RecipientTestRig.target, binding: "reply-binding"))
        let rig = try await SessionUpdateSettleRig.make(ambient: router)
        _ = await rig.submit()
        rig.clock.advance(by: .seconds(4))
        if mode == "meeting" {
            _ = router.setMeeting(on: true, connection: rig.connection, reason: "voice")
        } else { _ = router.setMedia(true, connection: rig.connection, reason: "voice") }
        #expect(await eventually { await rig.listener.settleDue(rig.connection) == nil })
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        if mode == "meeting" {
            _ = router.setMeeting(on: false, connection: rig.connection, reason: "voice")
        } else { _ = router.setMedia(false, connection: rig.connection, reason: "voice") }
        #expect(await eventually { await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8) })
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func deadlineDuringAnotherDrainResumesOnceThatSenderCompletes() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        _ = await rig.submit()
        let old = try #require(await rig.listener.sessionUpdates.held.first?.id)
        let entered = AsyncStream<Void>.makeStream(), released = AsyncStream<Void>.makeStream()
        let sending = Task {
            await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
                entered.continuation.yield(())
                for await _ in released.stream { break }
            }, operation: { await rig.listener.drainSessionUpdates(.asked, only: old) })
        }
        var entries = entered.stream.makeAsyncIterator()
        _ = await entries.next()
        rig.clock.advance(by: .seconds(4))
        _ = await rig.submit()
        await rig.advanceAndFire(.seconds(4))
        #expect(rig.deliveries == 0)
        released.continuation.yield(())
        released.continuation.finish()
        #expect(await sending.value.count == 1)
        #expect(await eventually { await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8) })
        await rig.advanceAndFire()
        #expect(rig.deliveries == 2)
        #expect(rig.drains.map(\.detail) == ["trigger=asked count=1", "trigger=settle count=1"])
        await rig.listener.stop()
    }

    @Test func cancelledOldFireCannotConsumeANewQueueWithTheSameActivityRevision() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        _ = await rig.submit()
        let snapshot = try #require(rig.session.sessionUpdateActivity.snapshot)
        let oldDue = try #require(await rig.listener.settleDue(rig.connection))
        let oldLease = SessionUpdateSettleLease(activity: rig.session.sessionUpdateActivity,
                                               revision: snapshot.revision, due: oldDue)
        #expect(await rig.listener.drainSessionUpdates(.asked).count == 1)
        rig.clock.advance(by: .seconds(8))
        _ = await rig.submit()
        #expect(rig.session.sessionUpdateActivity.snapshot?.revision == snapshot.revision)
        await rig.listener.sessionUpdateSettleFired(connection: rig.connection, lease: oldLease)
        #expect(rig.deliveries == 1, "late old callback cannot drain the newly held card")
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 2)
        await rig.listener.stop()
    }

    @Test func ambientFinalizedTranscriptRearmsBeforeAttentionOrRequest() async throws {
        let router = AmbientRightyoRouter(configuration: .init(executable: URL(fileURLWithPath: "/bin/false"),
            config: URL(fileURLWithPath: "/dev/null"), target: RecipientTestRig.target, binding: "reply-binding"))
        let rig = try await SessionUpdateSettleRig.make(ambient: router)
        let fixture = RightyoInputConsumerTests()
        let consumer = try RightyoInputConsumer(host: nil, target: RecipientTestRig.target, binding: "reply-binding",
            session: fixture.session, allowSynthetic: true,
            echoFilter: router.sessionUpdateEchoFilter(connection: rig.connection), duckActive: { false })
        _ = try await consumer.consume(fixture.start())
        _ = await rig.submit()
        rig.clock.advance(by: .seconds(4))
        _ = try await consumer.consume(fixture.event("transcript", sequence: 2, extra: ["turn": fixture.turn()]))
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        rig.clock.advance(by: .seconds(4))
        #expect(rig.deliveries == 0)
        await rig.advanceAndFire(.seconds(4))
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }
}
