import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateSettleTests {
    @Test func silentInfoDrainsOnceAfterFullIntervalAndLogsOnlyCountAndTrigger() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        let submitted = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
            text: "Synthetic secret card", card: "Synthetic secret metadata"))
        #expect(submitted.outcome == .held)
        #expect(await eventually { await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8) })
        rig.clock.advance(by: .milliseconds(7_999))
        #expect(rig.deliveries == 0)
        await rig.advanceAndFire(.milliseconds(1))
        #expect(rig.deliveries == 1)
        #expect(rig.drains.map(\.detail) == ["trigger=settle count=1"])
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(120))
        #expect(rig.deliveries == 1)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        #expect(rig.drains.allSatisfy { $0.sessionID == nil && $0.endpoint == nil })
        await rig.listener.stop()
    }

    @Test func quietBlocksAndClearingItStartsAFullInterval() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        await rig.listener.setSyntheticQuiet(true)
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        await rig.listener.setSyntheticQuiet(false)
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func playingReplyBlocksAndEndStartsAFullInterval() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        rig.session.sessionUpdateActivity.playback(true)
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        rig.session.sessionUpdateActivity.playback(false)
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func pendingRequestBlocksAndRetirementRestartsInterval() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        let context = try await rig.hostRig.submit(on: rig.session)
        _ = await rig.submit()
        #expect(try #require(await rig.listener.settleDue(rig.connection)) > rig.clock.now + .seconds(8))
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        await rig.session.finishSettleRequest(context.id)
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test(arguments: ["reply_end", "final_turn", "admission"])
    func activityDuringIntervalRearmsWithoutEarlyDelivery(_ signal: String) async throws {
        let rig = try await SessionUpdateSettleRig.make()
        _ = await rig.submit()
        let oldDue = rig.clock.now + .seconds(8)
        rig.clock.advance(by: .seconds(4))
        switch signal {
        case "reply_end": rig.session.sessionUpdateActivity.playback(false)
        case "final_turn":
            _ = await rig.session.authorize(sessionFrame(target: RecipientTestRig.target,
                payload: .text(TextPayload(text: "Synthetic finalized turn"))), device: "synthetic")
        default:
            let context = try await rig.hostRig.submit(on: rig.session)
            await rig.session.finishSettleRequest(context.id)
        }
        #expect(await eventually { await rig.listener.settleDue(rig.connection) == oldDue + .seconds(4) })
        rig.clock.advance(by: .seconds(4))
        #expect(rig.deliveries == 0)
        await rig.advanceAndFire(.seconds(4))
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func closingConnectionCancelsAndInvalidatesEvenAnAwakenedTimer() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        _ = await rig.submit()
        await rig.listener.endSettlePeer()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        #expect(rig.session.sessionUpdateActivity.snapshot == nil)
        await rig.listener.stop()
    }

    @Test func configuredSpeechHasNoSettleAndExistingTriggersStillWork() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        await rig.listener.configureSessionUpdateSpeech(SettleConfiguredSpeech())
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        #expect(await rig.listener.drainSessionUpdates(.naturalPause, connection: rig.connection).count == 1)
        #expect(rig.drains.map(\.detail) == ["trigger=natural_pause count=1"])
        await rig.listener.stop()
    }

    @Test func emptyDrainsAlsoLogTheirTriggerAndZeroCount() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        for trigger in [SessionUpdateDrainTrigger.asked, .interaction, .naturalPause] {
            #expect(await rig.listener.drainSessionUpdates(trigger).isEmpty)
        }
        #expect(rig.drains.map(\.detail) == ["trigger=asked count=0", "trigger=interaction count=0",
            "trigger=natural_pause count=0"])
        #expect(rig.drains.allSatisfy { $0.sessionID == nil && $0.endpoint == nil })
        await rig.listener.stop()
    }

    @Test func actionPushIsImmediateAndAllExistingDrainTriggersAreLogged() async throws {
        let rig = try await SessionUpdateSettleRig.make()
        #expect(await rig.submit(.action).outcome == .delivered)
        #expect(rig.deliveries == 1)
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        for trigger in [SessionUpdateDrainTrigger.asked, .interaction, .naturalPause] {
            _ = await rig.submit()
            #expect(await rig.listener.drainSessionUpdates(trigger, connection: rig.connection).count == 1)
        }
        #expect(rig.drains.map(\.detail) == ["trigger=interaction count=1", "trigger=asked count=1",
            "trigger=interaction count=1", "trigger=natural_pause count=1"])
        await rig.listener.stop()
    }
}

extension HostSession {
    func finishSettleRequest(_ id: UUID) { replyRequests[id] = nil }
}
