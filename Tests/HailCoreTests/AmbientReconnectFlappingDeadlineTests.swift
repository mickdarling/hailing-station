import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectFlappingDeadlineTests {
    @Test func secondDropKeepsItsOwnOutcomeAndCanRecoverAfterALongOutage() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        clock.advance(by: .seconds(55))
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        try await rig.drop() // Renewed, but no first PCM: must close capture admission again.
        try rig.discardWhileWaiting()
        #expect(rig.notices.map(\.outcome) == [.interrupted])
        clock.advance(by: .seconds(3_600))
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.capture.startCount == 1 && rig.released == 0)
        await rig.close()
    }

    @Test(arguments: [false, true])
    func restorePathNeverSendsPrivacyOffAcrossRepeatedDrops(knownPrivate: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: knownPrivate, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == knownPrivate } }
        var frames: [Frame] = []
        for _ in 0..<2 {
            frames += try await rig.socket.sentFrames()
            try await rig.drop()
            if knownPrivate {
                let old = rig.controller.binding
                let host = try await rig.privateReconnect()
                try await host.answer()
                try await waitUntil { await MainActor.run { rig.controller.binding != old } }
                try await rig.feed()
                await host.expectExactlyOnePrivacyOn()
            } else { try await rig.reconnect() }
        }
        frames += try await rig.socket.sentFrames()
        #expect(frames.allSatisfy { $0.payload != .control(.setPrivacy(on: false)) })
        #expect(rig.notices.map(\.outcome) == [.applied, .applied])
        await rig.close()
    }
}
