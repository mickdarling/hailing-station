import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectPrivacyDeadlineTests {
    @Test func staleGenerationCannotConfirmPrivacyOnTheNewConnection() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        let old = try #require(rig.store.snapshots[rig.endpoint.id])
        let binding = rig.controller.binding
        try await rig.drop()
        let host = try await rig.privateReconnect()
        rig.controller.reconnect.privacyConfirmation.receive(on: true, snapshot: old)
        try rig.discardWhileWaiting()
        try await rig.expectNoRestoredPCM()
        #expect(rig.controller.reconnect.isPending && rig.controller.binding == binding)
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != binding } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test func elapsedFiveSecondsRejectsConfirmationEvenBeforeTimeoutTaskRuns() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        let host = try await rig.privateReconnect()
        clock.advance(by: .seconds(5))
        try await host.answer()
        try await rig.expectStopped(.privacy, outcome: .failed)
        try await rig.expectNoRestoredPCM()
        await rig.close()
    }

    @Test func privacyConfirmationHasItsOwnFiveSecondsAfterALongOutage() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        clock.advance(by: .seconds(3_600))
        let old = rig.controller.binding
        let host = try await rig.privateReconnect()
        clock.advance(by: .seconds(2))
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != old } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        await host.expectExactlyOnePrivacyOn()
        await rig.close()
    }

    @Test func mediaNoticeDuringPrivacyWaitNeverVetoesTheRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        let old = rig.controller.binding
        try await rig.drop()
        let host = try await rig.privateReconnect()
        try await rig.socket.push(.mediaMode(on: true))
        try await waitUntil { await MainActor.run { rig.store.mediaMode[rig.endpoint.id]?.on == true } }
        #expect(rig.notices.isEmpty && rig.controller.reconnect.isPending)
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != old } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
}
