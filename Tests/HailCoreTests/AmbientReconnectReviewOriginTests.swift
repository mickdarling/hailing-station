import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewOriginTests {
    @Test func delayedOldGenerationModeEventMustNotConfirmNewGenerationPrivacy() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        // An already decoded old-connection callback delayed before entering the main-actor store.
        let oldEvent = HostReplyEvent(endpointID: rig.endpoint.id, frame: Frame(
            timestamp: 1, source: "haild", payload: .control(.duckMode(on: true, reason: "device"))
        ))
        let origin = try #require(rig.controller.binding).connectionGeneration
        try await rig.drop()
        let host = try await rig.privateReconnect()
        let waitingBinding = rig.controller.binding
        HostNoticeOrigin.$generation.withValue(origin) {
            #expect(rig.store.receiveAmbientNotice(oldEvent))
        }
        #expect(rig.controller.binding == waitingBinding,
                "An old-generation mode event must never open new-generation privacy")
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        await #expect(host.audioBeforeConfirmation() == 0,
                      "Old duck_mode callback unlocked PCM without any confirmation from the new host")
        #expect(rig.controller.reconnect.isPending)
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != waitingBinding } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
}
