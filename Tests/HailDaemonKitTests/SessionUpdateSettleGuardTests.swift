import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateSettleGuardTests {
    @Test(arguments: ["media", "meeting"])
    func modeBlocksAndClearRequiresFullInterval(_ mode: String) async throws {
        let wiring = SettleGuardWiring(), rig = try await SessionUpdateSettleRig.make(ambient: wiring)
        wiring.set(mode, on: true)
        _ = await rig.submit()
        #expect(await rig.listener.settleDue(rig.connection) == nil)
        rig.clock.advance(by: .seconds(100))
        #expect(rig.deliveries == 0)
        wiring.set(mode, on: false)
        await rig.listener.sessionUpdateModesChanged()
        await rig.refresh()
        #expect(await rig.listener.settleDue(rig.connection) == rig.clock.now + .seconds(8))
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test func privacyDropsOldCardsAndNewPublicCardWaitsFullInterval() async throws {
        let wiring = SettleGuardWiring(), rig = try await SessionUpdateSettleRig.make(ambient: wiring)
        _ = await rig.submit()
        wiring.set("privacy", on: true)
        rig.clock.advance(by: .seconds(8))
        await rig.refresh()
        #expect(rig.deliveries == 0)
        // Status purges private output exactly as the existing privacy policy specifies.
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        wiring.set("privacy", on: false)
        await rig.listener.sessionUpdateModesChanged()
        #expect(await rig.submit().outcome == .held)
        await rig.advanceAndFire()
        #expect(rig.deliveries == 1)
        await rig.listener.stop()
    }

    @Test(arguments: ["playback", "request", "turn", "media", "meeting", "closed", "renderer"])
    func activityOrBlockerAtPeerHopInvalidatesFinalEnqueue(_ signal: String) async throws {
        let wiring = SettleGuardWiring(), rig = try await SessionUpdateSettleRig.make(ambient: wiring)
        _ = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            switch signal {
            case "playback": rig.session.sessionUpdateActivity.playback(true)
            case "request": _ = try? await rig.hostRig.submit(on: rig.session)
            case "turn":
                _ = await rig.session.authorize(sessionFrame(target: RecipientTestRig.target,
                    payload: .text(TextPayload(text: "Synthetic final turn"))), device: "synthetic")
            case "closed": await rig.listener.endSettlePeer()
            case "renderer": await rig.listener.configureSessionUpdateSpeech(SettleConfiguredSpeech())
            default: wiring.set(signal, on: true)
            }
        }, operation: { await rig.submit() })
        await rig.advanceAndFire()
        #expect(rig.deliveries == 0)
        #expect(rig.drains.map(\.detail) == ["trigger=settle count=0"])
        await rig.listener.stop()
    }

    @Test func settingHasDefaultAndInclusiveBounds() {
        #expect(SessionUpdateSettleActivity.configuredMilliseconds(environment: [:]) == 8_000)
        for value in ["2000", "8000", "120000"] {
            #expect(SessionUpdateSettleActivity.configuredMilliseconds(
                environment: ["HAIL_SESSION_UPDATE_SETTLE_MS": value]) == Int(value))
        }
        for value in ["1999", "120001", "true", "", "-1"] {
            #expect(SessionUpdateSettleActivity.configuredMilliseconds(
                environment: ["HAIL_SESSION_UPDATE_SETTLE_MS": value]) == 8_000)
        }
    }
}
