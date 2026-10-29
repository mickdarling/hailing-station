import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewFlappingTests {
    @Test func secondDropDuringPrivateConfirmationKeepsCaptureClosedAndRecoversInBackground() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        try await rig.drop()
        let oldHost = try await rig.privateReconnect()
        let oldSnapshot = try #require(rig.store.snapshots[rig.endpoint.id])
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try rig.discardWhileWaiting()
        let host = try await rig.privateReconnect()
        rig.controller.reconnect.privacyConfirmation.receive(on: true, snapshot: oldSnapshot)
        try rig.discardWhileWaiting()
        try await rig.expectNoRestoredPCM()
        let before = rig.controller.binding
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != before } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.capture.startCount == 1 && rig.makeCalls == 1 && rig.permissionCalls == 1)
        await oldHost.expectExactlyOnePrivacyOn()
        await host.expectExactlyOnePrivacyOn()
        await rig.close()
    }

    @Test func secondDropDuringReauthorizationKeepsGapClosedAndDoesNotStartFreshCapture() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { try await rig.selectionPing(after: 0) != nil }
        try await rig.drop()
        try await waitUntil { await MainActor.run { !rig.notices.isEmpty } }
        #expect(rig.notices.map(\.outcome) == [.interrupted] && rig.controller.reconnect.isPending)
        await rig.controller.update(binding: nil, scene: .background)
        let before = rig.capture.discardedCount
        for _ in 0..<10 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == before + 10)
        try await rig.reconnect()
        #expect(rig.controller.isListening && rig.capture.startCount == 1 && rig.makeCalls == 1)
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        await rig.close()
    }

    @Test func selectionCompletionDuringCloseCannotReopenTheGap() async throws {
        let run = try AmbientClosingSelectionRun()
        let original = try await run.holdCloseDuringSelection()
        let rig = run.rig
        #expect(rig.notices.map(\.outcome) == [.interrupted] && rig.controller.reconnect.isPending)
        #expect(rig.controller.binding == original)
        let before = rig.capture.discardedCount
        for _ in 0..<10 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == before + 10)
        try await run.releaseClose()
        await rig.controller.update(binding: nil, scene: .background)
        run.clock.advance(by: .seconds(4))
        try await rig.reconnect()
        #expect(rig.controller.isListening && rig.capture.startCount == 1 && rig.makeCalls == 1)
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(try rig.currentBinding().hostID == original.hostID)
        #expect(try rig.currentBinding().targetID == original.targetID)
        #expect(rig.permissionCalls == 1 && rig.unexpected.isEmpty)
        try await run.expectNoGapAudioOrPrivacyOff()
        await rig.close()
    }

    @Test func selectionCompletionDuringCloseStillRecoversAfterALongOutage() async throws {
        let run = try AmbientClosingSelectionRun()
        let original = try await run.holdCloseDuringSelection()
        let rig = run.rig
        #expect(rig.controller.binding == original)
        try await run.releaseClose()
        run.clock.advance(by: .seconds(5))
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.controller.isListening && rig.capture.stopCount == 0 && rig.capture.startCount == 1)
        try await run.expectNoGapAudioOrPrivacyOff()
        await rig.close()
    }
}
